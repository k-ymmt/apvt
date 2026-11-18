import APVTModel
import AppKit
import Foundation

/// macOS apps (AppKit and SwiftUI): `apvt launch` starts the app with the agent in
/// `DYLD_INSERT_LIBRARIES`, signed so the app's code signature admits it. The agent answers on
/// a unix socket under `/tmp` — or, in a sandboxed app, on pipes there that a sandbox extension
/// token from apvt opens to it — and captures its own window for screenshots.
public struct MacOSPlatform: Platform {
    public let id = Snapshot.macOS

    public init() {}

    // MARK: - Setup

    public func setup(_ options: SetupOptions) throws -> SetupReport {
        throw APVTError(.usage, "apvt setup is for the iOS Simulator",
                        why: "a macOS app gets the agent from the launch itself; there is nothing to set up beforehand.",
                        fix: ["apvt launch path/to/MyApp.app"])
    }

    public func teardown(_ options: SetupOptions) throws -> SetupReport {
        throw APVTError(.usage, "apvt teardown is for the iOS Simulator",
                        why: "nothing is installed for macOS apps: one launched without apvt launch has no agent.")
    }

    public func status(device: String?) throws -> PlatformStatus {
        PlatformStatus(devices: [], oldLLDBHook: false, agentBuild: MacAgentBuilder.currentHash(), agents: try agents(device: device))
    }

    // MARK: - Launch

    /// What a launch of `app` needs: the agent (signed as the app requires) and its environment.
    struct Preparation {
        var bundle: AppBundle
        var signature: CodeSignature
        var environment: [String: String]
        var actions: [String]
    }

    func prepare(_ options: LaunchOptions, loadedBy: String) throws -> Preparation {
        let bundle = try AppBundle(path: options.app)
        guard bundle.platform == .macOS else {
            throw APVTError(.usage, "\(bundle.url.lastPathComponent) is not a macOS app apvt can launch", why: bundle.platformDescription)
        }
        let signature = try CodeSignature.read(bundle)
        // Before building anything: an app that will never load the agent is not launched.
        let requirement = try signature.agentSignature(app: bundle.url.path)

        var actions: [String] = []
        let products = try MacAgentBuilder.ensure(rebuild: options.rebuild)
        actions.append(products.built ? "built the agent for macOS (\(products.hash))" : "agent is up to date (\(products.hash))")
        var agent = products.agent
        switch requirement {
        case .adhoc:
            if let identity = options.identity {
                actions.append("--identity \(identity) not used: this app loads the agent as it is (no library validation)")
            }
        case .team(let team):
            let signed = try MacAgentBuilder.signed(products, team: team, appAuthority: signature.authority, identity: options.identity)
            agent = signed.agent
            actions.append("\(signed.signedNow ? "signed the agent" : "agent already signed") for team \(team) (identity \(signed.identity.prefix(8))…): the app's Hardened Runtime only loads libraries of its team")
        }

        var environment = ["DYLD_INSERT_LIBRARIES": agent.path, "APVT_LOADED_BY": loadedBy]
        let directory = AgentWire.directory(uid: getuid())
        mkdir(directory, 0o700)
        if signature.sandboxed {
            // `/tmp` is a link to `/private/tmp`: the extension is for the real path.
            let real = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            guard let token = SandboxExtension.readWriteToken(for: real) else {
                throw APVTError(.environment, "could not issue a sandbox extension for \(real)",
                                why: "the app is sandboxed (com.apple.security.app-sandbox), so its agent needs one to reach apvt; sandbox_extension_issue_file refused.",
                                fix: ["build the app without the App Sandbox entitlement for testing"])
            }
            environment[AgentWire.sandboxTokenVariable] = token
            actions.append("issued a sandbox extension for \(directory): the app is sandboxed, so its agent answers over pipes there")
        }
        return Preparation(bundle: bundle, signature: signature, environment: environment, actions: actions)
    }

    public func launchEnvironment(_ options: LaunchOptions) throws -> [String: String] {
        try prepare(options, loadedBy: "env").environment
    }

    public func launch(_ options: LaunchOptions) throws -> LaunchReport {
        let preparation = try prepare(options, loadedBy: "launch")
        let bundle = preparation.bundle
        var actions = preparation.actions

        // One instance: the one with the agent.
        let running = Processes.running(executable: bundle.executable)
        if !running.isEmpty {
            for pid in running {
                if NSRunningApplication(processIdentifier: pid)?.terminate() != true { kill(pid, SIGTERM) }
            }
            var deadline = Date().addingTimeInterval(3)
            while running.contains(where: Processes.isAlive), Date() < deadline { usleep(50_000) }
            for pid in running where Processes.isAlive(pid) { kill(pid, SIGKILL) }
            deadline = Date().addingTimeInterval(2)
            while running.contains(where: Processes.isAlive), Date() < deadline { usleep(50_000) }
            actions.append("terminated the running instance (pid \(running.map(String.init).joined(separator: ", ")))")
        }

        let log = "\(AgentWire.directory(uid: getuid()))/launch-\(bundle.bundleId).log"
        try? FileManager.default.removeItem(atPath: log)
        var arguments = ["-n", bundle.url.path, "--stdout", log, "--stderr", log]
        for (key, value) in preparation.environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        if !options.arguments.isEmpty { arguments += ["--args"] + options.arguments }
        let started = Date()
        let opened = try Shell.run("/usr/bin/open", arguments, timeout: 60)
        guard opened.ok else {
            throw APVTError(.environment, "macOS could not open \(bundle.url.lastPathComponent)",
                            why: opened.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                            fix: ["open \"\(bundle.url.path)\"   # does it start at all?"])
        }

        let deadline = started.addingTimeInterval(max(options.wait, 1))
        var announced: RunningAgent?
        while true {
            let candidates = AgentClient.announcements().filter {
                $0.platform == id && $0.startedAt > started.addingTimeInterval(-1)
                    && ($0.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == bundle.url.path } ?? ($0.bundleId == bundle.bundleId))
            }
            if let found = candidates.first.map({ RunningAgent($0, platform: id) }) {
                announced = found
                if ping(found, timeout: 2) {
                    // The first window is still being built.
                    let settle = 1.5 - Date().timeIntervalSince(found.startedAt)
                    if settle > 0 { Thread.sleep(forTimeInterval: settle) }
                    actions.append("launched \(bundle.url.lastPathComponent) (pid \(found.pid))" + (found.transport == AgentWire.transportPipe ? ", agent on pipes" : ""))
                    return LaunchReport(platform: id, agent: found, actions: actions,
                                        next: ["apvt inspect --app \(bundle.bundleId)   # issues in the key window"])
                }
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let output = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").suffix(6).joined(separator: " | ")
        let said = output.map { $0.isEmpty ? "" : " The app's output ends: \($0)" } ?? ""
        if let announced {
            let silence = explainSilence(of: [announced])
            throw APVTError(.agent, "\(announced.title) started but its agent did not answer within \(Describe.number(options.wait))s",
                            why: (silence.why ?? "") + said, fix: silence.fix)
        }
        let alive = !Processes.running(executable: bundle.executable).isEmpty
        if !alive {
            throw APVTError(.agent, "\(bundle.url.lastPathComponent) quit right after launch",
                            why: "the app crashed or exited on its own before the agent could announce itself." + said,
                            fix: ["open \"\(bundle.url.path)\"   # does it start without apvt?",
                                  "log show --last 1m --predicate 'process == \"\(bundle.executable.lastPathComponent)\"' | tail -20",
                                  "cat \(log)"])
        }
        let signature = preparation.signature
        var why = "the app is running, but dyld did not load the agent into it"
        if signature.hardenedRuntime {
            why += " (Hardened Runtime\(signature.getTaskAllow ? ", get-task-allow" : "")\(signature.teamIdentifier.map { ", team \($0)" } ?? ""): it may have refused the agent's signature)"
        }
        throw APVTError(.agent, "\(bundle.url.lastPathComponent) started, but no agent appeared in it within \(Describe.number(options.wait))s",
                        why: why + "." + said,
                        fix: ["apvt launch \"\(options.app)\" --wait 30   # a slow start",
                              "log show --last 1m --predicate 'eventMessage CONTAINS \"libapvt-agent\"' | tail -5   # what the system said about the library",
                              "build the app without the Hardened Runtime for testing: xcodebuild … ENABLE_HARDENED_RUNTIME=NO",
                              "cat \(log)"])
    }

    // MARK: - Agents

    public func agents(device: String?) throws -> [RunningAgent] {
        // A device names a simulator: no macOS app runs on one.
        guard device == nil else { return [] }
        return AgentClient.announcements().filter { $0.platform == id }.map { RunningAgent($0, platform: id) }
    }

    public func snapshot(of agent: RunningAgent, window: String?) throws -> Snapshot {
        try decodeSnapshot(AgentClient.send(AgentRequest(cmd: "snapshot", window: window), to: agent, silence: explainSilence(of: [agent])))
    }

    public func screenshot(of agent: RunningAgent, window: String?, to url: URL) throws {
        let data = try AgentClient.send(AgentRequest(cmd: "screenshot", window: window), to: agent, silence: explainSilence(of: [agent]))
        guard let response = try? JSONDecoder().decode(AgentScreenshotResponse.self, from: data),
              let png = Data(base64Encoded: response.pngBase64) else {
            throw APVTError(.agent, "the agent's screenshot did not decode", fix: [rebuildAdvice])
        }
        do { try png.write(to: url) } catch {
            throw APVTError(.io, "could not write \(url.path)", why: error.localizedDescription)
        }
    }

    // MARK: - Explanations

    public var focusAdvice: String {
        "click the text field first (screen point = the window's `at (x,y)` in the inspect header + the center of `apvt query <selector>`), then apvt type again"
    }

    public var rebuildAdvice: String {
        "apvt launch <App.app>   # the running agent may be older than this apvt: relaunching loads the current one"
    }

    public func explainSilence(of agents: [RunningAgent]) -> Explanation {
        Explanation(why: "the app's main thread is busy or still starting, or it is paused at a breakpoint (a macOS app answers in the background too).",
                    fix: ["resume the app in Xcode if it is stopped at a breakpoint",
                          "--wait 10   # if the app was just launched"])
    }

    public func explainNoAgent(app: String?, device: String?) throws -> Explanation {
        let path = app.flatMap { AppBundle.looksLikePath($0) ? $0 : nil } ?? "path/to/MyApp.app"
        return Explanation(why: "a macOS app has the agent only when apvt launch started it (or Xcode did, with the variables of apvt launch-env <App.app>).",
                           fix: ["apvt launch \(path)   # macOS: (re)starts the app with the agent; a Debug build"])
    }
}

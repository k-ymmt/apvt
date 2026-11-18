import APVTModel
import Foundation

/// The iOS Simulator: the agent gets into apps through the simulator's launchd environment,
/// answers on a unix socket under `/tmp`, and `simctl` takes screenshots.
public struct IOSSimulatorPlatform: Platform {
    public let id = Snapshot.iOSSimulator

    public init() {}

    // MARK: - Setup

    public func setup(_ options: SetupOptions) throws -> SetupReport {
        let device = try Simctl.resolveBooted(options.device)
        var actions: [String] = []
        let products = try AgentBuilder.ensure(rebuild: options.rebuild)
        actions.append(products.built ? "built the agent for the simulator (\(products.hash))" : "agent is up to date (\(products.hash))")

        let loader = products.loader.path
        let existing = try Simctl.launchdEnvironment(device.udid, "DYLD_INSERT_LIBRARIES")
        var libraries = existing?.split(separator: ":").map(String.init) ?? []
        if !libraries.contains(loader) {
            libraries.append(loader)
            try check(Simctl.spawn(device.udid, ["launchctl", "setenv", "DYLD_INSERT_LIBRARIES", libraries.joined(separator: ":")]),
                      "setting DYLD_INSERT_LIBRARIES in the simulator's launchd")
            actions.append("set DYLD_INSERT_LIBRARIES in \(device.name)'s launchd (apps launched from now on load the agent)")
        } else {
            actions.append("DYLD_INSERT_LIBRARIES already set in \(device.name)'s launchd")
        }
        try check(Simctl.spawn(device.udid, ["launchctl", "setenv", "APVT_AGENT_PATH", products.agent.path]),
                  "setting APVT_AGENT_PATH in the simulator's launchd")

        // UIKit answers accessibility (identifiers of SwiftUI views come from it) only when the
        // device says an assistive client exists. Read at app launch; invisible to the user.
        let ax = try Simctl.spawn(device.udid, ["defaults", "read", "com.apple.Accessibility", "ApplicationAccessibilityEnabled"])
        if ax.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            try check(Simctl.spawn(device.udid, ["defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"]),
                      "enabling application accessibility on the simulator")
            actions.append("enabled ApplicationAccessibilityEnabled on \(device.name) (SwiftUI accessibility identifiers need it)")
        }

        if LegacyLLDBHook.isInstalled {
            actions += try LegacyLLDBHook.uninstall()
        }

        var next: [String] = []
        let agents = Set(AgentClient.announcements().filter { $0.deviceUDID == device.udid }.map(\.bundleId))
        let running = try Simctl.runningApps(device.udid).filter { !$0.bundleId.hasPrefix("com.apple.") && !agents.contains($0.bundleId) }
        for app in running {
            next.append("xcrun simctl terminate \(device.udid) \(app.bundleId) && xcrun simctl launch \(device.udid) \(app.bundleId)   # running since before setup: relaunch to load the agent")
        }
        next.append("launch or relaunch the app with xcrun simctl launch (or from the home screen)")
        next.append("note: an app Xcode Runs under its debugger usually gets no agent — Xcode passes its own DYLD_INSERT_LIBRARIES (Main Thread Checker), which replaces apvt's; relaunch it with xcrun simctl launch (the build Xcode installed is used)")
        next.append("apvt inspect   # issues on the current screen")
        next.append("note: the launchd setting lasts until the simulator shuts down; run apvt setup again after a reboot")
        return SetupReport(device: "\(device.name) (\(device.runtime), \(device.udid))", actions: actions, next: next)
    }

    public func teardown(_ options: SetupOptions) throws -> SetupReport {
        var actions: [String] = []
        var deviceName = "-"
        if let device = try? Simctl.resolveBooted(options.device) {
            deviceName = "\(device.name) (\(device.runtime), \(device.udid))"
            let loader = AgentBuilder.currentLoader.path
            let existing = try Simctl.launchdEnvironment(device.udid, "DYLD_INSERT_LIBRARIES")
            let libraries = existing?.split(separator: ":").map(String.init) ?? []
            let remaining = libraries.filter { !$0.contains("libapvt-loader") }
            if remaining.count != libraries.count {
                if remaining.isEmpty {
                    try check(Simctl.spawn(device.udid, ["launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES"]), "unsetting DYLD_INSERT_LIBRARIES")
                } else {
                    try check(Simctl.spawn(device.udid, ["launchctl", "setenv", "DYLD_INSERT_LIBRARIES", remaining.joined(separator: ":")]), "restoring DYLD_INSERT_LIBRARIES")
                }
                actions.append("removed \(loader) from \(device.name)'s launchd")
            }
            _ = try Simctl.spawn(device.udid, ["launchctl", "unsetenv", "APVT_AGENT_PATH"])
            actions.append("apps launched from now on run without the agent; running apps keep it until they quit")
        } else if !LegacyLLDBHook.isInstalled {
            throw APVTError(.environment, "no booted simulator to tear down", fix: ["xcrun simctl list devices booted"])
        }
        actions += try LegacyLLDBHook.uninstall()
        return SetupReport(device: deviceName, actions: actions, next: [])
    }

    public func status(device query: String?) throws -> PlatformStatus {
        let all = try Simctl.devices()
        let booted: [Simctl.Device]
        if let query {
            booted = [try Simctl.resolveBooted(query)]
        } else {
            booted = all.filter(\.booted)
        }
        let announcements = AgentClient.announcements().filter { ($0.platform ?? id) == id }
        var devices: [PlatformStatus.Device] = []
        for device in booted {
            let env = try Simctl.launchdEnvironment(device.udid, "DYLD_INSERT_LIBRARIES") ?? ""
            let agents = announcements.filter { $0.deviceUDID == device.udid }.map { agent($0, device) }
            let withAgent = Set(agents.map(\.bundleId))
            let running = try Simctl.runningApps(device.udid)
                .filter { !$0.bundleId.hasPrefix("com.apple.") && !withAgent.contains($0.bundleId) }
                .map(\.bundleId)
            devices.append(.init(name: device.name, udid: device.udid, runtime: device.runtime,
                                 setUp: env.contains("libapvt-loader"), agents: agents, appsWithoutAgent: running))
        }
        return PlatformStatus(devices: devices, oldLLDBHook: LegacyLLDBHook.isInstalled, agentBuild: AgentBuilder.currentHash(), agents: nil)
    }

    // MARK: - Launch

    public func launch(_ options: LaunchOptions) throws -> LaunchReport {
        let device = try Simctl.resolveBooted(options.device)
        var actions: [String] = []
        // The loader in launchd is what gets the agent into the app: set it up when it is not.
        let libraries = try Simctl.launchdEnvironment(device.udid, "DYLD_INSERT_LIBRARIES") ?? ""
        let agentPath = try Simctl.launchdEnvironment(device.udid, "APVT_AGENT_PATH")
        if options.rebuild || !libraries.contains(AgentBuilder.currentLoader.path) || agentPath != AgentBuilder.currentAgent.path {
            actions += try setup(SetupOptions(device: device.udid, rebuild: options.rebuild)).actions
        } else {
            let products = try AgentBuilder.ensure()
            if products.built { actions.append("rebuilt the agent for the simulator (\(products.hash))") }
        }

        var bundleId = options.app
        if AppBundle.looksLikePath(options.app) {
            let bundle = try AppBundle(path: options.app)
            guard bundle.platform == .iOSSimulator else {
                throw APVTError(.usage, "\(bundle.url.lastPathComponent) is not an iOS Simulator app", why: bundle.platformDescription)
            }
            bundleId = bundle.bundleId
            try check(Shell.xcrun(["simctl", "install", device.udid, bundle.url.path], timeout: 180), "installing \(bundle.url.lastPathComponent) on \(device.name)")
            actions.append("installed \(bundle.url.lastPathComponent) on \(device.name)")
        }
        if try Simctl.runningApps(device.udid).contains(where: { $0.bundleId == bundleId }) {
            _ = try Shell.xcrun(["simctl", "terminate", device.udid, bundleId], timeout: 60)
            actions.append("terminated the running \(bundleId)")
        }
        let started = Date()
        let launched = try Shell.xcrun(["simctl", "launch", device.udid, bundleId] + options.arguments, timeout: 120)
        guard launched.ok else {
            let reason = launched.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw APVTError(.environment, "simctl could not launch \(bundleId) on \(device.name)", why: reason,
                            fix: ["xcrun simctl listapps \(device.udid) | grep -i \(bundleId)   # is it installed?",
                                  "apvt launch path/to/MyApp.app   # a simulator build: installs it, then launches"])
        }
        // `<bundle-id>: <pid>`
        let pid = launched.stdout.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        actions.append("launched \(bundleId) on \(device.name)" + (pid.map { " (pid \($0))" } ?? ""))

        let deadline = started.addingTimeInterval(max(options.wait, 1))
        var announced: RunningAgent?
        while true {
            let candidates = AgentClient.announcements().filter {
                $0.deviceUDID == device.udid && $0.bundleId == bundleId && (pid == nil ? $0.startedAt > started.addingTimeInterval(-1) : $0.pid == pid)
            }
            if let found = candidates.first.map({ agent($0, device) }) {
                announced = found
                if ping(found, timeout: 2) {
                    let settle = 1.5 - Date().timeIntervalSince(found.startedAt)
                    if settle > 0 { Thread.sleep(forTimeInterval: settle) }
                    return LaunchReport(platform: id, agent: found, actions: actions,
                                        next: ["apvt inspect --app \(bundleId)   # issues on the current screen"])
                }
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let alive = pid.map { kill($0, 0) == 0 } ?? true
        if let announced {
            let silence = explainSilence(of: [announced])
            throw APVTError(.agent, "\(announced.title) started but its agent did not answer within \(Describe.number(options.wait))s", why: silence.why, fix: silence.fix)
        }
        throw APVTError(.agent, alive ? "\(bundleId) started, but no agent appeared in it within \(Describe.number(options.wait))s" : "\(bundleId) quit right after launch",
                        why: alive ? "the app did not load the agent (a launch that replaced DYLD_INSERT_LIBRARIES?), or it is still starting."
                                   : "the app crashed or exited on its own; the agent never got to announce itself.",
                        fix: ["apvt launch \(options.app) --wait 30   # a slow start",
                              "xcrun simctl spawn \(device.udid) log show --last 1m --predicate 'process == \"\(bundleId.split(separator: ".").last ?? "")\"' | tail -20   # why it quit",
                              "apvt status"])
    }

    public func launchEnvironment(_ options: LaunchOptions) throws -> [String: String] {
        let products = try AgentBuilder.ensure(rebuild: options.rebuild)
        if let device = try? Simctl.resolveBooted(options.device) {
            // SwiftUI accessibility identifiers need it; read at app launch (see setup).
            _ = try? Simctl.spawn(device.udid, ["defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"])
        }
        return [
            "DYLD_INSERT_LIBRARIES": products.agent.path,
            "APVT_LOADED_BY": "env",
        ]
    }

    // MARK: - Agents

    public func agents(device query: String?) throws -> [RunningAgent] {
        let announcements = AgentClient.announcements().filter { ($0.platform ?? id) == id }
        let devices = try Simctl.devices()
        let byUDID = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
        if let query {
            let device = try Simctl.resolveBooted(query)
            return announcements.filter { $0.deviceUDID == device.udid }.map { agent($0, device) }
        }
        return announcements.compactMap { a in
            guard let udid = a.deviceUDID, let device = byUDID[udid], device.booted else { return nil }
            return agent(a, device)
        }
    }

    private func agent(_ a: AgentAnnouncement, _ device: Simctl.Device) -> RunningAgent {
        RunningAgent(a, platform: id, deviceName: device.name, runtime: device.runtime)
    }

    public func snapshot(of agent: RunningAgent, window: String?) throws -> Snapshot {
        guard window == nil else {
            throw APVTError(.usage, "--window is for macOS apps", why: "an iOS app's snapshot covers the whole screen, every window on it.")
        }
        var snapshot = try decodeSnapshot(AgentClient.send(AgentRequest(cmd: "snapshot"), to: agent))
        if let udid = agent.deviceUDID {
            snapshot.device = DeviceInfo(name: agent.deviceName ?? "?", udid: udid, runtime: agent.runtime ?? "?")
        }
        return snapshot
    }

    public func screenshot(of agent: RunningAgent, window: String?, to url: URL) throws {
        guard let udid = agent.deviceUDID else { throw APVTError(.agent, "the agent did not say which simulator it runs on") }
        let result = try Shell.xcrun(["simctl", "io", udid, "screenshot", "--type=png", url.path], timeout: 60)
        guard result.ok else {
            throw APVTError(.environment, "simctl could not take a screenshot", why: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Explanations

    public var focusAdvice: String {
        "tap the text field first (its hitPoint in the simulator's hierarchy, or the center of `apvt query <selector>`), then apvt type again"
    }

    public var rebuildAdvice: String {
        "apvt setup --rebuild   # the running agent may be older than this apvt; then relaunch the app"
    }

    public func explainSilence(of agents: [RunningAgent]) -> Explanation {
        Explanation(why: "an app in the background is suspended by iOS (only the foreground app answers), or it is paused at a breakpoint.",
                    fix: agents.map { "xcrun simctl launch \($0.deviceUDID ?? "booted") \($0.bundleId)   # brings it to the foreground" }
                        + ["resume the app in Xcode if it is stopped at a breakpoint",
                           "--wait 10   # if the app was just launched"])
    }

    public func explainNoAgent(app: String?, device query: String?) throws -> Explanation {
        let status = try status(device: query)
        guard !status.devices.isEmpty else {
            _ = try Simctl.resolveBooted(query) // throws the "nothing booted" error with its fix
            return Explanation(why: "no simulator is booted.")
        }
        var fix: [String] = []
        var why: String?
        for device in status.devices {
            if !device.setUp {
                why = "apvt setup has not been run on \(device.name) since it booted, so apps do not load the agent."
                fix.append("apvt setup --device \(device.udid)   # then relaunch the app")
                continue
            }
            let candidates = device.appsWithoutAgent.filter { app == nil || $0 == app }
            if !candidates.isEmpty {
                why = "the app was launched before apvt setup, or by Xcode's Run: Xcode passes its own DYLD_INSERT_LIBRARIES (Main Thread Checker), which replaces apvt's, so the app has no agent."
                for bundle in candidates {
                    fix.append("xcrun simctl terminate \(device.udid) \(bundle) && xcrun simctl launch \(device.udid) \(bundle)")
                }
                fix.append("from Xcode: stop the Run, then relaunch with the command above")
            } else {
                why = why ?? "the app is not running on \(device.name)."
                fix.append("xcrun simctl launch \(device.udid) \(app ?? "<bundle-id>")   # installs nothing: build/install it first (xcodebuild, or Xcode Run then this)")
            }
        }
        return Explanation(why: why, fix: fix)
    }

    private func check(_ result: Shell.Result, _ what: String) throws {
        guard result.ok else {
            throw APVTError(.environment, "\(what) failed", why: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

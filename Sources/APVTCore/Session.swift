import APVTModel
import Foundation

/// Which app a command looks at, and how its snapshot is obtained.
public struct Target: Sendable {
    public var device: String?
    public var app: String?
    /// Read a saved snapshot instead of asking a running app.
    public var snapshotFile: String?
    /// Seconds to wait for the app's agent to appear (right after launching it).
    public var wait: Double
    /// `ios-simulator` or `macos`; nil: wherever the one answering app is.
    public var platform: String?
    /// macOS: the window to look at, by number or title; nil: the key window.
    public var window: String?

    public init(device: String?, app: String?, snapshotFile: String?, wait: Double = 0, platform: String? = nil, window: String? = nil) {
        self.device = device
        self.app = app
        self.snapshotFile = snapshotFile
        self.wait = wait
        self.platform = platform
        self.window = window
    }
}

/// A running app's agent and the platform that talks to it.
public struct Connection: Sendable {
    public var platform: any Platform
    public var agent: RunningAgent

    public func snapshot(window: String?) throws -> Snapshot {
        do {
            return try platform.snapshot(of: agent, window: window)
        } catch var error as APVTError {
            error.message = "\(agent.title): \(error.message.replacingOccurrences(of: "the agent refused snapshot: ", with: ""))"
            throw error
        }
    }
}

public enum Session {
    public static let platforms: [any Platform] = [IOSSimulatorPlatform(), MacOSPlatform()]

    public static func platform(_ id: String) throws -> any Platform {
        guard let platform = platforms.first(where: { $0.id == id }) else {
            throw APVTError(.usage, "unknown platform \"\(id)\"", fix: ["--platform " + platforms.map(\.id).joined(separator: " | ")])
        }
        return platform
    }

    /// The platforms a target can be on: the named one; the simulator's when a device is named;
    /// else all of them.
    static func candidates(_ target: Target) throws -> [any Platform] {
        if let id = target.platform { return [try platform(id)] }
        if target.device != nil { return [try platform(Snapshot.iOSSimulator)] }
        return platforms
    }

    /// The one app the command is about: named by --app, or the only one whose agent answers,
    /// on whichever platform it runs. With --wait, waits for it to appear and to have run for
    /// a moment (its first screen built).
    public static func connect(_ target: Target) throws -> Connection {
        let searched = try candidates(target)
        let deadline = Date().addingTimeInterval(target.wait)
        while true {
            var found: [Connection] = []
            for platform in searched {
                let agents: [RunningAgent]
                // Searching everywhere, a platform that cannot even look (no simulator runtime
                // installed) has no agents; asked for by name, its error is the answer.
                if searched.count == 1 { agents = try platform.agents(device: target.device) } else { agents = (try? platform.agents(device: target.device)) ?? [] }
                found += agents.map { Connection(platform: platform, agent: $0) }
            }
            let candidates = target.app.map { app in
                found.filter { $0.agent.bundleId == app || $0.agent.name == app || String($0.agent.pid) == app }
            } ?? found
            // Ping together: each suspended app costs the whole timeout.
            nonisolated(unsafe) var answers = [Bool](repeating: false, count: candidates.count)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                let ok = candidates[i].platform.ping(candidates[i].agent, timeout: 2)
                answers[i] = ok
            }
            let answering = candidates.indices.filter { answers[$0] }.map { candidates[$0] }
            switch answering.count {
            case 1:
                // A just-launched app is still building its first screen.
                if target.wait > 0 {
                    let remaining = 1.5 - Date().timeIntervalSince(answering[0].agent.startedAt)
                    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                }
                return answering[0]
            case 0:
                // Keep waiting for the app that is being launched; other apps may be suspended.
                if Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                if candidates.isEmpty { throw try notRunning(searched, target) }
                let names = candidates.map(\.agent.title).joined(separator: ", ")
                var why: [String] = []
                var fix: [String] = []
                for platform in searched {
                    let silent = candidates.filter { $0.platform.id == platform.id }.map(\.agent)
                    guard !silent.isEmpty else { continue }
                    let explanation = platform.explainSilence(of: silent)
                    if let reason = explanation.why { why.append(reason) }
                    fix += explanation.fix.filter { !fix.contains($0) }
                }
                throw APVTError(.agent, "\(names) did not answer within 2s", why: why.joined(separator: " "), fix: fix)
            default:
                throw APVTError(.usage, "\(answering.count) apps with the agent are answering; say which one",
                                fix: answering.map { c in
                                    let a = c.agent
                                    let sameId = answering.filter { $0.agent.bundleId == a.bundleId }
                                    var option = "--app \(a.bundleId)"
                                    if sameId.count > 1 {
                                        // The same app on two platforms, or two instances of it.
                                        option = sameId.filter { $0.platform.id == c.platform.id }.count > 1 ? "--app \(a.pid)" : "--app \(a.bundleId) --platform \(c.platform.id)"
                                    }
                                    return "\(option)   # \(a.name), pid \(a.pid), \(a.place)"
                                })
            }
        }
    }

    private static func notRunning(_ searched: [any Platform], _ target: Target) throws -> APVTError {
        let what = target.app.map { "\($0) is not running with the agent" } ?? "no app with the apvt agent is running"
        if searched.count == 1 {
            let explanation = try searched[0].explainNoAgent(app: target.app, device: target.device)
            return APVTError(.environment, what, why: explanation.why, fix: explanation.fix + ["apvt status   # shows setup, running apps and their agents"])
        }
        // Looked everywhere: every platform says how an app gets the agent there.
        var why: [String] = []
        var fix: [String] = []
        for platform in searched {
            do {
                let explanation = try platform.explainNoAgent(app: target.app, device: target.device)
                if let reason = explanation.why { why.append(reason) }
                fix += explanation.fix
            } catch let error as APVTError {
                // "no simulator is booted": a fact about that platform, not the failure.
                why.append("\(platform.id): \(error.message).")
                fix += error.fix.map { "\($0)   # \(platform.id)" }.prefix(1)
            }
        }
        return APVTError(.environment, what, why: why.joined(separator: " "), fix: fix + ["apvt status   # shows setup, running apps and their agents"])
    }

    /// A fresh snapshot from the app, or a saved one.
    public static func snapshot(_ target: Target) throws -> (IndexedSnapshot, Connection?) {
        if let file = target.snapshotFile {
            let data: Data
            do { data = try Data(contentsOf: URL(fileURLWithPath: file)) } catch {
                throw APVTError(.io, "could not read \(file)", why: error.localizedDescription)
            }
            do {
                return (IndexedSnapshot(try JSONDecoder().decode(Snapshot.self, from: data)), nil)
            } catch {
                throw APVTError(.io, "\(file) is not an apvt snapshot", why: "\(error)", fix: ["apvt inspect --save \(file)   # writes one"])
            }
        }
        let connection = try connect(target)
        return (IndexedSnapshot(try connection.snapshot(window: target.window)), connection)
    }

    public static func save(_ snapshot: Snapshot, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(snapshot).write(to: URL(fileURLWithPath: path))
        } catch {
            throw APVTError(.io, "could not write \(path)", why: error.localizedDescription)
        }
    }
}

extension Session {
    /// Types into whatever has keyboard focus in the app (`apvt type`).
    public static func type(_ target: Target, text: String, replace: Bool, submit: Bool) throws -> (AgentTypeResponse, RunningAgent) {
        let connection = try connect(target)
        let (platform, agent) = (connection.platform, connection.agent)
        let data: Data
        do {
            data = try platform.rawRequest(AgentRequest(cmd: "type", text: text, replace: replace, submit: submit, window: target.window), to: agent)
        } catch var error as APVTError {
            // The agent answers ok:false when nothing has focus; say what to do about it.
            error.message = "\(agent.title): \(error.message.replacingOccurrences(of: "the agent refused type: ", with: ""))"
            if error.fix.isEmpty {
                error.fix = [platform.focusAdvice, platform.rebuildAdvice + "   # if the agent says unknown cmd type"]
            }
            throw error
        }
        guard let response = try? JSONDecoder().decode(AgentTypeResponse.self, from: data) else {
            // Typing (above all --submit) can run app code that crashes before the agent answers.
            if !platform.ping(agent, timeout: 2) {
                throw APVTError(.agent, "\(agent.title) stopped answering while typing",
                                why: "the app most likely crashed or froze in code that the text or Return triggered (an .onSubmit, a delegate, a binding).",
                                fix: ["look at the app (a screenshot, Xcode's console or the crash log) for the reason",
                                      "apvt status   # the app is gone from the list if it crashed"])
            }
            let message = (try? JSONDecoder().decode(AgentErrorResponse.self, from: data))?.error ?? String(decoding: data, as: UTF8.self)
            throw APVTError(.agent, "\(agent.title): the agent did not type", why: message, fix: [platform.rebuildAdvice])
        }
        guard response.ok else {
            throw APVTError(.agent, "\(agent.title): \(response.error ?? "typing failed")",
                            why: response.focused.map { "focused: \($0)" }, fix: [platform.focusAdvice])
        }
        return (response, agent)
    }

    /// The platform an app reference belongs to: a `.app` says it in its Info.plist; anything
    /// else is the bundle id of an app installed on a simulator.
    static func platform(forApp app: String, named: String?) throws -> any Platform {
        if let named { return try platform(named) }
        guard AppBundle.looksLikePath(app) else { return try platform(Snapshot.iOSSimulator) }
        let bundle = try AppBundle(path: app)
        switch bundle.platform {
        case .macOS: return try platform(Snapshot.macOS)
        case .iOSSimulator: return try platform(Snapshot.iOSSimulator)
        case .iOSDevice:
            throw APVTError(.usage, "\(bundle.url.lastPathComponent) cannot be launched by apvt", why: bundle.platformDescription,
                            fix: ["build it for the simulator: xcodebuild … -destination 'platform=iOS Simulator,name=<device>' build"])
        case .macCatalyst, .other:
            throw APVTError(.usage, "\(bundle.url.lastPathComponent) cannot be launched by apvt", why: bundle.platformDescription)
        }
    }

    /// Starts (or restarts) an app with the agent and waits for it to answer (`apvt launch`).
    public static func launch(_ options: LaunchOptions, platform named: String? = nil) throws -> LaunchReport {
        try platform(forApp: options.app, named: named).launch(options)
    }

    /// Environment that makes an app launched by someone else (Xcode's Run, Xcode MCP, a scheme)
    /// load the agent. `app`: a macOS `.app`; nil: the iOS Simulator.
    public static func launchEnvironment(app: String?, device: String?, identity: String? = nil) throws -> [String: String] {
        guard let app else {
            return try platform(Snapshot.iOSSimulator).launchEnvironment(LaunchOptions(app: "", device: device))
        }
        let platform = try platform(forApp: app, named: nil)
        return try platform.launchEnvironment(LaunchOptions(app: app, device: device, identity: identity))
    }

    public static func launchEnvironment(device: String?) throws -> [String: String] {
        try launchEnvironment(app: nil, device: device)
    }

    /// Booted simulators and their agents, and the macOS apps that have one.
    public static func status(device: String?) throws -> PlatformStatus {
        var status = try platform(Snapshot.iOSSimulator).status(device: device)
        if device == nil {
            status.agents = try platform(Snapshot.macOS).agents(device: nil)
        }
        return status
    }
}

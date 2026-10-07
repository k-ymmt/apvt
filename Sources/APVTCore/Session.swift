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

    public init(device: String?, app: String?, snapshotFile: String?, wait: Double = 0) {
        self.device = device
        self.app = app
        self.snapshotFile = snapshotFile
        self.wait = wait
    }
}

public enum Session {
    public static let platforms: [any Platform] = [IOSSimulatorPlatform()]

    public static func platform(_ id: String) throws -> any Platform {
        guard let platform = platforms.first(where: { $0.id == id }) else {
            throw APVTError(.usage, "unknown platform \"\(id)\"", fix: ["--platform " + platforms.map(\.id).joined(separator: " | ")])
        }
        return platform
    }

    /// The one app the command is about: named by --app, or the only one whose agent answers.
    /// With --wait, waits for it to appear and to have run for a moment (its first screen built).
    public static func agent(_ platform: any Platform, _ target: Target) throws -> RunningAgent {
        let deadline = Date().addingTimeInterval(target.wait)
        while true {
            let agents = try platform.agents(device: target.device)
            let candidates = target.app.map { app in agents.filter { $0.bundleId == app || $0.name == app } } ?? agents
            // Ping together: each suspended app costs the whole timeout.
            nonisolated(unsafe) var answers = [Bool](repeating: false, count: candidates.count)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                let ok = platform.ping(candidates[i], timeout: 2)
                answers[i] = ok
            }
            let answering = candidates.indices.filter { answers[$0] }.map { candidates[$0] }
            switch answering.count {
            case 1:
                // A just-launched app is still building its first screen.
                if target.wait > 0 {
                    let remaining = 1.5 - Date().timeIntervalSince(answering[0].startedAt)
                    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                }
                return answering[0]
            case 0:
                // Keep waiting for the app that is being launched; other apps may be suspended.
                if Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                if candidates.isEmpty { throw try notRunning(platform, target, app: target.app) }
                let names = candidates.map(\.title).joined(separator: ", ")
                throw APVTError(.agent, "\(names) did not answer within 2s",
                                why: "an app in the background is suspended by iOS (only the foreground app answers), or it is paused at a breakpoint.",
                                fix: candidates.map { "xcrun simctl launch \($0.deviceUDID ?? "booted") \($0.bundleId)   # brings it to the foreground" }
                                    + ["resume the app in Xcode if it is stopped at a breakpoint",
                                       "--wait 10   # if the app was just launched"])
            default:
                throw APVTError(.usage, "\(answering.count) apps with the agent are answering; say which one",
                                fix: answering.map { "--app \($0.bundleId)   # \($0.name), pid \($0.pid), \($0.deviceName ?? "")" })
            }
        }
    }

    private static func notRunning(_ platform: any Platform, _ target: Target, app: String?) throws -> APVTError {
        let status = try platform.status(device: target.device)
        guard !status.devices.isEmpty else {
            _ = try Simctl.resolveBooted(target.device) // throws the "nothing booted" error with its fix
            return APVTError(.environment, "no booted simulator")
        }
        let what = app.map { "\($0) is not running with the agent" } ?? "no app with the apvt agent is running"
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
        fix.append("apvt status   # shows setup, running apps and their agents")
        return APVTError(.environment, what, why: why, fix: fix)
    }

    /// A fresh snapshot from the app, or a saved one.
    public static func snapshot(_ platform: any Platform, _ target: Target) throws -> (IndexedSnapshot, RunningAgent?) {
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
        let agent = try Session.agent(platform, target)
        do {
            return (IndexedSnapshot(try platform.snapshot(of: agent)), agent)
        } catch var error as APVTError {
            error.message = "\(agent.title): \(error.message)"
            throw error
        }
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
    public static func type(_ platform: any Platform, _ target: Target, text: String, replace: Bool, submit: Bool) throws -> (AgentTypeResponse, RunningAgent) {
        let agent = try Session.agent(platform, target)
        let data: Data
        do {
            data = try platform.rawRequest(AgentRequest(cmd: "type", text: text, replace: replace, submit: submit), to: agent)
        } catch var error as APVTError {
            // The agent answers ok:false when nothing has focus; say what to do about it.
            error.message = "\(agent.title): \(error.message.replacingOccurrences(of: "the agent refused type: ", with: ""))"
            if error.fix.isEmpty {
                error.fix = ["tap the text field first (its hitPoint in the simulator's hierarchy, or the center of `apvt query <selector>`), then apvt type again",
                             "apvt setup --rebuild   # if the agent says unknown cmd type: it predates apvt type; then relaunch the app"]
            }
            throw error
        }
        guard let response = try? JSONDecoder().decode(AgentTypeResponse.self, from: data) else {
            let message = (try? JSONDecoder().decode(AgentErrorResponse.self, from: data))?.error ?? String(decoding: data, as: UTF8.self)
            throw APVTError(.agent, "\(agent.title): the agent did not type", why: message,
                            fix: ["apvt setup --rebuild   # the running agent may be older than this apvt; then relaunch the app"])
        }
        guard response.ok else {
            throw APVTError(.agent, "\(agent.title): \(response.error ?? "typing failed")",
                            why: response.focused.map { "focused: \($0)" },
                            fix: ["tap the text field (its hitPoint in the hierarchy, or the center of `apvt query <selector>`), then apvt type again"])
        }
        return (response, agent)
    }

    /// Environment that makes an app launched by someone else (Xcode's Run, Xcode MCP
    /// `DeviceInteractionInstallAndRun`, a scheme) load the agent, without `apvt setup`'s launchd change.
    public static func launchEnvironment(device: String?) throws -> [String: String] {
        let products = try AgentBuilder.ensure()
        if let device = try? Simctl.resolveBooted(device) {
            // SwiftUI accessibility identifiers need it; read at app launch (see setup).
            _ = try? Simctl.spawn(device.udid, ["defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"])
        }
        return [
            "DYLD_INSERT_LIBRARIES": products.agent.path,
            "APVT_LOADED_BY": "env",
        ]
    }
}

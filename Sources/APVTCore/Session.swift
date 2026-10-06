import APVTModel
import Foundation

/// Which app a command looks at, and how its snapshot is obtained.
public struct Target: Sendable {
    public var device: String?
    public var app: String?
    /// Read a saved snapshot instead of asking a running app.
    public var snapshotFile: String?

    public init(device: String?, app: String?, snapshotFile: String?) {
        self.device = device
        self.app = app
        self.snapshotFile = snapshotFile
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

    /// The one app the command is about.
    public static func agent(_ platform: any Platform, _ target: Target) throws -> RunningAgent {
        let agents = try platform.agents(device: target.device)
        if let app = target.app {
            let matches = agents.filter { $0.bundleId == app || $0.name == app }
            if let first = matches.first { return first }
            throw try notRunning(platform, target, app: app)
        }
        switch agents.count {
        case 1: return agents[0]
        case 0: throw try notRunning(platform, target, app: nil)
        default:
            throw APVTError(.usage, "\(agents.count) apps with the agent are running; say which one",
                            fix: agents.map { "--app \($0.bundleId)   # \($0.name), pid \($0.pid), \($0.deviceName ?? "")" })
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
                fix.append("apvt setup --device \(device.udid)\(status.xcodeHook ? " --xcode" : "")   # then relaunch the app")
                continue
            }
            let candidates = device.appsWithoutAgent.filter { app == nil || $0 == app }
            if !candidates.isEmpty {
                why = "the app was launched before apvt setup (or by Xcode without the --xcode hook), so it has no agent."
                for bundle in candidates {
                    fix.append("xcrun simctl terminate \(device.udid) \(bundle) && xcrun simctl launch \(device.udid) \(bundle)")
                }
                if !status.xcodeHook { fix.append("apvt setup --xcode   # if the app is run from Xcode, then Run again") }
            } else {
                why = why ?? "the app is not running on \(device.name)."
                fix.append("xcrun simctl launch \(device.udid) \(app ?? "<bundle-id>")   # or Run it from Xcode")
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
        return (IndexedSnapshot(try platform.snapshot(of: agent)), agent)
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

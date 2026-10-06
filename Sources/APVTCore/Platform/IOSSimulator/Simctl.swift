import Foundation

/// `xcrun simctl`, and what it says about devices.
enum Simctl {
    struct Device: Sendable {
        var udid: String
        var name: String
        var state: String
        var runtime: String
        var booted: Bool { state == "Booted" }
    }

    static func devices() throws -> [Device] {
        let result = try Shell.xcrun(["simctl", "list", "devices", "-j"], timeout: 60)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else {
            throw APVTError(.environment, "`xcrun simctl list devices` failed",
                            why: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                            fix: ["xcode-select -p   # Xcode must be selected", "sudo xcode-select -s /Applications/Xcode.app"])
        }
        var devices: [Device] = []
        for (runtimeId, list) in byRuntime {
            let runtime = runtimeName(runtimeId)
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                devices.append(Device(udid: udid, name: name, state: d["state"] as? String ?? "", runtime: runtime))
            }
        }
        return devices
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`.
    static func runtimeName(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    /// The booted device `query` names (UDID or name), or the only booted one.
    static func resolveBooted(_ query: String?) throws -> Device {
        let all = try devices()
        let booted = all.filter(\.booted)
        if let query, query != "booted" {
            let matches = all.filter { $0.udid.caseInsensitiveCompare(query) == .orderedSame || $0.name == query }
            guard let device = matches.first(where: \.booted) ?? matches.first else {
                throw APVTError(.usage, "no simulator named or with UDID \"\(query)\"",
                                fix: ["xcrun simctl list devices available   # pick a name or UDID"])
            }
            guard device.booted else {
                throw APVTError(.environment, "\(device.name) (\(device.runtime)) is not booted",
                                fix: ["xcrun simctl boot \(device.udid) && xcrun simctl bootstatus \(device.udid)"])
            }
            if matches.filter(\.booted).count > 1 {
                throw APVTError(.usage, "more than one booted simulator is named \"\(query)\"",
                                fix: matches.filter(\.booted).map { "--device \($0.udid)   # \($0.name) \($0.runtime)" })
            }
            return device
        }
        switch booted.count {
        case 1: return booted[0]
        case 0:
            let candidate = all.filter { $0.runtime.hasPrefix("iOS") }.sorted { $0.runtime > $1.runtime }.first
            throw APVTError(.environment, "no iOS simulator is booted",
                            fix: candidate.map { ["xcrun simctl boot \($0.udid) && xcrun simctl bootstatus \($0.udid)   # \($0.name) \($0.runtime)"] }
                                ?? ["xcrun simctl list devices available"])
        default:
            throw APVTError(.usage, "\(booted.count) simulators are booted; say which one",
                            fix: booted.map { "--device \($0.udid)   # \($0.name) \($0.runtime)" })
        }
    }

    static func spawn(_ udid: String, _ arguments: [String]) throws -> Shell.Result {
        try Shell.xcrun(["simctl", "spawn", udid] + arguments, timeout: 60)
    }

    static func launchdEnvironment(_ udid: String, _ name: String) throws -> String? {
        let r = try spawn(udid, ["launchctl", "getenv", name])
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Bundle ids of user apps running on the device (`UIKitApplication:<bundle-id>[…]`).
    static func runningApps(_ udid: String) throws -> [(bundleId: String, pid: Int32)] {
        let r = try spawn(udid, ["launchctl", "list"])
        var apps: [(String, Int32)] = []
        for line in r.stdout.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count == 3, let pid = Int32(columns[0]), columns[2].hasPrefix("UIKitApplication:") else { continue }
            let label = columns[2].dropFirst("UIKitApplication:".count)
            let bundle = label.split(separator: "[").first.map(String.init) ?? String(label)
            apps.append((bundle, pid))
        }
        return apps
    }
}

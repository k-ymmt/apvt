import APVTModel
import Foundation

/// The iOS Simulator: the agent gets into apps through the simulator's launchd environment
/// answers on a unix socket under `/tmp`, and `simctl` takes screenshots.
public struct IOSSimulatorPlatform: Platform {
    public let id = "ios-simulator"

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
        let announcements = AgentClient.announcements()
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
        return PlatformStatus(devices: devices, oldLLDBHook: LegacyLLDBHook.isInstalled, agentBuild: AgentBuilder.currentHash())
    }

    // MARK: - Agents

    public func agents(device query: String?) throws -> [RunningAgent] {
        let announcements = AgentClient.announcements()
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
        RunningAgent(bundleId: a.bundleId, name: a.name, pid: a.pid, socket: a.socket, deviceUDID: device.udid,
                     deviceName: device.name, runtime: device.runtime, swiftUIDebug: a.swiftUIDebug, loadedBy: a.loadedBy,
                     startedAt: a.startedAt)
    }

    public func snapshot(of agent: RunningAgent) throws -> Snapshot {
        let data = try AgentClient.send(AgentRequest(cmd: "snapshot"), socket: agent.socket)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshot: Snapshot
        do {
            snapshot = try decoder.decode(AgentSnapshotResponse.self, from: data).snapshot
        } catch {
            throw APVTError(.agent, "the agent's snapshot did not decode", why: "\(error)",
                            fix: ["apvt setup --rebuild   # the running agent may be older than this apvt; then relaunch the app"])
        }
        if let udid = agent.deviceUDID {
            snapshot.device = DeviceInfo(name: agent.deviceName ?? "?", udid: udid, runtime: agent.runtime ?? "?")
        }
        return snapshot
    }

    public func screenshot(of agent: RunningAgent, to url: URL) throws {
        guard let udid = agent.deviceUDID else { throw APVTError(.agent, "the agent did not say which simulator it runs on") }
        let result = try Shell.xcrun(["simctl", "io", udid, "screenshot", "--type=png", url.path], timeout: 60)
        guard result.ok else {
            throw APVTError(.environment, "simctl could not take a screenshot", why: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func ping(_ agent: RunningAgent, timeout: TimeInterval) -> Bool {
        (try? AgentClient.send(AgentRequest(cmd: "ping"), socket: agent.socket, timeout: timeout)) != nil
    }

    public func rawRequest(_ request: AgentRequest, to agent: RunningAgent) throws -> Data {
        try AgentClient.send(request, socket: agent.socket)
    }

    private func check(_ result: Shell.Result, _ what: String) throws {
        guard result.ok else {
            throw APVTError(.environment, "\(what) failed", why: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

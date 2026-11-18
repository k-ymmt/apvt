import APVTModel
import Foundation

/// What apvt needs from a platform: how the agent gets into an app, where agents are found,
/// screenshots, and the words for what only that platform can explain. Everything above this
/// line (analysis, selectors, assertions, output) is shared.
public protocol Platform: Sendable {
    /// `ios-simulator`, `macos`.
    var id: String { get }

    /// Make apps started from now on load the agent.
    func setup(_ options: SetupOptions) throws -> SetupReport
    /// Undo `setup`.
    func teardown(_ options: SetupOptions) throws -> SetupReport
    func status(device: String?) throws -> PlatformStatus

    /// Start (or restart) an app with the agent in it and wait for the agent to answer.
    func launch(_ options: LaunchOptions) throws -> LaunchReport
    /// Environment variables that make a launch by someone else (Xcode) load the agent.
    func launchEnvironment(_ options: LaunchOptions) throws -> [String: String]

    /// Apps whose agent has announced itself.
    func agents(device: String?) throws -> [RunningAgent]
    /// `window`: on platforms with several windows per app, the one to look at.
    func snapshot(of agent: RunningAgent, window: String?) throws -> Snapshot
    /// A PNG of what the snapshot's frames are measured against, at its scale.
    func screenshot(of agent: RunningAgent, window: String?, to url: URL) throws

    /// Why no app has the agent, and the commands that give it one.
    func explainNoAgent(app: String?, device: String?) throws -> Explanation
    /// Why announced agents do not answer, and what brings them back.
    func explainSilence(of agents: [RunningAgent]) -> Explanation
    /// How to give a text field keyboard focus, for `apvt type`.
    var focusAdvice: String { get }
    /// The command that replaces an agent older than this apvt.
    var rebuildAdvice: String { get }
}

extension Platform {
    /// Whether the agent answers within `timeout`.
    public func ping(_ agent: RunningAgent, timeout: TimeInterval) -> Bool {
        (try? AgentClient.send(AgentRequest(cmd: "ping"), to: agent, timeout: timeout)) != nil
    }

    /// Raw responses (`swiftui-raw`, `methods`, `type`).
    public func rawRequest(_ request: AgentRequest, to agent: RunningAgent) throws -> Data {
        try AgentClient.send(request, to: agent, silence: explainSilence(of: [agent]))
    }

    func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AgentSnapshotResponse.self, from: data).snapshot
        } catch {
            throw APVTError(.agent, "the agent's snapshot did not decode", why: "\(error)", fix: [rebuildAdvice])
        }
    }
}

public struct Explanation: Sendable {
    public var why: String?
    public var fix: [String]

    public init(why: String? = nil, fix: [String] = []) {
        self.why = why
        self.fix = fix
    }
}

public struct SetupOptions: Sendable {
    public var device: String?
    public var rebuild: Bool

    public init(device: String?, rebuild: Bool = false) {
        self.device = device
        self.rebuild = rebuild
    }
}

public struct SetupReport: Sendable, Codable {
    public var device: String
    public var actions: [String]
    public var next: [String]
}

public struct LaunchOptions: Sendable {
    /// A `.app` bundle, or (iOS Simulator) the bundle id of an installed app.
    public var app: String
    public var device: String?
    /// Passed to the app as its command line arguments.
    public var arguments: [String]
    /// Seconds to wait for the agent to answer.
    public var wait: Double
    /// macOS: the code signing identity for the agent, instead of the one apvt would pick.
    public var identity: String?
    public var rebuild: Bool

    public init(app: String, device: String? = nil, arguments: [String] = [], wait: Double = 15, identity: String? = nil, rebuild: Bool = false) {
        self.app = app
        self.device = device
        self.arguments = arguments
        self.wait = wait
        self.identity = identity
        self.rebuild = rebuild
    }
}

public struct LaunchReport: Sendable, Codable {
    public var platform: String
    public var agent: RunningAgent
    public var actions: [String]
    public var next: [String]
}

public struct PlatformStatus: Sendable, Codable {
    public struct Device: Sendable, Codable {
        public var name: String
        public var udid: String
        public var runtime: String
        public var setUp: Bool
        public var agents: [RunningAgent]
        /// User apps running without the agent (started before setup).
        public var appsWithoutAgent: [String]
    }

    public var devices: [Device]
    /// An LLDB init-file hook from an earlier apvt is still installed (`apvt teardown` removes it).
    public var oldLLDBHook: Bool
    public var agentBuild: String?
    /// Apps with the agent that run on no device: macOS apps.
    public var agents: [RunningAgent]?
}

public struct RunningAgent: Sendable, Codable {
    public var bundleId: String
    public var name: String
    public var pid: Int32
    /// The unix socket, or the request pipe when `transport` is `pipe`.
    public var socket: String
    public var platform: String
    public var transport: String?
    public var bundlePath: String?
    public var deviceUDID: String?
    public var deviceName: String?
    public var runtime: String?
    public var swiftUIDebug: Bool
    public var loadedBy: String
    public var startedAt: Date

    public init(_ a: AgentAnnouncement, platform: String, deviceName: String? = nil, runtime: String? = nil) {
        bundleId = a.bundleId
        name = a.name
        pid = a.pid
        socket = a.socket
        self.platform = platform
        transport = a.transport
        bundlePath = a.bundlePath
        deviceUDID = a.deviceUDID
        self.deviceName = deviceName
        self.runtime = runtime
        swiftUIDebug = a.swiftUIDebug
        loadedBy = a.loadedBy
        startedAt = a.startedAt
    }

    /// `Laperm (app.kymmt.Laperm, pid 4012)`.
    public var title: String { "\(name) (\(bundleId), pid \(pid))" }
    /// `iPhone 17 Pro` or `macOS`.
    public var place: String { deviceName ?? (platform == Snapshot.macOS ? "macOS" : platform) }
}

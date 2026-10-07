import APVTModel
import Foundation

/// What apvt needs from a platform. iOS Simulator implements it today; a macOS or visionOS
/// simulator platform would supply its own injection, discovery and screenshots and reuse
/// everything above this line (analysis, selectors, assertions, output).
public protocol Platform: Sendable {
    /// `ios-simulator`.
    var id: String { get }

    /// Make apps started from now on load the agent.
    func setup(_ options: SetupOptions) throws -> SetupReport
    /// Undo `setup`.
    func teardown(_ options: SetupOptions) throws -> SetupReport
    func status(device: String?) throws -> PlatformStatus

    /// Apps whose agent is answering.
    func agents(device: String?) throws -> [RunningAgent]
    func snapshot(of agent: RunningAgent) throws -> Snapshot
    /// A PNG of the device's screen, at the screen scale.
    func screenshot(of agent: RunningAgent, to url: URL) throws
    /// Whether the agent answers within `timeout` (an app in the background is suspended and does not).
    func ping(_ agent: RunningAgent, timeout: TimeInterval) -> Bool
    /// Raw responses for diagnostics (`swiftui-raw`, `methods`).
    func rawRequest(_ request: AgentRequest, to agent: RunningAgent) throws -> Data
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
}

public struct RunningAgent: Sendable, Codable {
    public var bundleId: String
    public var name: String
    public var pid: Int32
    public var socket: String
    public var deviceUDID: String?
    public var deviceName: String?
    public var runtime: String?
    public var swiftUIDebug: Bool
    public var loadedBy: String
    public var startedAt: Date

    /// `Laperm (app.kymmt.Laperm, pid 4012)`.
    public var title: String { "\(name) (\(bundleId), pid \(pid))" }
}

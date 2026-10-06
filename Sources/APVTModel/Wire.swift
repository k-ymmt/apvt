import Foundation

/// The host ↔ agent protocol: one JSON line in, one JSON line out, per unix-socket connection.
public enum AgentWire {
    public static let version = 1

    /// `/tmp/apvt-<uid>/`. A simulator process shares the host's filesystem and user, so the
    /// host connects to the same path. Kept short: `sun_path` holds 104 bytes.
    public static func directory(uid: UInt32) -> String { "/tmp/apvt-\(uid)" }
    public static func socketPath(uid: UInt32, pid: Int32) -> String { "\(directory(uid: uid))/\(pid).sock" }
    /// The agent announces itself here so the host can find an app by bundle id.
    public static func announcementPath(uid: UInt32, pid: Int32) -> String { "\(directory(uid: uid))/\(pid).json" }

    /// Environment the agent reads.
    public static let swiftUIDebugVariable = "SWIFTUI_VIEW_DEBUG"
    public static let agentPathVariable = "APVT_AGENT_PATH"
}

public struct AgentRequest: Codable, Sendable {
    /// `ping`, `snapshot`, `swiftui-raw`, `methods`.
    public var cmd: String
    /// For `methods`: a class name and an optional substring.
    public var className: String?
    public var match: String?

    public init(cmd: String, className: String? = nil, match: String? = nil) {
        self.cmd = cmd
        self.className = className
        self.match = match
    }
}

/// Written next to the socket when the agent starts.
public struct AgentAnnouncement: Codable, Sendable {
    public var wire: Int
    public var pid: Int32
    public var bundleId: String
    public var name: String
    /// `SIMULATOR_UDID` of the process, so the host can tell two simulators apart.
    public var deviceUDID: String?
    public var socket: String
    /// Whether SwiftUI was told to record debug data before its first view graph.
    public var swiftUIDebug: Bool
    /// How the agent got in: `launchd` (apvt setup), `lldb` (Xcode hook), `env`.
    public var loadedBy: String
    public var startedAt: Date

    public init(wire: Int, pid: Int32, bundleId: String, name: String, deviceUDID: String?,
                socket: String, swiftUIDebug: Bool, loadedBy: String, startedAt: Date) {
        self.wire = wire
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.deviceUDID = deviceUDID
        self.socket = socket
        self.swiftUIDebug = swiftUIDebug
        self.loadedBy = loadedBy
        self.startedAt = startedAt
    }
}

public struct AgentPing: Codable, Sendable {
    public var ok: Bool
    public var announcement: AgentAnnouncement
}

public struct AgentSnapshotResponse: Codable, Sendable {
    public var ok: Bool
    public var snapshot: Snapshot
    /// Milliseconds spent collecting, for the curious and for performance work.
    public var elapsedMs: Int
}

public struct AgentErrorResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String

    public init(error: String) {
        self.ok = false
        self.error = error
    }
}

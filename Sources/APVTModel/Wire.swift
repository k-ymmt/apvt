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

    /// A sandboxed macOS app may not bind a socket outside its container, but with the host's
    /// sandbox extension token it may create named pipes here: requests arrive on `.in`,
    /// answers leave on `.out`. One JSON line each way; an answer is preceded by a line holding
    /// the request's `id`, so an answer nobody waited for is never taken for the next one.
    public static func pipeInPath(uid: UInt32, pid: Int32) -> String { "\(directory(uid: uid))/\(pid).in" }
    public static func pipeOutPath(uid: UInt32, pid: Int32) -> String { "\(directory(uid: uid))/\(pid).out" }
    /// Hosts take this lock around a request so two of them never interleave on the pipes.
    public static func pipeLockPath(uid: UInt32, pid: Int32) -> String { "\(directory(uid: uid))/\(pid).lock" }

    public static let transportSocket = "socket"
    public static let transportPipe = "pipe"

    /// Environment the agent reads.
    public static let swiftUIDebugVariable = "SWIFTUI_VIEW_DEBUG"
    public static let agentPathVariable = "APVT_AGENT_PATH"
    /// A sandbox extension token for `directory(uid:)`, issued by the host (macOS, App Sandbox).
    public static let sandboxTokenVariable = "APVT_SANDBOX_TOKEN"
}

public struct AgentRequest: Codable, Sendable {
    /// `ping`, `snapshot`, `swiftui-raw`, `methods`, `type`, `screenshot`.
    public var cmd: String
    /// Echoed before the answer on the pipe transport.
    public var id: String?
    /// macOS: the window `snapshot`, `screenshot`, `swiftui-raw` and `type` are about — its
    /// number or (part of) its title. nil: the key window.
    public var window: String?
    /// For `methods`: a class name and an optional substring.
    public var className: String?
    public var match: String?
    /// For `type`: the text, whether it replaces the field's text, and whether Return follows.
    public var text: String?
    public var replace: Bool?
    public var submit: Bool?

    public init(cmd: String, className: String? = nil, match: String? = nil,
                text: String? = nil, replace: Bool? = nil, submit: Bool? = nil, window: String? = nil) {
        self.cmd = cmd
        self.window = window
        self.className = className
        self.match = match
        self.text = text
        self.replace = replace
        self.submit = submit
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
    /// The unix socket; with the pipe transport, the request pipe (`AgentWire.pipeInPath`).
    public var socket: String
    /// `ios-simulator` (also when absent: agents from before macOS support) or `macos`.
    public var platform: String?
    /// `socket` (also when absent) or `pipe`.
    public var transport: String?
    /// The app bundle the process runs from (macOS: what `apvt launch` was given).
    public var bundlePath: String?
    /// Whether SwiftUI was told to record debug data before its first view graph.
    public var swiftUIDebug: Bool
    /// How the agent got in: `launchd` (apvt setup), `launch` (apvt launch), `env` (launch-env).
    public var loadedBy: String
    public var startedAt: Date

    public init(wire: Int, pid: Int32, bundleId: String, name: String, deviceUDID: String?,
                socket: String, platform: String? = nil, transport: String? = nil, bundlePath: String? = nil,
                swiftUIDebug: Bool, loadedBy: String, startedAt: Date) {
        self.wire = wire
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.deviceUDID = deviceUDID
        self.socket = socket
        self.platform = platform
        self.transport = transport
        self.bundlePath = bundlePath
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

/// The answer to `screenshot` (macOS): the window as the app itself renders it. No screen
/// recording permission is involved: a process may always capture its own windows.
public struct AgentScreenshotResponse: Codable, Sendable {
    public var ok: Bool
    public var pngBase64: String
    public var window: WindowInfo?

    public init(pngBase64: String, window: WindowInfo?) {
        self.ok = true
        self.pngBase64 = pngBase64
        self.window = window
    }
}

/// The answer to `type`: which responder got the text and its value afterwards.
public struct AgentTypeResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    /// `UITextField #new-task placeholder:"New task"`.
    public var focused: String?
    public var value: String?
    /// What has keyboard focus after typing (nil: nothing, e.g. after submit ended editing).
    public var focusedAfter: String?

    public init(ok: Bool, error: String? = nil, focused: String? = nil, value: String? = nil, focusedAfter: String? = nil) {
        self.ok = ok
        self.error = error
        self.focused = focused
        self.value = value
        self.focusedAfter = focusedAfter
    }
}

public struct AgentErrorResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String

    public init(error: String) {
        self.ok = false
        self.error = error
    }
}

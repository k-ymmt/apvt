import Foundation
import UIKit

/// One request per connection: a JSON line in, a JSON line out. UIKit work runs on the main
/// thread; the socket lives on its own thread so a busy main thread only delays the answer.
enum AgentServer {
    static func start() {
        let thread = Thread { serve() }
        thread.name = "apvt-agent"
        thread.start()
    }

    private static func serve() {
        let uid = getuid()
        let pid = getpid()
        let directory = AgentWire.directory(uid: uid)
        mkdir(directory, 0o700)
        let path = AgentWire.socketPath(uid: uid, pid: pid)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return APVTAgent.log("socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return APVTAgent.log("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            return APVTAgent.log("bind/listen \(path): \(String(cString: strerror(errno)))")
        }
        announce(pid: pid, socket: path, uid: uid)
        atexit {
            unlink(AgentWire.socketPath(uid: getuid(), pid: getpid()))
            unlink(AgentWire.announcementPath(uid: getuid(), pid: getpid()))
        }
        APVTAgent.log("serving \(path)")
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            autoreleasepool { handle(client) }
            close(client)
        }
    }

    private static func announce(pid: Int32, socket: String, uid: UInt32) {
        let env = ProcessInfo.processInfo.environment
        let announcement = AgentAnnouncement(
            wire: AgentWire.version,
            pid: pid,
            bundleId: Bundle.main.bundleIdentifier ?? "",
            name: ProcessInfo.processInfo.processName,
            deviceUDID: env["SIMULATOR_UDID"],
            socket: socket,
            swiftUIDebug: APVTAgent.swiftUIDebug,
            loadedBy: env["APVT_LOADED_BY"] ?? "lldb",
            startedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(announcement) {
            FileManager.default.createFile(atPath: AgentWire.announcementPath(uid: uid, pid: pid), contents: data)
        }
    }

    private static func handle(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(UInt8(ascii: "\n")) || buffer.count > 1 << 20 { break }
        }
        let response: Data
        if let request = try? JSONDecoder().decode(AgentRequest.self, from: buffer) {
            response = respond(to: request)
        } else {
            response = errorData("request is not a JSON AgentRequest")
        }
        var out = response
        out.append(UInt8(ascii: "\n"))
        out.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let w = write(client, raw.baseAddress! + offset, raw.count - offset)
                if w <= 0 { break }
                offset += w
            }
        }
    }

    private static func errorData(_ message: String) -> Data {
        (try? JSONEncoder().encode(AgentErrorResponse(error: message))) ?? Data("{\"ok\":false}".utf8)
    }

    private static func respond(to request: AgentRequest) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch request.cmd {
        case "ping":
            let path = AgentWire.announcementPath(uid: getuid(), pid: getpid())
            if let data = FileManager.default.contents(atPath: path),
               let announcement = try? { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode(AgentAnnouncement.self, from: data) }() {
                return (try? encoder.encode(AgentPing(ok: true, announcement: announcement))) ?? errorData("encode failed")
            }
            return errorData("announcement missing")
        case "snapshot":
            let start = Date()
            let snapshot: Snapshot = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    var collector = Collector()
                    return collector.snapshot()
                }
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return (try? encoder.encode(AgentSnapshotResponse(ok: true, snapshot: snapshot, elapsedMs: ms))) ?? errorData("encode failed")
        case "swiftui-raw":
            return DispatchQueue.main.sync { MainActor.assumeIsolated { Collector().rawSwiftUIData() } }
        case "methods":
            return methods(className: request.className ?? "", match: request.match ?? "")
        case "type":
            let response = DispatchQueue.main.sync { MainActor.assumeIsolated { Typer.insert(request) } }
            return (try? encoder.encode(response)) ?? errorData("encode failed")
        default:
            return errorData("unknown cmd \(request.cmd) (ping, snapshot, swiftui-raw, methods, type)")
        }
    }

    /// Reflection for the next OS: which selectors a class really has.
    private static func methods(className: String, match: String) -> Data {
        guard let cls = NSClassFromString(className) else { return errorData("no class \(className)") }
        var names: [String] = []
        var current: AnyClass? = cls
        while let c = current {
            var count: UInt32 = 0
            if let list = class_copyMethodList(c, &count) {
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(list[i]))
                    if match.isEmpty || name.localizedCaseInsensitiveContains(match) {
                        names.append("\(NSStringFromClass(c)) \(name)")
                    }
                }
                free(list)
            }
            if c == NSObject.self { break }
            current = class_getSuperclass(c)
        }
        let object: [String: Any] = ["ok": true, "methods": names]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? errorData("encode failed")
    }
}

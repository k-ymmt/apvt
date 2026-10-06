import APVTModel
import Foundation

/// Talks to an agent over its unix socket, and finds agents by their announcements.
public enum AgentClient {
    public static func send(_ request: AgentRequest, socket path: String, timeout: TimeInterval = 60) throws -> Data {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw APVTError(.agent, "socket(): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw APVTError(.agent, "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            throw APVTError(.agent, "could not connect to the agent at \(path)",
                            why: String(cString: strerror(errno)) + " — the app may have quit or be stopped in a debugger.",
                            fix: ["apvt status", "relaunch the app, then run the command again"])
        }
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw APVTError(.agent, "the agent did not answer within \(Int(timeout))s",
                                    why: "the app's main thread is busy or paused (a breakpoint in Xcode stops it).",
                                    fix: ["resume the app in Xcode if it is paused, then retry"])
                }
                throw APVTError(.agent, "reading from the agent failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if chunk[n - 1] == UInt8(ascii: "\n") { break }
        }
        if let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           object["ok"] as? Bool == false {
            throw APVTError(.agent, "the agent refused \(request.cmd): \(object["error"] as? String ?? "unknown error")")
        }
        return response
    }

    /// Every announced agent whose process is alive. Stale announcements are removed.
    public static func announcements() -> [AgentAnnouncement] {
        let directory = AgentWire.directory(uid: getuid())
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [AgentAnnouncement] = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(directory)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  let announcement = try? decoder.decode(AgentAnnouncement.self, from: data) else { continue }
            if kill(announcement.pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: announcement.socket)
                continue
            }
            result.append(announcement)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }
}

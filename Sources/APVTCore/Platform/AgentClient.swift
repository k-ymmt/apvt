import APVTModel
import Foundation

/// Talks to an agent — over its unix socket, or over its pair of pipes when the app is
/// sandboxed — and finds agents by their announcements.
public enum AgentClient {
    static let iOSSilence = Explanation(
        why: "the app is in the background (iOS suspends it), or its main thread is busy or paused at a breakpoint.",
        fix: ["bring the app to the foreground (xcrun simctl launch booted <bundle-id> does), or resume it in Xcode, then retry"])

    public static func send(_ request: AgentRequest, to agent: RunningAgent, timeout: TimeInterval = 60, silence: Explanation? = nil) throws -> Data {
        if agent.transport == AgentWire.transportPipe {
            return try sendOverPipes(request, pid: agent.pid, timeout: timeout, silence: silence ?? iOSSilence)
        }
        return try send(request, socket: agent.socket, timeout: timeout, silence: silence ?? iOSSilence)
    }

    public static func send(_ request: AgentRequest, socket path: String, timeout: TimeInterval = 60, silence: Explanation? = nil) throws -> Data {
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
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw gone(path, String(cString: strerror(errno))) }
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw silent(timeout, silence ?? iOSSilence) }
                throw APVTError(.agent, "reading from the agent failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if chunk[n - 1] == UInt8(ascii: "\n") { break }
        }
        return try checked(response, request)
    }

    /// The pipe transport (`AgentWire.pipeInPath`): one host at a time, and every answer is
    /// preceded by the id of the request it answers.
    static func sendOverPipes(_ request: AgentRequest, pid: Int32, timeout: TimeInterval, silence: Explanation) throws -> Data {
        let uid = getuid()
        let deadline = Date().addingTimeInterval(timeout)
        let lock = open(AgentWire.pipeLockPath(uid: uid, pid: pid), O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw APVTError(.agent, "could not open the agent's lock file: \(String(cString: strerror(errno)))") }
        defer { close(lock) }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                throw APVTError(.agent, "another apvt command is still talking to the app (pid \(pid))", fix: ["wait for it to finish, then retry"])
            }
            usleep(20_000)
        }
        defer { flock(lock, LOCK_UN) }

        let inPath = AgentWire.pipeInPath(uid: uid, pid: pid)
        // Reading end first: the agent answers only when somebody is listening.
        let output = open(AgentWire.pipeOutPath(uid: uid, pid: pid), O_RDONLY | O_NONBLOCK)
        guard output >= 0 else { throw gone(inPath, String(cString: strerror(errno))) }
        defer { close(output) }
        let input = open(inPath, O_WRONLY | O_NONBLOCK)
        guard input >= 0 else { throw gone(inPath, String(cString: strerror(errno))) }
        defer { close(input) }
        _ = fcntl(input, F_SETNOSIGPIPE, 1)

        var request = request
        let id = UUID().uuidString
        request.id = id
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { write(input, $0.baseAddress! + offset, $0.count - offset) }
            if written > 0 { offset += written; continue }
            if written < 0, errno == EAGAIN || errno == EINTR, Date() < deadline { usleep(5_000); continue }
            throw gone(inPath, String(cString: strerror(errno)))
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(output, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if chunk[n - 1] == UInt8(ascii: "\n"), let response = answer(to: id, in: buffer) { return try checked(response, request) }
                continue
            }
            if n < 0, errno != EAGAIN, errno != EINTR {
                throw APVTError(.agent, "reading from the agent failed: \(String(cString: strerror(errno)))")
            }
            // Nothing yet: the agent opens the pipe only to write its answer.
            guard Date() < deadline else { throw silent(timeout, silence) }
            if kill(pid, 0) != 0, errno == ESRCH { throw gone(inPath, "the app (pid \(pid)) has quit") }
            usleep(10_000)
        }
    }

    /// `<id>\n<answer>\n` pairs; answers to requests an earlier host gave up on are skipped.
    private static func answer(to id: String, in buffer: Data) -> Data? {
        let lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        var index = 0
        while index + 1 < lines.count {
            if String(decoding: lines[index], as: UTF8.self) == id { return Data(lines[index + 1]) }
            index += 2
        }
        return nil
    }

    private static func checked(_ response: Data, _ request: AgentRequest) throws -> Data {
        if let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           object["ok"] as? Bool == false {
            throw APVTError(.agent, "the agent refused \(request.cmd): \(object["error"] as? String ?? "unknown error")")
        }
        return response
    }

    private static func gone(_ path: String, _ reason: String) -> APVTError {
        APVTError(.agent, "could not connect to the agent at \(path)",
                  why: reason + " — the app may have quit or be stopped in a debugger.",
                  fix: ["apvt status", "relaunch the app, then run the command again"])
    }

    private static func silent(_ timeout: TimeInterval, _ silence: Explanation) -> APVTError {
        APVTError(.agent, "the agent did not answer within \(Describe.number(timeout))s", why: silence.why, fix: silence.fix)
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
                let uid = getuid()
                for stale in [path, announcement.socket, AgentWire.pipeInPath(uid: uid, pid: announcement.pid),
                              AgentWire.pipeOutPath(uid: uid, pid: announcement.pid), AgentWire.pipeLockPath(uid: uid, pid: announcement.pid)] {
                    try? FileManager.default.removeItem(atPath: stale)
                }
                continue
            }
            result.append(announcement)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }
}

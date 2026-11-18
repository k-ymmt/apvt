import Foundation

/// One request, one answer, as JSON lines. Platform work runs on the main thread; the transport
/// lives on its own thread so a busy main thread only delays the answer.
///
/// The transport is a unix socket under `/tmp/apvt-<uid>/`. Where the App Sandbox forbids
/// binding one (a sandboxed macOS app), it is a pair of named pipes in the same directory,
/// which the host opened to the app with a sandbox extension token.
enum AgentServer {
    static func start() {
        let thread = Thread { serve() }
        thread.name = "apvt-agent"
        thread.start()
    }

    private static func serve() {
        let uid = getuid()
        let pid = getpid()
        mkdir(AgentWire.directory(uid: uid), 0o700)
        let path = AgentWire.socketPath(uid: uid, pid: pid)
        if let fd = listen(at: path) {
            announce(pid: pid, uid: uid, endpoint: path, transport: AgentWire.transportSocket)
            atexit {
                unlink(AgentWire.socketPath(uid: getuid(), pid: getpid()))
                unlink(AgentWire.announcementPath(uid: getuid(), pid: getpid()))
            }
            APVTAgent.log("serving \(path)")
            acceptLoop(fd)
            return
        }
        let socketError = String(cString: strerror(errno))
        guard consumeSandboxToken() else {
            return APVTAgent.log("could not serve \(path): \(socketError). In a sandboxed app the host's token is needed: start the app with apvt launch, or with the variables of apvt launch-env.")
        }
        let input = AgentWire.pipeInPath(uid: uid, pid: pid)
        let output = AgentWire.pipeOutPath(uid: uid, pid: pid)
        unlink(input)
        unlink(output)
        guard mkfifo(input, 0o600) == 0, mkfifo(output, 0o600) == 0 else {
            return APVTAgent.log("could not create the pipes at \(input): \(String(cString: strerror(errno)))")
        }
        // Holding a write end ourselves: hosts come and go without the read ever ending.
        let fd = open(input, O_RDWR)
        guard fd >= 0 else { return APVTAgent.log("could not open \(input): \(String(cString: strerror(errno)))") }
        announce(pid: pid, uid: uid, endpoint: input, transport: AgentWire.transportPipe)
        atexit {
            unlink(AgentWire.pipeInPath(uid: getuid(), pid: getpid()))
            unlink(AgentWire.pipeOutPath(uid: getuid(), pid: getpid()))
            unlink(AgentWire.pipeLockPath(uid: getuid(), pid: getpid()))
            unlink(AgentWire.announcementPath(uid: getuid(), pid: getpid()))
        }
        APVTAgent.log("serving \(input) (pipes: the sandbox does not allow a socket there)")
        pipeLoop(fd, output: output)
    }

    // MARK: - Socket

    private static func listen(at path: String) -> Int32? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            errno = ENAMETOOLONG
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let saved = errno
            close(fd)
            errno = saved
            return nil
        }
        return fd
    }

    private static func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            // A host that gave up must not kill the app with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            autoreleasepool {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(client, &chunk, chunk.count)
                    if n <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<n])
                    if chunk[0..<n].contains(UInt8(ascii: "\n")) || buffer.count > 1 << 20 { break }
                }
                var out = answer(buffer).response
                out.append(UInt8(ascii: "\n"))
                write(out, to: client)
            }
            close(client)
        }
    }

    // MARK: - Pipes

    private static func pipeLoop(_ fd: Int32, output: String) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                autoreleasepool {
                    let (id, response) = answer(line)
                    // Nobody reading means the host gave up: writing would block for good.
                    let out = open(output, O_WRONLY | O_NONBLOCK)
                    guard out >= 0 else { return }
                    _ = fcntl(out, F_SETFL, fcntl(out, F_GETFL) & ~O_NONBLOCK)
                    _ = fcntl(out, F_SETNOSIGPIPE, 1)
                    var framed = Data((id ?? "").utf8)
                    framed.append(UInt8(ascii: "\n"))
                    framed.append(response)
                    framed.append(UInt8(ascii: "\n"))
                    write(framed, to: out)
                    close(out)
                }
            }
            if buffer.count > 1 << 20 { buffer.removeAll() }
        }
    }

    /// The host's sandbox extension token for `/tmp/apvt-<uid>/`, passed in the environment:
    /// consuming it lets this process read and write there (files and pipes, not sockets).
    private static func consumeSandboxToken() -> Bool {
        guard let token = getenv(AgentWire.sandboxTokenVariable),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_consume") else { return false }
        typealias Consume = @convention(c) (UnsafePointer<CChar>) -> Int64
        return unsafeBitCast(symbol, to: Consume.self)(token) >= 0
    }

    // MARK: - Requests

    private static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let w = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if w < 0, errno == EINTR { continue }
                if w <= 0 { break }
                offset += w
            }
        }
    }

    private static func announce(pid: Int32, uid: UInt32, endpoint: String, transport: String) {
        let env = ProcessInfo.processInfo.environment
        let announcement = AgentAnnouncement(
            wire: AgentWire.version,
            pid: pid,
            bundleId: Bundle.main.bundleIdentifier ?? "",
            name: ProcessInfo.processInfo.processName,
            deviceUDID: env["SIMULATOR_UDID"],
            socket: endpoint,
            platform: AgentBackend.platform,
            transport: transport,
            bundlePath: Bundle.main.bundlePath,
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

    private static func answer(_ line: Data) -> (id: String?, response: Data) {
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
            return (nil, errorData("request is not a JSON AgentRequest"))
        }
        return (request.id, respond(to: request))
    }

    private static func errorData(_ message: String) -> Data {
        (try? JSONEncoder().encode(AgentErrorResponse(error: message))) ?? Data("{\"ok\":false}".utf8)
    }

    /// Runs platform work on the main thread and returns what it made (or why it could not).
    private static func onMain<T: Sendable>(_ body: @MainActor @Sendable () throws -> T) -> Result<T, AgentFailure> {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                do { return .success(try body()) } catch let failure as AgentFailure { return .failure(failure) } catch {
                    return .failure(AgentFailure("\(error)"))
                }
            }
        }
    }

    private static func respond(to request: AgentRequest) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func encoded<T: Encodable>(_ result: Result<T, AgentFailure>) -> Data {
            switch result {
            case .success(let value): return (try? encoder.encode(value)) ?? errorData("encode failed")
            case .failure(let failure): return errorData(failure.message)
            }
        }
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
            let result = onMain { try AgentBackend.snapshot(request) }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return encoded(result.map { AgentSnapshotResponse(ok: true, snapshot: $0, elapsedMs: ms) })
        case "swiftui-raw":
            switch onMain({ try AgentBackend.rawSwiftUIData(request) }) {
            case .success(let data): return data
            case .failure(let failure): return errorData(failure.message)
            }
        case "methods":
            return methods(className: request.className ?? "", match: request.match ?? "")
        case "type":
            return encoded(onMain { AgentBackend.type(request) })
        case "screenshot":
            return encoded(onMain { try AgentBackend.screenshot(request) })
        default:
            return errorData("unknown cmd \(request.cmd) (ping, snapshot, swiftui-raw, methods, type, screenshot)")
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

import Foundation

/// Runs a tool and collects its output.
enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 300) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw APVTError(.environment, "could not run \(executable)", why: error.localizedDescription)
        }
        // Read before waiting: a full pipe would block the child forever.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data(), errData = Data()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw APVTError(.environment, "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.prefix(3).joined(separator: " ")) timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    static func xcrun(_ arguments: [String], timeout: TimeInterval = 300) throws -> Result {
        try run("/usr/bin/xcrun", arguments, timeout: timeout)
    }
}

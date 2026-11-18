import CryptoKit
import Foundation

/// Compiles the agent sources embedded in apvt (`EmbeddedAgentSources`, by group) into dylibs.
///
/// Built on this machine because an agent must match the installed SDK and the host's
/// architecture, and Xcode — which apvt needs anyway — makes it a few seconds' work.
enum AgentCompiler {
    /// One build at a time per cache directory, across threads and apvt processes: two builds of
    /// the same sources would write over each other's files.
    static func exclusively<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appending(path: "build.lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// A content hash of the groups and of whatever else decides the build (`salt`).
    static func hash(groups: [String], salt: String) -> String {
        var hasher = SHA256()
        for file in EmbeddedAgentSources.files where groups.contains(file.group) {
            hasher.update(data: Data("\(file.group)/\(file.name)\n".utf8))
            hasher.update(data: Data(file.base64.utf8))
        }
        hasher.update(data: Data(salt.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the groups' sources under `directory/<group>/` and returns their files by group.
    static func write(groups: [String], to directory: URL) throws -> [String: [URL]] {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [String: [URL]] = [:]
        for file in EmbeddedAgentSources.files where groups.contains(file.group) {
            let folder = directory.appending(path: file.group)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: file.name)
            try Data(base64Encoded: file.base64)?.write(to: url)
            result[file.group, default: []].append(url)
        }
        return result
    }

    static func sdkPath(_ sdk: String, what: String, fix: String) throws -> String {
        let result = try Shell.xcrun(["--sdk", sdk, "--show-sdk-path"])
        guard result.ok else {
            throw APVTError(.environment, "the \(what) SDK was not found",
                            why: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), fix: [fix])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func swiftVersion(_ sdk: String) throws -> String {
        try Shell.xcrun(["--sdk", sdk, "swiftc", "--version"]).stdout
    }

    static func compile(sdk: String, module: String, sources: [URL], output: URL, target: String, sdkPath: String,
                        what: String, rebuild: String) throws {
        let arguments = ["--sdk", sdk, "swiftc", "-emit-library", "-target", target, "-sdk", sdkPath,
                         "-swift-version", "6", "-module-name", module, "-parse-as-library", "-O",
                         "-o", output.path] + sources.map(\.path)
        let result = try Shell.xcrun(arguments, timeout: 600)
        guard result.ok else {
            let errors = result.stderr.split(separator: "\n").filter { $0.contains("error:") }.prefix(10).joined(separator: "\n")
            throw APVTError(.environment, "building the \(module) dylib for \(what) failed",
                            why: errors.isEmpty ? result.stderr : errors,
                            fix: ["xcrun --sdk \(sdk) swiftc --version   # needs Swift 6.2 or later (for @section)", rebuild])
        }
    }

    static func hostArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.hasPrefix("arm64") ? "arm64" : "x86_64"
    }
}

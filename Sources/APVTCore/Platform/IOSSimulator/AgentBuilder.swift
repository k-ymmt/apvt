import CryptoKit
import Foundation

/// Builds the agent and the loader for the iOS Simulator from the sources embedded in apvt.
///
/// Built on this machine because a simulator dylib must match the host's architecture and the
/// installed SDK, and Xcode — which apvt needs anyway — makes it a few seconds' work. Builds are
/// cached by content under `~/Library/Caches/apvt/ios-simulator/<hash>/`; `current/` always
/// holds the latest, so the paths written into launchd and `~/.lldbinit` stay valid when
/// apvt is updated.
enum AgentBuilder {
    struct Products {
        var agent: URL
        var loader: URL
        var hash: String
        var built: Bool
    }

    static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/apvt/ios-simulator")
    }

    static var currentAgent: URL { cacheRoot.appending(path: "current/libapvt-agent.dylib") }
    static var currentLoader: URL { cacheRoot.appending(path: "current/libapvt-loader.dylib") }

    /// Deployment target of the agent: anything a current Xcode still simulates.
    static let deploymentTarget = "16.0"

    static func ensure(rebuild: Bool = false) throws -> Products {
        let sdk = try Shell.xcrun(["--sdk", "iphonesimulator", "--show-sdk-path"])
        guard sdk.ok else {
            throw APVTError(.environment, "the iOS Simulator SDK was not found",
                            why: sdk.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                            fix: ["install Xcode with the iOS platform, then: sudo xcode-select -s /Applications/Xcode.app"])
        }
        let sdkPath = sdk.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let swiftVersion = try Shell.xcrun(["--sdk", "iphonesimulator", "swiftc", "--version"]).stdout
        let arch = hostArchitecture()

        var hasher = SHA256()
        for file in EmbeddedAgentSources.files {
            hasher.update(data: Data("\(file.group)/\(file.name)\n".utf8))
            hasher.update(data: Data(file.base64.utf8))
        }
        hasher.update(data: Data("\(sdkPath)\n\(swiftVersion)\n\(arch)\n\(deploymentTarget)".utf8))
        let hash = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        let directory = cacheRoot.appending(path: hash)
        let agent = directory.appending(path: "libapvt-agent.dylib")
        let loader = directory.appending(path: "libapvt-loader.dylib")
        let fm = FileManager.default
        var built = false
        if rebuild || !fm.fileExists(atPath: agent.path) || !fm.fileExists(atPath: loader.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appending(path: "src")
            try? fm.removeItem(at: source)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            var groups: [String: [URL]] = [:]
            for file in EmbeddedAgentSources.files {
                let folder = source.appending(path: file.group)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: file.name)
                try Data(base64Encoded: file.base64)?.write(to: url)
                groups[file.group, default: []].append(url)
            }
            let target = "\(arch)-apple-ios\(deploymentTarget)-simulator"
            try compile(module: "APVTAgent", sources: (groups["model"] ?? []) + (groups["agent-ios"] ?? []),
                        output: agent, target: target, sdk: sdkPath)
            try compile(module: "APVTLoader", sources: groups["loader"] ?? [], output: loader, target: target, sdk: sdkPath)
            built = true
        }
        // `current/` = copies of the latest build at stable paths.
        let current = cacheRoot.appending(path: "current")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        for (from, to) in [(agent, currentAgent), (loader, currentLoader)] {
            if built || !fm.contentsEqual(atPath: from.path, andPath: to.path) {
                try? fm.removeItem(at: to)
                try fm.copyItem(at: from, to: to)
            }
        }
        try Data(hash.utf8).write(to: current.appending(path: "hash"))
        return Products(agent: currentAgent, loader: currentLoader, hash: hash, built: built)
    }

    static func currentHash() -> String? {
        (try? String(contentsOf: cacheRoot.appending(path: "current/hash"), encoding: .utf8))
    }

    private static func compile(module: String, sources: [URL], output: URL, target: String, sdk: String) throws {
        let arguments = ["--sdk", "iphonesimulator", "swiftc", "-emit-library", "-target", target, "-sdk", sdk,
                         "-swift-version", "6", "-module-name", module, "-parse-as-library", "-O",
                         "-o", output.path] + sources.map(\.path)
        let result = try Shell.xcrun(arguments, timeout: 600)
        guard result.ok else {
            let errors = result.stderr.split(separator: "\n").filter { $0.contains("error:") }.prefix(10).joined(separator: "\n")
            throw APVTError(.environment, "building the \(module) dylib for the simulator failed",
                            why: errors.isEmpty ? result.stderr : errors,
                            fix: ["xcrun --sdk iphonesimulator swiftc --version   # needs Swift 6.2 or later (for @section)",
                                  "apvt setup --rebuild"])
        }
    }

    private static func hostArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.hasPrefix("arm64") ? "arm64" : "x86_64"
    }
}

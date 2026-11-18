import Foundation

/// Builds the agent and the loader for the iOS Simulator from the sources embedded in apvt.
///
/// Builds are cached by content under `~/Library/Caches/apvt/ios-simulator/<hash>/`; `current/`
/// always holds the latest, so the paths written into launchd stay valid when apvt is updated.
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
    static let groups = ["model", "agent-shared", "agent-ios", "loader"]

    static func ensure(rebuild: Bool = false) throws -> Products {
        try AgentCompiler.exclusively(in: cacheRoot) { try build(rebuild: rebuild) }
    }

    private static func build(rebuild: Bool) throws -> Products {
        let sdkPath = try AgentCompiler.sdkPath("iphonesimulator", what: "iOS Simulator",
                                                fix: "install Xcode with the iOS platform, then: sudo xcode-select -s /Applications/Xcode.app")
        let swiftVersion = try AgentCompiler.swiftVersion("iphonesimulator")
        let arch = AgentCompiler.hostArchitecture()
        let hash = AgentCompiler.hash(groups: groups, salt: "\(sdkPath)\n\(swiftVersion)\n\(arch)\n\(deploymentTarget)")

        let directory = cacheRoot.appending(path: hash)
        let agent = directory.appending(path: "libapvt-agent.dylib")
        let loader = directory.appending(path: "libapvt-loader.dylib")
        let fm = FileManager.default
        var built = false
        if rebuild || !fm.fileExists(atPath: agent.path) || !fm.fileExists(atPath: loader.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let sources = try AgentCompiler.write(groups: groups, to: directory.appending(path: "src"))
            let target = "\(arch)-apple-ios\(deploymentTarget)-simulator"
            try AgentCompiler.compile(sdk: "iphonesimulator", module: "APVTAgent",
                                      sources: (sources["model"] ?? []) + (sources["agent-shared"] ?? []) + (sources["agent-ios"] ?? []),
                                      output: agent, target: target, sdkPath: sdkPath, what: "the simulator", rebuild: "apvt setup --rebuild")
            try AgentCompiler.compile(sdk: "iphonesimulator", module: "APVTLoader", sources: sources["loader"] ?? [],
                                      output: loader, target: target, sdkPath: sdkPath, what: "the simulator", rebuild: "apvt setup --rebuild")
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
}

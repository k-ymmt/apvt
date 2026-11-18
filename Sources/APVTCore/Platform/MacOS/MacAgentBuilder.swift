import Foundation

/// Builds the agent for macOS apps from the sources embedded in apvt: one universal dylib
/// (arm64 + x86_64, so it loads into an app of either architecture), cached by content under
/// `~/Library/Caches/apvt/macos/<hash>/`. `current/` holds the latest at a stable path, and
/// `current/signed/<team>/` the copies signed for apps that validate libraries.
enum MacAgentBuilder {
    struct Products {
        var agent: URL
        var hash: String
        var built: Bool
    }

    static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/apvt/macos")
    }

    static var currentAgent: URL { cacheRoot.appending(path: "current/libapvt-agent.dylib") }

    /// Deployment target of the agent (it uses NSView.clipsToBounds, macOS 14).
    static let deploymentTarget = "14.0"
    static let groups = ["model", "agent-shared", "agent-macos"]
    static let architectures = ["arm64", "x86_64"]

    static func ensure(rebuild: Bool = false) throws -> Products {
        try AgentCompiler.exclusively(in: cacheRoot) { try build(rebuild: rebuild) }
    }

    private static func build(rebuild: Bool) throws -> Products {
        let sdkPath = try AgentCompiler.sdkPath("macosx", what: "macOS", fix: "install Xcode, then: sudo xcode-select -s /Applications/Xcode.app")
        let swiftVersion = try AgentCompiler.swiftVersion("macosx")
        let hash = AgentCompiler.hash(groups: groups, salt: "\(sdkPath)\n\(swiftVersion)\n\(architectures)\n\(deploymentTarget)")

        let directory = cacheRoot.appending(path: hash)
        let agent = directory.appending(path: "libapvt-agent.dylib")
        let fm = FileManager.default
        var built = false
        if rebuild || !fm.fileExists(atPath: agent.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let sources = try AgentCompiler.write(groups: groups, to: directory.appending(path: "src"))
            let files = groups.flatMap { sources[$0] ?? [] }
            let slices = architectures.map { directory.appending(path: "libapvt-agent-\($0).dylib") }
            nonisolated(unsafe) var failures = [Error?](repeating: nil, count: architectures.count)
            DispatchQueue.concurrentPerform(iterations: architectures.count) { i in
                do {
                    try AgentCompiler.compile(sdk: "macosx", module: "APVTAgent", sources: files, output: slices[i],
                                              target: "\(architectures[i])-apple-macos\(deploymentTarget)", sdkPath: sdkPath,
                                              what: "macOS (\(architectures[i]))", rebuild: "apvt launch <App.app> --rebuild")
                } catch {
                    failures[i] = error
                }
            }
            if let failure = failures.compactMap({ $0 }).first { throw failure }
            let staging = directory.appending(path: ".libapvt-agent.dylib")
            try? fm.removeItem(at: staging)
            let lipo = try Shell.xcrun(["lipo", "-create"] + slices.map(\.path) + ["-output", staging.path], timeout: 120)
            guard lipo.ok else {
                throw APVTError(.environment, "lipo could not join the agent's architectures", why: lipo.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // One ad-hoc signature over the universal file.
            _ = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", staging.path], timeout: 60)
            try? fm.removeItem(at: agent)
            try fm.moveItem(at: staging, to: agent)
            slices.forEach { try? fm.removeItem(at: $0) }
            built = true
        }
        // `current/` = a copy of the latest build at a stable path (what launch-env prints).
        let current = cacheRoot.appending(path: "current")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        if built || !fm.contentsEqual(atPath: agent.path, andPath: currentAgent.path) {
            try? fm.removeItem(at: currentAgent)
            try fm.copyItem(at: agent, to: currentAgent)
        }
        try Data(hash.utf8).write(to: current.appending(path: "hash"))
        return Products(agent: currentAgent, hash: hash, built: built)
    }

    static func currentHash() -> String? {
        (try? String(contentsOf: cacheRoot.appending(path: "current/hash"), encoding: .utf8))
    }

    /// The agent signed for apps of `team`: with `identity` when given, else with whichever of
    /// the keychains' identities belongs to that team (the app's own certificate first).
    static func signed(_ products: Products, team: String, appAuthority: String?, identity: String?) throws -> (agent: URL, identity: String, signedNow: Bool) {
        let fm = FileManager.default
        let directory = cacheRoot.appending(path: "current/signed/\(team)")
        let destination = directory.appending(path: "libapvt-agent.dylib")
        let stamp = directory.appending(path: "stamp")
        if let identity {
            let wanted = "\(products.hash)\n\(identity)"
            if fm.fileExists(atPath: destination.path), (try? String(contentsOf: stamp, encoding: .utf8)) == wanted {
                return (destination, identity, false)
            }
            let signedTeam = try SigningIdentity.sign(products.agent, to: destination, identity: identity)
            guard signedTeam == team else {
                try? fm.removeItem(at: destination)
                throw APVTError(.environment, "the identity \"\(identity)\" signs for team \(signedTeam ?? "none"), but the app is signed by team \(team)",
                                why: "the app validates libraries: only one signed by its own team loads.",
                                fix: ["security find-identity -v -p codesigning   # pick the identity of team \(team)"])
            }
            try Data(wanted.utf8).write(to: stamp)
            return (destination, identity, true)
        }
        // Already signed by an identity that is still in the keychain, for this build: reuse.
        var identities = try SigningIdentity.all()
        if fm.fileExists(atPath: destination.path), let saved = try? String(contentsOf: stamp, encoding: .utf8) {
            let parts = saved.split(separator: "\n").map(String.init)
            if parts.count == 2, parts[0] == products.hash, identities.contains(where: { $0.hash == parts[1] }) {
                return (destination, parts[1], false)
            }
        }
        // The certificate the app was signed with first, then development certificates.
        identities.sort { a, b in
            func rank(_ i: SigningIdentity.Identity) -> Int { i.name == appAuthority ? 0 : i.name.hasPrefix("Apple Development") || i.name.hasPrefix("Mac Developer") ? 1 : 2 }
            return rank(a) < rank(b)
        }
        var problems: [String] = []
        for candidate in identities {
            do {
                if try SigningIdentity.sign(products.agent, to: destination, identity: candidate.hash) == team {
                    try Data("\(products.hash)\n\(candidate.hash)".utf8).write(to: stamp)
                    return (destination, candidate.hash, true)
                }
            } catch let error as APVTError {
                problems.append(error.why ?? error.message)
            }
        }
        try? fm.removeItem(at: destination)
        throw APVTError(.environment, "no code signing identity of team \(team) was found to sign the apvt agent with",
                        why: "the app is signed with the Hardened Runtime by team \(team), so it only loads libraries signed by that team; your keychains hold \(identities.count) code signing identit\(identities.count == 1 ? "y" : "ies"), none of that team\(problems.isEmpty ? "" : " (\(problems[0]))").",
                        fix: ["security find-identity -v -p codesigning   # the identities you can sign with",
                              "apvt launch <App.app> --identity <name-or-hash>   # if the right one is not picked",
                              "or build the app without the Hardened Runtime (xcodebuild … ENABLE_HARDENED_RUNTIME=NO), or signed to run locally (CODE_SIGN_IDENTITY=-)"])
    }
}

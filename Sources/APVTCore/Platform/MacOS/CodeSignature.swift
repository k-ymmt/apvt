import Foundation

/// What a macOS app's code signature says about loading a library into it.
///
/// Measured on macOS 27 (docs/macos.md): without the Hardened Runtime an ad-hoc signed agent
/// loads. With it, dyld honours `DYLD_INSERT_LIBRARIES` only when the app has `get-task-allow`
/// (every Xcode Debug build) or `allow-dyld-environment-variables`, and library validation then
/// wants the agent signed by the app's team unless `disable-library-validation` is set.
struct CodeSignature: Sendable, Equatable {
    var signed = false
    var adhoc = false
    var hardenedRuntime = false
    var libraryValidation = false
    var teamIdentifier: String?
    /// The signing certificate's common name (`Apple Development: … (…)`).
    var authority: String?
    var getTaskAllow = false
    var allowDyldEnvironment = false
    var disableLibraryValidation = false
    var sandboxed = false

    enum AgentSignature: Sendable, Equatable {
        /// The linker's ad-hoc signature is enough.
        case adhoc
        /// The agent must carry a signature of the app's team.
        case team(String)
    }

    static func read(_ bundle: AppBundle) throws -> CodeSignature {
        let details = try Shell.run("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.url.path], timeout: 60)
        guard details.ok else { return CodeSignature() } // not signed at all
        let entitlements = try Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.url.path], timeout: 60)
        return parse(details: details.stderr, entitlements: entitlements.ok ? Data(entitlements.stdout.utf8) : nil)
    }

    /// `details`: what `codesign -dv --verbose=4` prints; `entitlements`: the XML plist of `--entitlements - --xml`.
    static func parse(details: String, entitlements: Data?) -> CodeSignature {
        var signature = CodeSignature()
        signature.signed = true
        for line in details.split(separator: "\n") {
            if line.hasPrefix("CodeDirectory "), let open = line.range(of: "flags=")?.upperBound {
                let rest = line[open...]
                if let start = rest.firstIndex(of: "("), let end = rest.firstIndex(of: ")") {
                    let flags = rest[rest.index(after: start)..<end].split(separator: ",").map(String.init)
                    signature.adhoc = flags.contains("adhoc")
                    signature.hardenedRuntime = flags.contains("runtime")
                    signature.libraryValidation = flags.contains("library-validation")
                }
            } else if line == "Signature=adhoc" {
                signature.adhoc = true
            } else if line.hasPrefix("TeamIdentifier=") {
                let team = String(line.dropFirst("TeamIdentifier=".count))
                signature.teamIdentifier = team == "not set" || team.isEmpty ? nil : team
            } else if line.hasPrefix("Authority="), signature.authority == nil {
                signature.authority = String(line.dropFirst("Authority=".count))
            }
        }
        if let entitlements, !entitlements.isEmpty,
           let plist = try? PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Any] {
            func flag(_ key: String) -> Bool { plist[key] as? Bool ?? false }
            signature.getTaskAllow = flag("com.apple.security.get-task-allow")
            signature.allowDyldEnvironment = flag("com.apple.security.cs.allow-dyld-environment-variables")
            signature.disableLibraryValidation = flag("com.apple.security.cs.disable-library-validation")
            signature.sandboxed = flag("com.apple.security.app-sandbox")
        }
        return signature
    }

    /// What the agent must be signed with to load into this app, or why it never will.
    func agentSignature(app: String) throws -> AgentSignature {
        let debugBuild = "build the app's Debug configuration: Xcode adds get-task-allow (CODE_SIGN_INJECT_BASE_ENTITLEMENTS) to it"
        let noRuntime = "build it without the Hardened Runtime: xcodebuild … ENABLE_HARDENED_RUNTIME=NO"
        if hardenedRuntime, !getTaskAllow, !allowDyldEnvironment {
            throw APVTError(.environment, "\(app) cannot load the apvt agent: it is signed with the Hardened Runtime and without get-task-allow",
                            why: "dyld ignores DYLD_INSERT_LIBRARIES for a hardened app unless it has the get-task-allow or allow-dyld-environment-variables entitlement (a release or archived build has neither). apvt does not re-sign your app.",
                            fix: [debugBuild, "or " + noRuntime,
                                  "codesign -d --entitlements - \"\(app)\"   # what the build has now"])
        }
        guard hardenedRuntime || libraryValidation, !disableLibraryValidation else { return .adhoc }
        guard let teamIdentifier else {
            throw APVTError(.environment, "\(app) cannot load the apvt agent: it enforces library validation but is signed ad hoc",
                            why: "library validation only admits libraries signed by the app's team, and an ad-hoc signature has no team.",
                            fix: ["sign the app with a development certificate (Xcode: Signing & Capabilities > Team): apvt then signs its agent for that team",
                                  "or " + noRuntime])
        }
        return .team(teamIdentifier)
    }
}

/// Code signing identities in the user's keychains, and the agent signed with one of them.
enum SigningIdentity {
    struct Identity: Sendable, Equatable {
        /// SHA-1 of the certificate: unambiguous for `codesign -s`.
        var hash: String
        var name: String
    }

    static func all() throws -> [Identity] {
        let result = try Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], timeout: 60)
        return parse(result.stdout)
    }

    /// `  1) 0123…CDEF "Apple Development: Jane Appleseed (ABCDE12345)"`.
    static func parse(_ output: String) -> [Identity] {
        var identities: [Identity] = []
        for line in output.split(separator: "\n") {
            guard let close = line.firstIndex(of: ")"), let quote = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), quote < end else { continue }
            let hash = line[line.index(after: close)..<quote].trimmingCharacters(in: .whitespaces)
            guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { continue }
            let identity = Identity(hash: hash, name: String(line[line.index(after: quote)..<end]))
            if !identities.contains(identity) { identities.append(identity) }
        }
        return identities
    }

    /// Signs `source` into `destination` with `identity`; returns the team the signature carries.
    static func sign(_ source: URL, to destination: URL, identity: String) throws -> String? {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).dylib")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let signed = try Shell.run("/usr/bin/codesign", ["-f", "-s", identity, "--timestamp=none", staging.path], timeout: 120)
        guard signed.ok else {
            throw APVTError(.environment, "codesign could not sign the apvt agent with \"\(identity)\"",
                            why: signed.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                            fix: ["security find-identity -v -p codesigning   # the identities you can sign with",
                                  "apvt launch <App.app> --identity <name-or-hash>"])
        }
        let details = try Shell.run("/usr/bin/codesign", ["-dv", "--verbose=4", staging.path], timeout: 60)
        let team = CodeSignature.parse(details: details.stderr, entitlements: nil).teamIdentifier
        // A new file each time: a process that has the old one mapped keeps its pages.
        _ = try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        return team
    }
}

/// `sandbox_extension_issue_file`: a token that lets a sandboxed process that consumes it read
/// and write under `path`. This is how a sandboxed app's agent reaches `/tmp/apvt-<uid>/`.
enum SandboxExtension {
    static func readWriteToken(for path: String) -> String? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_issue_file") else { return nil }
        typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let token = unsafeBitCast(symbol, to: Issue.self)("com.apple.app-sandbox.read-write", path, 0) else { return nil }
        defer { free(token) }
        return String(cString: token)
    }
}

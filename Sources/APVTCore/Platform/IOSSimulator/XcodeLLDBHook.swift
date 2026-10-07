import Foundation

/// The `~/.lldbinit` block that loads the agent into apps Xcode runs under its debugger.
///
/// Why: Xcode passes its own DYLD_INSERT_LIBRARIES (the Main Thread Checker) to the app, which
/// replaces the one `apvt setup` puts into the simulator's launchd (measured: a per-launch value
/// wins). Xcode's LLDB reads its init file before it creates the target; a breakpoint set there
/// lives in LLDB's dummy target and is copied into every target Xcode debugs. It auto-continues
/// on `UIApplicationMain` — before any SwiftUI view graph exists — after `dlopen`ing the agent.
/// In a non-simulator process the dlopen fails and nothing happens.
///
/// Which file: LLDB sources `~/.lldbinit-<program>` when it exists, else `~/.lldbinit`. Xcode 27
/// debugs from `lldb-rpc-server`, which (measured with the same LLDB.framework under a temporary
/// HOME) reads `~/.lldbinit` — not `~/.lldbinit-Xcode`, which only a process named `Xcode` reads.
/// Command-line `lldb` reads `~/.lldbinit-lldb` when it exists, else `~/.lldbinit` too.
enum XcodeLLDBHook {
    static let begin = "# >>> apvt agent hook (apvt setup --xcode; remove with apvt teardown --xcode)"
    static let end = "# <<< apvt agent hook"

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lldbinit")
    }

    /// Where earlier apvt versions put the hook; Xcode 27 does not read it.
    static var legacyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lldbinit-Xcode")
    }

    static func block(agentPath: String) -> String {
        let expression = "(void)setenv(\\\"APVT_LOADED_BY\\\", \\\"xcode\\\", 1); (void*)dlopen(\\\"\(agentPath)\\\", 2)"
        return """
        \(begin)
        breakpoint set --name UIApplicationMain --auto-continue true --breakpoint-name apvt_agent --command "expression -l objective-c -- \(expression)"
        \(end)
        """
    }

    static var isInstalled: Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains(begin)
    }

    /// Writes (or replaces) the block. Returns what it did.
    static func install(agentPath: String) throws -> String {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let stripped = remove(from: existing)
        var text = stripped
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += block(agentPath: agentPath) + "\n"
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw APVTError(.io, "could not write \(file.path)", why: error.localizedDescription)
        }
        var message = existing.contains(begin) ? "updated the agent hook in \(file.path)" : "added the agent hook to \(file.path)"
        if let legacy = try? String(contentsOf: legacyFile, encoding: .utf8), legacy.contains(begin) {
            let stripped = remove(from: legacy)
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: legacyFile)
            } else {
                try? stripped.write(to: legacyFile, atomically: true, encoding: .utf8)
            }
            message += " (and moved it out of \(legacyFile.path), which Xcode 27 does not read)"
        }
        return message
    }

    static func uninstall() throws -> String? {
        var done: [String] = []
        for url in [file, legacyFile] {
            guard let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains(begin) else { continue }
            let stripped = remove(from: existing)
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try FileManager.default.removeItem(at: url)
                done.append("removed \(url.path) (it held only the apvt hook)")
            } else {
                try stripped.write(to: url, atomically: true, encoding: .utf8)
                done.append("removed the agent hook from \(url.path)")
            }
        }
        return done.isEmpty ? nil : done.joined(separator: "; ")
    }

    static func remove(from text: String) -> String {
        var lines: [Substring] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == begin { inside = true; continue }
            if inside { if line == end { inside = false }; continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

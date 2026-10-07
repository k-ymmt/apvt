import Foundation

/// What earlier apvt versions wrote into LLDB init files, so `apvt teardown` can remove it.
///
/// apvt no longer loads the agent through Xcode's debugger. Measured with Xcode 27.1 beta: Xcode
/// passes its own DYLD_INSERT_LIBRARIES (Main Thread Checker), replacing the one `apvt setup`
/// puts into the simulator's launchd; an init-file breakpoint on `UIApplicationMain` was read
/// (Xcode 27's `lldb-rpc-server` reads `~/.lldbinit`, not `~/.lldbinit-Xcode`), but Xcode imports
/// every breakpoint the debugger creates into the project's own breakpoint list without its
/// commands, callbacks or auto-continue, so the app stopped there on every Run and the agent
/// never loaded. See docs/ios-simulator.md.
enum LegacyLLDBHook {
    static let begin = "# >>> apvt agent hook (apvt setup --xcode; remove with apvt teardown --xcode)"
    static let end = "# <<< apvt agent hook"

    /// LLDB finds init files through `HOME` (FileManager would ignore it).
    static var home: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var files: [URL] { [home.appending(path: ".lldbinit"), home.appending(path: ".lldbinit-Xcode")] }

    static var script: URL { AgentBuilder.cacheRoot.appending(path: "current/apvt_lldb.py") }

    static var isInstalled: Bool {
        files.contains { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(begin) }
    }

    /// Removes the block from every init file that has it, and the script it imported.
    static func uninstall() throws -> [String] {
        var done: [String] = []
        for url in files {
            guard let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains(begin) else { continue }
            let stripped = remove(from: existing)
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try FileManager.default.removeItem(at: url)
                done.append("removed \(url.path) (it held only an old apvt hook)")
            } else {
                try stripped.write(to: url, atomically: true, encoding: .utf8)
                done.append("removed an old apvt hook from \(url.path)")
            }
        }
        if FileManager.default.fileExists(atPath: script.path) {
            try? FileManager.default.removeItem(at: script)
        }
        return done
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

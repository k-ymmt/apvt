import Foundation

/// The `~/.lldbinit` block that loads the agent into apps Xcode runs under its debugger.
///
/// Why: Xcode passes its own DYLD_INSERT_LIBRARIES (the Main Thread Checker) to the app, which
/// replaces the one `apvt setup` puts into the simulator's launchd (measured: a per-launch value
/// wins). Xcode's LLDB reads its init file before it creates the target; a breakpoint set there
/// lives in LLDB's dummy target and is copied into every target Xcode debugs. It auto-continues
/// on `UIApplicationMain` — before any SwiftUI view graph exists — after `dlopen`ing the agent
/// (see `script(agentPath:)`). Non-simulator targets are left alone.
///
/// Which file: LLDB sources `~/.lldbinit-<program>` when it exists, else `~/.lldbinit`. Xcode 27
/// debugs from `lldb-rpc-server`, which (measured with the same LLDB.framework under a temporary
/// HOME) reads `~/.lldbinit` — not `~/.lldbinit-Xcode`, which only a process named `Xcode` reads.
/// Command-line `lldb` reads `~/.lldbinit-lldb` when it exists, else `~/.lldbinit` too.
enum XcodeLLDBHook {
    static let begin = "# >>> apvt agent hook (apvt setup --xcode; remove with apvt teardown --xcode)"
    static let end = "# <<< apvt agent hook"

    /// LLDB finds init files through `HOME`; so does apvt (FileManager would ignore `HOME`).
    static var home: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var file: URL { home.appending(path: ".lldbinit") }

    /// Where earlier apvt versions put the hook; Xcode 27 does not read it.
    static var legacyFile: URL { home.appending(path: ".lldbinit-Xcode") }

    /// The init-file block: it only imports the script, so the logic lives in Python.
    static func block(scriptPath: String) -> String {
        """
        \(begin)
        command script import "\(scriptPath)"
        \(end)
        """
    }

    /// An LLDB Python module, written next to the agent.
    ///
    /// A breakpoint command written as `--command "expression …"` stopped the app in a real Xcode
    /// Run instead of continuing (LLDB stops when a breakpoint command fails, auto-continue or
    /// not), and the init file was sourced twice (`breakpoint 1.1 2.1`). The script instead:
    /// sets the breakpoint once per debugger, evaluates with explicit options, never stops the
    /// app (the callback returns False), skips non-simulator targets and apps that already have
    /// the agent, and writes what happened to `/tmp/apvt-<uid>/xcode-hook.log`.
    static func script(agentPath: String) -> String {
        """
        # Written by `apvt setup --xcode`; loaded from ~/.lldbinit. Remove with `apvt teardown --xcode`.
        import datetime
        import os

        import lldb

        AGENT = \(pythonString(agentPath))
        NAME = "apvt_agent"
        LOG = "/tmp/apvt-%d/xcode-hook.log" % os.getuid()


        def log(message):
            try:
                os.makedirs(os.path.dirname(LOG), exist_ok=True)
                with open(LOG, "a") as f:
                    f.write("%s %s\\n" % (datetime.datetime.now().isoformat(timespec="seconds"), message))
            except Exception:
                pass


        def on_ui_application_main(frame, bp_loc, *rest):
            try:
                target = frame.GetThread().GetProcess().GetTarget()
                triple = target.GetTriple() or ""
                pid = frame.GetThread().GetProcess().GetProcessID()
                if "simulator" not in triple:
                    return False
                for module in target.module_iter():
                    if module.GetFileSpec().GetFilename() == os.path.basename(AGENT):
                        log("pid %d: agent already loaded (launchd); nothing to do" % pid)
                        return False
                options = lldb.SBExpressionOptions()
                options.SetLanguage(lldb.eLanguageTypeC)
                options.SetIgnoreBreakpoints(True)
                options.SetTryAllThreads(True)
                options.SetTimeoutInMicroSeconds(10 * 1000 * 1000)
                env = frame.EvaluateExpression('(int)setenv("APVT_LOADED_BY", "xcode", 1)', options)
                handle = frame.EvaluateExpression('(void *)dlopen("%s", 2)' % AGENT, options)
                if handle.GetError().Fail():
                    log("pid %d (%s): dlopen expression failed: %s; setenv: %s"
                        % (pid, triple, handle.GetError().GetCString(), env.GetError().GetCString()))
                elif handle.GetValueAsUnsigned() == 0:
                    reason = frame.EvaluateExpression("(char *)dlerror()", options)
                    log("pid %d (%s): dlopen returned NULL: %s" % (pid, triple, reason.GetSummary()))
                else:
                    log("pid %d (%s): agent loaded" % (pid, triple))
            except Exception as error:
                log("callback raised: %r" % (error,))
            return False


        def __lldb_init_module(debugger, internal_dict):
            target = debugger.GetDummyTarget()
            existing = lldb.SBBreakpointList(target)
            target.FindBreakpointsByName(NAME, existing)
            if existing.GetSize() > 0:
                return
            bp = target.BreakpointCreateByName("UIApplicationMain")
            bp.AddName(NAME)
            bp.SetAutoContinue(True)
            bp.SetScriptCallbackFunction(__name__ + ".on_ui_application_main")

        """
    }

    private static func pythonString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func scriptURL(agentPath: String) -> URL {
        URL(fileURLWithPath: agentPath).deletingLastPathComponent().appending(path: "apvt_lldb.py")
    }

    static var isInstalled: Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains(begin)
    }

    /// Writes (or replaces) the block. Returns what it did.
    static func install(agentPath: String) throws -> String {
        let scriptURL = scriptURL(agentPath: agentPath)
        do {
            try script(agentPath: agentPath).write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw APVTError(.io, "could not write \(scriptURL.path)", why: error.localizedDescription)
        }
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let stripped = remove(from: existing)
        var text = stripped
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += block(scriptPath: scriptURL.path) + "\n"
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

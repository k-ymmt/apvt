import APVTModel
import Foundation

/// What `apvt inspect` prints.
public struct InspectReport: Codable, Sendable {
    public struct Summary: Codable, Sendable {
        public var errors: Int
        public var warnings: Int
        public var nodes: Int
    }

    public var platform: String
    public var app: AppInfo
    public var device: DeviceInfo?
    public var screen: ScreenInfo
    /// macOS: the window the report is about, and the app's other windows.
    public var window: WindowInfo?
    public var otherWindows: [WindowInfo]?
    public var summary: Summary
    public var issues: [Issue]
    public var notes: [String]
    public var hints: [String: String]

    public init(_ s: IndexedSnapshot, issues: [Issue]) {
        platform = s.snapshot.platform
        app = s.snapshot.app
        device = s.snapshot.device
        screen = s.snapshot.screen
        window = s.snapshot.window
        otherWindows = s.snapshot.otherWindows
        summary = Summary(errors: issues.filter { $0.severity == .error }.count,
                          warnings: issues.filter { $0.severity == .warning }.count,
                          nodes: s.entries.count)
        self.issues = issues
        notes = s.snapshot.notes
        let systemBreaks = s.snapshot.constraintBreaks.filter { $0.system == true }.count
        if systemBreaks > 0 {
            let own = s.snapshot.platform == Snapshot.macOS ? "AppKit's own views (the title bar, alerts, panels)" : "UIKit's own views (alerts, keyboard)"
            notes.append("\(systemBreaks) constraint conflict(s) inside \(own) were ignored: not the app's to fix.")
        }
        var hints: [String: String] = [:]
        for issue in issues { hints[issue.rule.rawValue] = issue.rule.hint(for: s.snapshot.platform) }
        self.hints = hints
    }

    public static func header(_ s: Snapshot) -> String {
        let app = s.app
        var parts = ["\(app.name) (\(app.bundleId), pid \(app.pid))"]
        if s.platform == Snapshot.macOS {
            // One window, measured from its top-left corner; `at` is that corner on the screen.
            parts.append("macOS \(app.osVersion)")
            let sc = s.screen
            var window = "window"
            if let w = s.window {
                window += " \(w.index) \(Describe.quoted(w.title))"
                if let kind = w.kind { window += " \(kind)" }
            }
            window += " \(Describe.number(sc.width))x\(Describe.number(sc.height))pt @\(Describe.number(sc.scale))x"
            if let w = s.window, let x = w.x, let y = w.y { window += " at (\(Describe.number(x)),\(Describe.number(y)))" }
            parts.append(window)
            var lines = [parts.joined(separator: " · ")]
            if let others = s.otherWindows, !others.isEmpty {
                let list = others.map { w in
                    "\(w.index) \(Describe.quoted(w.title)) \(Describe.number(w.width))x\(Describe.number(w.height))" + (w.kind.map { " \($0)" } ?? "") + (w.key ? " (key)" : "")
                }
                lines.append("other windows: \(list.joined(separator: " · "))   # --window <number|title> looks at one")
            }
            return lines.joined(separator: "\n")
        }
        if let d = s.device { parts.append("\(d.name), \(d.runtime)") } else { parts.append("iOS \(app.osVersion)") }
        let sc = s.screen
        var screen = "screen \(Describe.number(sc.width))x\(Describe.number(sc.height))pt @\(Describe.number(sc.scale))x"
        screen += ", safe area top \(Describe.number(sc.safeArea.top)) bottom \(Describe.number(sc.safeArea.bottom))"
        if sc.safeArea.left > 0 || sc.safeArea.right > 0 {
            screen += " left \(Describe.number(sc.safeArea.left)) right \(Describe.number(sc.safeArea.right))"
        }
        parts.append(screen)
        return parts.joined(separator: " · ")
    }

    public func text(limit: Int?) -> String {
        var lines: [String] = []
        let total = issues.count
        if total == 0 {
            lines.append("no issues found (\(summary.nodes) nodes checked)")
        } else {
            lines.append("\(summary.errors) error\(summary.errors == 1 ? "" : "s"), \(summary.warnings) warning\(summary.warnings == 1 ? "" : "s"):")
            let shown = limit.map { Array(issues.prefix($0)) } ?? issues
            for issue in shown {
                let tag = issue.severity == .error ? "E" : "W"
                lines.append("\(tag) \(issue.rule.rawValue): \(issue.message)")
            }
            if shown.count < total {
                lines.append("… \(total - shown.count) more (--limit 0 shows all, --rule <name> filters)")
            }
        }
        if !notes.isEmpty {
            lines.append("notes:")
            lines += notes.map { "- \($0)" }
        }
        if !hints.isEmpty {
            lines.append("how to fix:")
            for rule in Rule.allCases {
                if let hint = hints[rule.rawValue] { lines.append("- \(rule.rawValue): \(hint)") }
            }
        }
        if let first = issues.first(where: { $0.ref != nil })?.ref {
            lines.append("next: apvt query @\(first)   # the node, its ancestors and metrics · apvt tree · apvt screenshot <file.png>")
        }
        return lines.joined(separator: "\n")
    }
}

/// What `apvt query` prints for each match.
public enum QueryFormatter {
    public static func text(_ entries: [IndexedSnapshot.Entry], in s: IndexedSnapshot, issues: [Issue]) -> String {
        if entries.isEmpty { return "no matches" }
        var lines: [String] = ["\(entries.count) match\(entries.count == 1 ? "" : "es"):"]
        for e in entries.prefix(50) {
            let n = e.node
            lines.append("\(Describe.node(e)) \(Describe.frame(e.frame))")
            var facts: [String] = ["role \(n.role.rawValue)", "source \(n.source.rawValue)"]
            if let d = n.detail { facts.append(d.hasPrefix(".") ? d : "class \(d.count > 90 ? String(d.prefix(89)) + "…" : d)") }
            if let mods = n.modifiers, !mods.isEmpty { facts.append("modifiers \(mods.joined(separator: ","))") }
            if let traits = n.traits?.filter({ $0 != "wrapper" }), !traits.isEmpty { facts.append("traits \(traits.joined(separator: ","))") }
            if e.hidden { facts.append("hidden") }
            lines.append("  " + facts.joined(separator: " · "))
            if let t = n.text {
                var font: [String] = []
                if let style = t.textStyle { font.append(style) }
                if let name = t.fontName { font.append(name) }
                if let size = t.fontSize { font.append("\(Describe.number(size))pt") }
                if t.bold == true { font.append("bold") }
                if t.fontGuessed == true { font.append("(guessed)") }
                var metrics: [String] = []
                if let w = t.singleLineWidth { metrics.append("one line needs \(Describe.number(w))pt") }
                if let h = t.requiredHeight { metrics.append("at this width needs \(Describe.number(h))pt height") }
                if let l = t.lineHeight { metrics.append("line \(Describe.number(l))pt") }
                if let m = t.maxLines { metrics.append("numberOfLines \(m)") }
                lines.append("  text \(Describe.quoted(t.string, limit: 80))" + (font.isEmpty ? "" : " font \(font.joined(separator: " "))"))
                if !metrics.isEmpty { lines.append("  " + metrics.joined(separator: " · ")) }
            }
            if let label = n.label { lines.append("  accessibilityLabel \(Describe.quoted(label, limit: 80))") }
            let path = e.ancestors.suffix(6).map { r -> String in
                let a = s[r]
                return "@\(r) \(a.node.type)\(a.node.identifier.map { "#\($0)" } ?? "")"
            }
            lines.append("  in: " + (e.ancestors.count > 6 ? "… > " : "") + path.joined(separator: " > "))
            let kids = e.childRefs.prefix(8).map { "@\($0) \(s[$0].node.type)" }
            if !kids.isEmpty { lines.append("  children: " + kids.joined(separator: ", ") + (e.childRefs.count > 8 ? ", … (\(e.childRefs.count))" : "")) }
            for issue in issues where issue.ref == e.ref || issue.related.contains(e.ref) {
                lines.append("  \(issue.severity == .error ? "E" : "W") \(issue.rule.rawValue): \(issue.message)")
            }
        }
        if entries.count > 50 { lines.append("… \(entries.count - 50) more; narrow the selector") }
        return lines.joined(separator: "\n")
    }
}

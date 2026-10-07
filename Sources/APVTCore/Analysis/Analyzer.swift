import APVTModel
import Foundation

/// Finds the layout mistakes `Rule` names in a snapshot. Pure: no platform, no I/O.
public struct Analyzer: Sendable {
    /// Smallest tappable size, in points (WCAG 2.5.8 minimum).
    public var minimumTarget: Double = 24
    public var rules: Set<Rule> = Set(Rule.allCases)

    public init() {}

    public func analyze(_ s: IndexedSnapshot) -> [Issue] {
        var issues: [Issue] = []
        let screen = s.snapshot.screen
        let content = s.entries.filter { isContent($0) }

        if rules.contains(.widerThanScreen) { issues += widerThanScreen(s, screen) }
        if rules.contains(.offscreen) { issues += offscreen(content, screen) }
        if rules.contains(.clipped) { issues += clipped(s, content) }
        var squeezedRefs = Set<Int>()
        if rules.contains(.squeezed) {
            let found = squeezed(s, content)
            squeezedRefs = Set(found.compactMap(\.ref))
            issues += found
        }
        if rules.contains(.truncated) { issues += truncated(content, skip: squeezedRefs) }
        if rules.contains(.overlap) { issues += overlap(s, content) }
        if rules.contains(.unsafeArea) { issues += unsafeArea(content, screen) }
        if rules.contains(.smallTarget) { issues += smallTargets(content, skip: squeezedRefs) }
        if rules.contains(.ambiguousLayout) {
            for e in s.entries where e.node.has("ambiguousLayout") && e.isAppContent {
                issues.append(Issue(rule: .ambiguousLayout, severity: .warning, ref: e.ref,
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame)) has an ambiguous Auto Layout frame", frame: e.frame))
            }
        }
        if rules.contains(.brokenConstraint) { issues += brokenConstraints(s) }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.ref ?? Int.max, $0.rule.rawValue) < ($1.ref ?? Int.max, $1.rule.rawValue)
        }
    }

    // MARK: - What counts

    /// Something a user sees: text, an image, a control, a shape — of the app, not hidden.
    func isContent(_ e: IndexedSnapshot.Entry) -> Bool {
        guard e.isAppContent, !e.node.has("wrapper") || e.node.role == .control else { return false }
        switch e.node.role {
        case .text, .image, .control, .shape: return true
        default: return e.node.text != nil
        }
    }

    /// `text` overlaps `control` and sticks out of it: the text straddles the control's border.
    func crossesControlEdge(_ text: IndexedSnapshot.Entry, _ textFrame: Rect, _ control: IndexedSnapshot.Entry, _ controlFrame: Rect) -> Bool {
        guard text.node.role == .text || (text.node.text != nil && text.node.role != .control), control.node.role == .control else { return false }
        return !controlFrame.contains(textFrame, tolerance: 0.5)
    }

    func isTextOrControl(_ e: IndexedSnapshot.Entry) -> Bool {
        e.node.role == .text || e.node.role == .control || e.node.text != nil
    }

    // MARK: - Rules

    private func offscreen(_ content: [IndexedSnapshot.Entry], _ screen: ScreenInfo) -> [Issue] {
        var issues: [Issue] = []
        var flagged = Set<Int>()
        let bounds = screen.bounds
        for e in content where e.scrollAncestor == nil && !e.frame.isEmpty {
            if bounds.contains(e.frame, tolerance: 0.5) { continue }
            if let control = e.controlAncestor, flagged.contains(control) { continue }
            flagged.insert(e.ref)
            guard bounds.intersection(e.frame) != nil else {
                issues.append(Issue(rule: .offscreen, severity: .warning, ref: e.ref,
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame)) is entirely outside the \(Describe.number(screen.width))x\(Describe.number(screen.height))pt screen",
                                    frame: e.frame))
                continue
            }
            var edges: [String] = []
            if e.frame.minX < -0.5 { edges.append("\(Describe.number(-e.frame.minX))pt past the left edge") }
            if e.frame.maxX > bounds.maxX + 0.5 { edges.append("\(Describe.number(e.frame.maxX - bounds.maxX))pt past the right edge") }
            if e.frame.minY < -0.5 { edges.append("\(Describe.number(-e.frame.minY))pt past the top edge") }
            if e.frame.maxY > bounds.maxY + 0.5 { edges.append("\(Describe.number(e.frame.maxY - bounds.maxY))pt past the bottom edge") }
            issues.append(Issue(rule: .offscreen, severity: .error, ref: e.ref,
                                message: "\(Describe.node(e)) \(Describe.frame(e.frame)) is cut off: \(edges.joined(separator: ", "))",
                                frame: e.frame))
        }
        return issues
    }

    private func widerThanScreen(_ s: IndexedSnapshot, _ screen: ScreenInfo) -> [Issue] {
        var issues: [Issue] = []
        var reported = Set<Int>()
        for e in s.entries where e.isAppContent && e.scrollAncestor == nil && e.node.role != .window {
            guard e.frame.width > screen.width + 0.5 else { continue }
            if e.ancestors.contains(where: reported.contains) { continue }
            // A UIKit container wider than the screen with nothing visible beyond it is harmless.
            let descendants = s.descendants(of: e.ref).filter { isContent($0) && $0.scrollAncestor == nil }
            let overflowing = descendants.filter { !screen.bounds.contains($0.frame, tolerance: 0.5) && !$0.frame.isEmpty }
            // Content wider than the screen is reported by offscreen; this rule is for containers.
            guard !overflowing.isEmpty, !isContent(e) else { continue }
            reported.insert(e.ref)
            let suspects = self.suspects(in: descendants + s.descendants(of: e.ref).filter { !isContent($0) }, screen)
            var message = "\(Describe.node(e)) \(Describe.frame(e.frame)) is \(Describe.number(e.frame.width))pt wide; the screen is \(Describe.number(screen.width))pt"
            if !overflowing.isEmpty { message += "; \(overflowing.count) visible element(s) end up past the edge" }
            if !suspects.isEmpty {
                message += ". Fixed-size children: " + suspects.map { suspect in
                    let n = suspect.node
                    let why = n.modifiers?.first { $0.hasPrefix("frame(") || $0 == "fixedSize" }
                        ?? n.detail.flatMap { $0.hasPrefix(".") ? $0 : nil }
                    return "\(Describe.node(suspect)) \(Describe.number(suspect.frame.width))pt" + (why.map { " \($0)" } ?? "")
                }.joined(separator: ", ")
            }
            issues.append(Issue(rule: .widerThanScreen, severity: .error, ref: e.ref, related: suspects.map(\.ref), message: message, frame: e.frame))
        }
        return issues
    }

    /// Children that refuse to shrink: .fixedSize, a fixed .frame(width:), unwrapped long text.
    private func suspects(in entries: [IndexedSnapshot.Entry], _ screen: ScreenInfo) -> [IndexedSnapshot.Entry] {
        var result: [IndexedSnapshot.Entry] = []
        var seen = Set<Int>()
        for e in entries.sorted(by: { $0.ref < $1.ref }) where !seen.contains(e.ref) && e.isAppContent {
            let n = e.node
            var suspect = false
            if n.type == ".fixedSize" || n.hasModifier("fixedSize") { suspect = true }
            let fixedWidth = (n.type == ".frame" && (n.detail?.contains("width:") ?? false))
                || (n.modifiers ?? []).contains { $0.hasPrefix("frame(") && $0.contains("width:") && !$0.contains("maxWidth") }
            if fixedWidth, e.frame.width >= screen.width * 0.25 { suspect = true }
            if n.source == .uikit, isContent(e), e.frame.width > screen.width + 0.5 { suspect = true }
            if !suspect { continue }
            seen.insert(e.ref)
            // The .fixedSize wrapper and its Text are one suspect.
            if let last = result.last, s(last, contains: e) { continue }
            result.append(e)
            if result.count == 5 { break }
        }
        return result
        func s(_ a: IndexedSnapshot.Entry, contains b: IndexedSnapshot.Entry) -> Bool { b.ancestors.contains(a.ref) }
    }

    private func clipped(_ s: IndexedSnapshot, _ content: [IndexedSnapshot.Entry]) -> [Issue] {
        var issues: [Issue] = []
        var flagged = Set<Int>()
        for e in content where !e.frame.isEmpty {
            guard let clip = e.clipRect, let clipper = e.clipper, !clip.contains(e.frame, tolerance: 1) else { continue }
            if let control = e.controlAncestor, flagged.contains(control) { continue }
            if e.ancestors.contains(where: flagged.contains) { continue }
            flagged.insert(e.ref)
            let owner = Describe.node(s[clipper])
            if let visible = e.frame.intersection(clip) {
                let hidden = 100 - Int((visible.area / max(e.frame.area, 0.0001) * 100).rounded())
                var sides: [String] = []
                if e.frame.minX < clip.minX - 1 { sides.append("left") }
                if e.frame.maxX > clip.maxX + 1 { sides.append("right") }
                if e.frame.minY < clip.minY - 1 { sides.append("top") }
                if e.frame.maxY > clip.maxY + 1 { sides.append("bottom") }
                issues.append(Issue(rule: .clipped, severity: .error, ref: e.ref, related: [clipper],
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame)) is \(hidden)% hidden (\(sides.joined(separator: ", ")) side) by \(owner) \(Describe.frame(s[clipper].frame)), which clips",
                                    frame: e.frame))
            } else {
                issues.append(Issue(rule: .clipped, severity: .error, ref: e.ref, related: [clipper],
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame)) is entirely hidden: it lies outside \(owner) \(Describe.frame(s[clipper].frame)), which clips",
                                    frame: e.frame))
            }
        }
        return issues
    }

    private func squeezed(_ s: IndexedSnapshot, _ content: [IndexedSnapshot.Entry]) -> [Issue] {
        var issues: [Issue] = []
        for e in content {
            let inside = e.controlAncestor.map { " (inside \(Describe.node(s[$0])))" } ?? ""
            // 0x0 is not drawn at all (SwiftUI keeps such Texts for accessibility); a zero width
            // with height is a text stood on end, one character per line.
            if let text = e.node.text, let word = text.longestWordWidth, word > 0, e.frame.width + 1 < word,
               e.frame.height >= (text.lineHeight ?? 1) * 0.5,
               e.node.source == .swiftui || (text.maxLines ?? 1) != 1 {
                let words: [Substring] = text.string.split(whereSeparator: { (c: Character) in c.isWhitespace })
                let longest = text.longestWord ?? words.max(by: { $0.count < $1.count }).map { String($0) } ?? text.string
                let how = e.frame.width < 1 ? "has no width" : "is \(Describe.number(e.frame.width))pt wide"
                issues.append(Issue(rule: .squeezed, severity: .error, ref: e.ref,
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame))\(inside) \(how), but the word \(Describe.quoted(longest)) needs \(Describe.number(word))pt: its characters wrap one per line or are not drawn",
                                    frame: e.frame))
                continue
            }
            if e.node.role == .control, e.frame.width < 1 || e.frame.height < 1 {
                issues.append(Issue(rule: .squeezed, severity: .error, ref: e.ref,
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame)) collapsed to zero size", frame: e.frame))
            }
        }
        return issues
    }

    private func truncated(_ content: [IndexedSnapshot.Entry], skip: Set<Int>) -> [Issue] {
        var issues: [Issue] = []
        for e in content where !skip.contains(e.ref) && !e.frame.isEmpty {
            guard let t = e.node.text, !t.string.isEmpty, !e.node.has("textNotLaidOut"),
                  let lineHeight = t.lineHeight, lineHeight > 0, let required = t.requiredHeight, let single = t.singleLineWidth else { continue }
            // Text fields and text views scroll their text; shrink-to-fit labels shrink it.
            if e.node.type.contains("TextField") || e.node.type.contains("TextView") || e.node.has("shrinksToFit") { continue }
            let w = e.frame.width, h = e.frame.height
            let guessed = t.fontGuessed == true ? " (font guessed from the frame)" : ""
            let severity: Severity = t.fontGuessed == true ? .warning : .error
            let oneLine = t.maxLines == 1 || h < lineHeight * 1.5
            if oneLine {
                if single > w + 1.5 {
                    let shown = Int((w / single * 100).rounded())
                    issues.append(Issue(rule: .truncated, severity: severity, ref: e.ref,
                                        message: "\(Describe.node(e)) \(Describe.frame(e.frame)) needs \(Describe.number(single))pt on one line but has \(Describe.number(w))pt: about \(shown)% of it is shown\(guessed)",
                                        frame: e.frame))
                }
            } else if required > h + max(2, lineHeight * 0.3) {
                let needLines = Int((required / lineHeight).rounded())
                let haveLines = max(0, Int((h / lineHeight).rounded(.down)))
                issues.append(Issue(rule: .truncated, severity: severity, ref: e.ref,
                                    message: "\(Describe.node(e)) \(Describe.frame(e.frame)) needs \(Describe.number(required))pt of height (\(needLines) lines) but has \(Describe.number(h))pt (\(haveLines) line\(haveLines == 1 ? "" : "s"))\(guessed)",
                                    frame: e.frame))
            }
        }
        return issues
    }

    private func overlap(_ s: IndexedSnapshot, _ content: [IndexedSnapshot.Entry]) -> [Issue] {
        // What is drawn: the part left after clipping; nothing for fully clipped views.
        let candidates = content.filter { isTextOrControl($0) && $0.controlAncestor == nil && ($0.visibleFrame?.area ?? 0) > 1 }
        var issues: [Issue] = []
        for (i, a) in candidates.enumerated() {
            for b in candidates[(i + 1)...] {
                guard a.ancestors.first == b.ancestors.first, !s.isAncestor(a.ref, of: b.ref), !s.isAncestor(b.ref, of: a.ref),
                      let va = a.visibleFrame, let vb = b.visibleFrame,
                      let shared = va.intersection(vb), shared.width > 1, shared.height > 1 else { continue }
                // A SwiftUI control and the UIKit view it hosts (TextField → UITextField) are one.
                if a.node.source != b.node.source, sameFrame(a.frame, b.frame) { continue }
                // A text owner and the text it owns describe the same thing.
                if a.node.has("textNotLaidOut") || b.node.has("textNotLaidOut") { continue }
                // Text drawn across a control's edge is a mistake; text placed wholly inside a
                // control (a badge, a caption on a big button) may be intended.
                let crossesEdge = crossesControlEdge(a, va, b, vb) || crossesControlEdge(b, vb, a, va)
                issues.append(Issue(rule: .overlap, severity: crossesEdge ? .error : .warning, ref: a.ref, related: [b.ref],
                                    message: "\(Describe.node(a)) \(Describe.frame(a.frame)) overlaps \(Describe.node(b)) \(Describe.frame(b.frame)) by \(Describe.number(shared.width))x\(Describe.number(shared.height))pt\(crossesEdge ? " across the control's edge" : "")",
                                    frame: shared))
            }
        }
        return issues
    }

    private func unsafeArea(_ content: [IndexedSnapshot.Entry], _ screen: ScreenInfo) -> [Issue] {
        let safe = screen.safeBounds
        var issues: [Issue] = []
        for e in content where isTextOrControl(e) && e.scrollAncestor == nil && e.controlAncestor == nil && !e.frame.isEmpty {
            guard let onScreen = e.frame.intersection(screen.bounds) else { continue }
            var places: [String] = []
            if screen.safeArea.top > 0, safe.minY - onScreen.minY > 1 {
                places.append("\(Describe.number(safe.minY - onScreen.minY))pt under the status bar area (top \(Describe.number(screen.safeArea.top))pt)")
            }
            if screen.safeArea.bottom > 0, onScreen.maxY - safe.maxY > 1 {
                places.append("\(Describe.number(onScreen.maxY - safe.maxY))pt into the home indicator area (bottom \(Describe.number(screen.safeArea.bottom))pt)")
            }
            if screen.safeArea.left > 0, safe.minX - onScreen.minX > 1 { places.append("\(Describe.number(safe.minX - onScreen.minX))pt into the left inset") }
            if screen.safeArea.right > 0, onScreen.maxX - safe.maxX > 1 { places.append("\(Describe.number(onScreen.maxX - safe.maxX))pt into the right inset") }
            guard !places.isEmpty else { continue }
            issues.append(Issue(rule: .unsafeArea, severity: .warning, ref: e.ref,
                                message: "\(Describe.node(e)) \(Describe.frame(e.frame)) reaches \(places.joined(separator: " and "))", frame: e.frame))
        }
        return issues
    }

    private func smallTargets(_ content: [IndexedSnapshot.Entry], skip: Set<Int>) -> [Issue] {
        var issues: [Issue] = []
        // Text fields are left out: in a Form or List the whole row focuses them.
        for e in content where e.node.role == .control && !skip.contains(e.ref) && !e.node.has("disabled")
            && !e.node.type.contains("TextField") && !e.node.type.contains("SecureField") {
            let w = e.frame.width, h = e.frame.height
            guard w >= 1, h >= 1, min(w, h) < minimumTarget else { continue }
            issues.append(Issue(rule: .smallTarget, severity: .warning, ref: e.ref,
                                message: "\(Describe.node(e)) \(Describe.frame(e.frame)) is \(Describe.number(w))x\(Describe.number(h))pt; tappable areas should be at least \(Describe.number(minimumTarget))x\(Describe.number(minimumTarget))pt (44x44 recommended)",
                                frame: e.frame))
        }
        return issues
    }

    private func brokenConstraints(_ s: IndexedSnapshot) -> [Issue] {
        var issues: [Issue] = []
        var seen = Set<String>()
        for b in s.snapshot.constraintBreaks where b.system != true {
            let broken = Describe.constraint(b.broken)
            guard seen.insert(broken).inserted else { continue }
            // Point at the first involved view apvt can find by identifier.
            var ref: Int?
            for v in b.views {
                guard let hash = v.firstIndex(of: "#") else { continue }
                let id = String(v[v.index(after: hash)...])
                if let e = s.entries.first(where: { $0.node.identifier == id }) { ref = e.ref; break }
            }
            let others = b.conflicting.map(Describe.constraint).filter { $0 != broken }
            issues.append(Issue(rule: .brokenConstraint, severity: .error, ref: ref,
                                message: "UIKit broke \(broken) (views: \(b.views.joined(separator: ", "))); it conflicts with \(others.joined(separator: "; "))",
                                frame: ref.map { s[$0].frame }))
        }
        return issues
    }

    private func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

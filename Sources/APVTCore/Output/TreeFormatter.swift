import APVTModel
import Foundation

/// The view tree as indented lines, written to be cheap to read:
///
///     @9 HostingView (0,0 402x874) {clips}
///       @10 .safeArea > @11 .frame (-22.7,116 447.3x724) [frame]
///         @13 Text "Recent posts" (-6.7,324.3 124.7x26.3) !offscreen
///
/// Private views are left out (their children are kept), system chrome is folded into one line,
/// and a chain of nodes with the same frame is printed as `A > B > C`.
public struct TreeFormatter: Sendable {
    public var showAll = false
    public var maxDepth: Int?
    public var root: Int?

    public init() {}

    public func format(_ s: IndexedSnapshot, issues: [Issue]) -> String {
        var issuesByRef: [Int: [String]] = [:]
        for issue in issues {
            if let ref = issue.ref { issuesByRef[ref, default: []].append(issue.rule.rawValue) }
        }
        var lines: [String] = []

        func shown(_ e: IndexedSnapshot.Entry) -> Bool {
            showAll || !(e.node.has("internal") && e.childRefs.isEmpty == false ? true : e.node.has("internal"))
        }

        /// The children to print under a node: hidden private views are replaced by their children.
        func visibleChildren(of ref: Int) -> [Int] {
            var result: [Int] = []
            for child in s[ref].childRefs {
                let e = s[child]
                if !showAll && e.node.has("internal") {
                    result += visibleChildren(of: child)
                } else {
                    result.append(child)
                }
            }
            return result
        }

        func label(_ e: IndexedSnapshot.Entry) -> String {
            Describe.node(e)
        }

        func suffix(_ e: IndexedSnapshot.Entry) -> String {
            var parts: [String] = [Describe.frame(e.frame)]
            if let detail = e.node.detail, detail.hasPrefix(".") { parts.append(detail) }
            if let mods = e.node.modifiers, !mods.isEmpty { parts.append("[" + mods.joined(separator: ",") + "]") }
            var traits = (e.node.traits ?? []).filter { !["wrapper", "system", "internal", "interactive"].contains($0) }
            if let alpha = e.node.alpha { traits.append("alpha \(Describe.number(alpha))") }
            if let scroll = e.node.scroll {
                traits.append("scrolls content \(Describe.number(scroll.contentWidth))x\(Describe.number(scroll.contentHeight)) offset \(Describe.number(scroll.offsetX)),\(Describe.number(scroll.offsetY))")
            }
            if !traits.isEmpty { parts.append("{" + traits.joined(separator: ", ") + "}") }
            if let rules = issuesByRef[e.ref] { parts.append(rules.map { "!" + $0 }.joined(separator: " ")) }
            return parts.joined(separator: " ")
        }

        func emit(_ ref: Int, depth: Int) {
            if let maxDepth, depth > maxDepth { return }
            var chain = [s[ref]]
            var children = visibleChildren(of: ref)
            // Fold same-frame single-child chains.
            while children.count == 1, let only = chain.last, only.node.text == nil, issuesByRef[only.ref] == nil,
                  !(only.system != s[children[0]].system),
                  sameFrame(only.frame, s[children[0]].frame) {
                chain.append(s[children[0]])
                children = visibleChildren(of: children[0])
            }
            let last = chain[chain.count - 1]
            let indent = String(repeating: "  ", count: depth)
            if !showAll, last.system, !(last.parent.map { s[$0].system } ?? false) {
                let count = s.descendants(of: last.ref).count
                lines.append(indent + chain.map(label).joined(separator: " > ") + " " + Describe.frame(last.frame) + " {system chrome, \(count) nodes folded; --all shows them}")
                return
            }
            lines.append(indent + chain.map(label).joined(separator: " > ") + " " + suffix(last))
            for child in children { emit(child, depth: depth + 1) }
        }

        if let root {
            emit(root, depth: 0)
        } else {
            for e in s.entries where e.parent == nil { emit(e.ref, depth: 0) }
        }
        return lines.joined(separator: "\n")
    }

    private func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

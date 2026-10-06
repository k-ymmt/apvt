import APVTModel
import Foundation

/// The checks `apvt assert` runs on every node its selector matches.
public struct AssertionSpec: Sendable {
    public enum Reference: Sendable {
        case screen, safeArea
        case node(NodeSelector)

        public init(_ string: String) throws {
            switch string {
            case "screen": self = .screen
            case "safe-area", "safearea", "safe": self = .safeArea
            default: self = .node(try NodeSelector(string))
            }
        }
    }

    public struct Comparison: Sendable, CustomStringConvertible {
        public enum Op: String, Sendable { case eq = "==", ge = ">=", le = "<=", gt = ">", lt = "<" }
        public var op: Op
        public var value: Double

        public init(_ string: String) throws {
            let s = string.replacingOccurrences(of: " ", with: "")
            for op in [Op.ge, .le, .eq, .gt, .lt] where s.hasPrefix(op.rawValue) {
                guard let v = Double(s.dropFirst(op.rawValue.count)) else { break }
                self.op = op; self.value = v; return
            }
            if s.hasPrefix("="), let v = Double(s.dropFirst()) { op = .eq; value = v; return }
            guard let v = Double(s) else {
                throw APVTError(.usage, "\"\(string)\" is not a size", fix: ["--width 150", "--width \">=44\"", "--height \"<=100\""])
            }
            op = .eq; value = v
        }

        func holds(_ actual: Double, tolerance: Double) -> Bool {
            switch op {
            case .eq: abs(actual - value) <= tolerance
            case .ge: actual >= value - tolerance
            case .le: actual <= value + tolerance
            case .gt: actual > value
            case .lt: actual < value
            }
        }

        public var description: String { "\(op.rawValue) \(Describe.number(value))" }
    }

    public enum Edge: String, Sendable, CaseIterable {
        case leading, trailing, top, bottom, centerX = "center-x", centerY = "center-y"

        func value(_ r: Rect) -> Double {
            switch self {
            case .leading: r.minX
            case .trailing: r.maxX
            case .top: r.minY
            case .bottom: r.maxY
            case .centerX: r.midX
            case .centerY: r.midY
            }
        }
    }

    public enum Direction: String, Sendable {
        case leftOf = "left-of", rightOf = "right-of", above, below
    }

    public var count: Int?
    public var visible = false
    public var inside: [Reference] = []
    public var notTruncated = false
    public var noOverlap = false
    public var noIssues = false
    public var width: Comparison?
    public var height: Comparison?
    public var aligned: [(Edge, Reference)] = []
    public var sameWidth: [Reference] = []
    public var sameHeight: [Reference] = []
    public var relative: [(Direction, Reference)] = []
    /// For `relative`: the gap between the two, when given.
    public var spacing: Comparison?
    public var tolerance: Double = 0.5

    public init() {}

    public var isEmpty: Bool {
        count == nil && !visible && inside.isEmpty && !notTruncated && !noOverlap && !noIssues && width == nil
            && height == nil && aligned.isEmpty && sameWidth.isEmpty && sameHeight.isEmpty && relative.isEmpty
    }
}

public struct AssertionResult: Codable, Sendable {
    public var ref: Int?
    public var node: String
    public var check: String
    public var passed: Bool
    public var detail: String
}

public enum Assertions {
    public static func evaluate(_ spec: AssertionSpec, selector: NodeSelector, in s: IndexedSnapshot,
                                issues: [Issue], includeSystem: Bool) throws -> [AssertionResult] {
        let matches = selector.select(in: s, includeSystem: includeSystem)
        var results: [AssertionResult] = []
        if let count = spec.count {
            results.append(AssertionResult(ref: nil, node: selector.description, check: "count == \(count)",
                                           passed: matches.count == count,
                                           detail: "\(matches.count) match\(matches.count == 1 ? "" : "es")" + (matches.isEmpty ? "" : ": " + matches.prefix(8).map { Describe.node($0) }.joined(separator: ", "))))
        }
        if matches.isEmpty {
            if spec.count == nil {
                results.append(AssertionResult(ref: nil, node: selector.description, check: "exists", passed: false,
                                               detail: "no node matches \(selector.description) (try apvt query, or apvt tree to see identifiers and texts)"))
            }
            return results
        }
        let screen = s.snapshot.screen
        func resolve(_ reference: AssertionSpec.Reference) throws -> (String, Rect, Int?) {
            switch reference {
            case .screen: return ("screen", screen.bounds, nil)
            case .safeArea: return ("safe-area", screen.safeBounds, nil)
            case .node(let sel):
                let found = sel.select(in: s, includeSystem: true)
                guard found.count == 1 else {
                    throw APVTError(.usage, "the reference \(sel.description) matched \(found.count) nodes; it must match exactly one",
                                    why: found.isEmpty ? nil : found.prefix(6).map { Describe.node($0) }.joined(separator: ", "),
                                    fix: ["use @N from apvt tree, or add terms: type:Text,text:…"])
                }
                return (Describe.node(found[0]), found[0].frame, found[0].ref)
            }
        }
        let t = spec.tolerance
        for e in matches {
            let name = Describe.node(e)
            let f = e.frame
            func add(_ check: String, _ passed: Bool, _ detail: String) {
                results.append(AssertionResult(ref: e.ref, node: name, check: check, passed: passed, detail: detail))
            }
            if spec.isEmpty {
                add("exists", true, Describe.frame(f))
            }
            if spec.visible {
                var problems: [String] = []
                if e.hidden { problems.append("hidden (itself or an ancestor: isHidden / alpha 0)") }
                if f.isEmpty { problems.append("zero size") }
                if e.scrollAncestor == nil, !screen.bounds.contains(f, tolerance: t) {
                    problems.append(screen.bounds.intersection(f) == nil ? "outside the screen" : "partly outside the screen")
                }
                if let clip = e.clipRect, !clip.contains(f, tolerance: 1) {
                    problems.append("clipped by @\(e.clipper ?? 0)")
                }
                add("visible", problems.isEmpty, problems.isEmpty ? "\(Describe.frame(f)) on screen" : "\(Describe.frame(f)): " + problems.joined(separator: ", "))
            }
            for reference in spec.inside {
                let (refName, r, _) = try resolve(reference)
                let ok = r.contains(f, tolerance: t)
                var detail = "\(Describe.frame(f)) in \(refName) \(Describe.frame(r))"
                if !ok {
                    var over: [String] = []
                    if f.minX < r.minX - t { over.append("left by \(Describe.number(r.minX - f.minX))") }
                    if f.maxX > r.maxX + t { over.append("right by \(Describe.number(f.maxX - r.maxX))") }
                    if f.minY < r.minY - t { over.append("top by \(Describe.number(r.minY - f.minY))") }
                    if f.maxY > r.maxY + t { over.append("bottom by \(Describe.number(f.maxY - r.maxY))") }
                    detail += ": outside on the " + over.joined(separator: ", ") + "pt"
                }
                add("inside \(refName)", ok, detail)
            }
            if spec.notTruncated {
                let hits = issues.filter { $0.ref == e.ref && ($0.rule == .truncated || $0.rule == .squeezed || $0.rule == .clipped) }
                add("not truncated", hits.isEmpty, hits.isEmpty ? (e.node.text == nil ? "no text on this node" : "text fits") : hits.map(\.message).joined(separator: "; "))
            }
            if spec.noOverlap {
                let hits = issues.filter { $0.rule == .overlap && ($0.ref == e.ref || $0.related.contains(e.ref)) }
                add("no overlap", hits.isEmpty, hits.isEmpty ? "overlaps nothing" : hits.map(\.message).joined(separator: "; "))
            }
            if spec.noIssues {
                let hits = issues.filter { $0.ref == e.ref }
                add("no issues", hits.isEmpty, hits.isEmpty ? "none" : hits.map { "[\($0.rule.rawValue)] \($0.message)" }.joined(separator: "; "))
            }
            if let c = spec.width {
                add("width \(c)", c.holds(f.width, tolerance: t), "width is \(Describe.number(f.width))")
            }
            if let c = spec.height {
                add("height \(c)", c.holds(f.height, tolerance: t), "height is \(Describe.number(f.height))")
            }
            for (edge, reference) in spec.aligned {
                let (refName, r, _) = try resolve(reference)
                let a = edge.value(f), b = edge.value(r)
                add("\(edge.rawValue) aligned with \(refName)", abs(a - b) <= t, "\(edge.rawValue) \(Describe.number(a)) vs \(Describe.number(b)) (off by \(Describe.number(abs(a - b))))")
            }
            for reference in spec.sameWidth {
                let (refName, r, _) = try resolve(reference)
                add("same width as \(refName)", abs(f.width - r.width) <= t, "\(Describe.number(f.width)) vs \(Describe.number(r.width))")
            }
            for reference in spec.sameHeight {
                let (refName, r, _) = try resolve(reference)
                add("same height as \(refName)", abs(f.height - r.height) <= t, "\(Describe.number(f.height)) vs \(Describe.number(r.height))")
            }
            for (direction, reference) in spec.relative {
                let (refName, r, _) = try resolve(reference)
                let gap: Double
                switch direction {
                case .leftOf: gap = r.minX - f.maxX
                case .rightOf: gap = f.minX - r.maxX
                case .above: gap = r.minY - f.maxY
                case .below: gap = f.minY - r.maxY
                }
                var ok = gap >= -t
                var check = "\(direction.rawValue) \(refName)"
                if let spacing = spec.spacing {
                    ok = ok && spacing.holds(gap, tolerance: t)
                    check += " with spacing \(spacing)"
                }
                add(check, ok, "gap is \(Describe.number(gap))pt" + (gap < -t ? " (they overlap)" : ""))
            }
        }
        return results
    }
}

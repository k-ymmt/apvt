import APVTModel
import Foundation

/// Picks nodes out of a snapshot.
///
///     @12              the node numbered 12 in this snapshot
///     #follow          accessibilityIdentifier == "follow"
///     text:Follow      text (or label / placeholder) contains "Follow", case-insensitive
///     text=Follow      text is exactly "Follow"
///     type:Button      type or class name, case-insensitive (Text, UILabel, HStack, .frame, …)
///     role:control     window, container, text, image, control, shape, spacer, scroll, hosting
///     follow           an identifier, or else an exact text
///
/// Terms joined by `,` must all match: `type:Text,text:Inbox`.
public struct NodeSelector: Sendable, CustomStringConvertible {
    enum Term: Sendable {
        case ref(Int)
        case identifier(String)
        case textContains(String)
        case textEquals(String)
        case type(String)
        case role(Role)
        case bare(String)
    }

    let terms: [Term]
    public let description: String

    public init(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw APVTError(.usage, "empty selector", fix: NodeSelector.examples) }
        description = trimmed
        var terms: [Term] = []
        for raw in NodeSelector.split(trimmed) {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("@"), let n = Int(part.dropFirst()) {
                terms.append(.ref(n))
            } else if part.hasPrefix("#") {
                terms.append(.identifier(String(part.dropFirst())))
            } else if part.hasPrefix("text:") {
                terms.append(.textContains(NodeSelector.unquote(String(part.dropFirst(5)))))
            } else if part.hasPrefix("text=") {
                terms.append(.textEquals(NodeSelector.unquote(String(part.dropFirst(5)))))
            } else if part.hasPrefix("type:") {
                terms.append(.type(String(part.dropFirst(5))))
            } else if part.hasPrefix("role:") {
                guard let role = Role(rawValue: String(part.dropFirst(5))) else {
                    throw APVTError(.usage, "unknown role in \"\(part)\"",
                                    fix: ["roles: window, container, text, image, control, shape, spacer, scroll, hosting"])
                }
                terms.append(.role(role))
            } else if part.hasPrefix("@") {
                throw APVTError(.usage, "\"\(part)\" is not a node number", fix: ["@12   # numbers come from apvt tree / apvt inspect"])
            } else {
                terms.append(.bare(NodeSelector.unquote(part)))
            }
        }
        self.terms = terms
    }

    public static let examples = ["@12", "#follow", "text:Follow", "text=\"Recent posts\"", "type:Button", "type:Text,text:Inbox"]

    private static func split(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if ch == ",", !quoted { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        return parts
    }

    private static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
    }

    public var isRef: Bool {
        if terms.count == 1, case .ref = terms[0] { return true }
        return false
    }

    public func matches(_ e: IndexedSnapshot.Entry) -> Bool {
        terms.allSatisfy { term in
            let n = e.node
            let texts = [n.text?.string, n.label, n.text?.placeholder].compactMap { $0 }
            switch term {
            case .ref(let r): return e.ref == r
            case .identifier(let id): return n.identifier == id
            case .textContains(let t): return texts.contains { $0.localizedCaseInsensitiveContains(t) }
            case .textEquals(let t): return texts.contains(t)
            case .type(let t):
                return n.type.caseInsensitiveCompare(t) == .orderedSame || n.detail?.caseInsensitiveCompare(t) == .orderedSame
                    || (t.hasPrefix(".") == false && n.type.caseInsensitiveCompare("." + t) == .orderedSame)
            case .role(let role): return n.role == role
            case .bare(let b): return n.identifier == b || texts.contains(b)
            }
        }
    }

    /// Matches in pre-order. System and private views only for `@N` or when asked.
    public func select(in s: IndexedSnapshot, includeSystem: Bool = false) -> [IndexedSnapshot.Entry] {
        s.entries.filter { e in
            (includeSystem || isRef || (!e.system && !e.internal)) && matches(e)
        }
    }
}

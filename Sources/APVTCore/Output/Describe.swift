import APVTModel
import Foundation

/// How nodes, frames and numbers read in text output: short, exact, greppable.
public enum Describe {
    public static func number(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == r.rounded() { return String(Int(r)) }
        return String(format: "%.1f", r)
    }

    /// `(x,y wxh)` in points.
    public static func frame(_ r: Rect) -> String {
        "(\(number(r.x)),\(number(r.y)) \(number(r.width))x\(number(r.height)))"
    }

    public static func quoted(_ s: String, limit: Int = 40) -> String {
        let single = s.replacingOccurrences(of: "\n", with: "⏎")
        let cut = single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
        return "\"\(cut)\""
    }

    /// `@12 Button #follow "Follow"`.
    public static func node(_ node: Node) -> String {
        var parts = ["@\(node.ref ?? 0)", node.type]
        if let id = node.identifier { parts.append("#\(id)") }
        if let text = node.text?.string, !text.isEmpty {
            parts.append(quoted(text))
        } else if let placeholder = node.text?.placeholder, !placeholder.isEmpty {
            parts.append("placeholder:" + quoted(placeholder))
        } else if let label = node.label {
            parts.append("label:" + quoted(label))
        }
        return parts.joined(separator: " ")
    }

    public static func node(_ entry: IndexedSnapshot.Entry) -> String { node(entry.node) }

    /// UIKit constraint descriptions without memory addresses.
    public static func constraint(_ s: String) -> String {
        s.replacingOccurrences(of: #":0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<NSLayoutConstraint ", with: "<")
    }
}

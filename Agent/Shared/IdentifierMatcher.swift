import Foundation

/// What accessibility says about one element: SwiftUI's debug data carries neither identifiers
/// nor the strings actually shown, so they are read here and matched to nodes by frame.
struct AccessibilityElement {
    /// In the same coordinates as the nodes' frames.
    var frame: Rect
    var identifier: String?
    var label: String?
    var isButton: Bool
}

/// Gives SwiftUI nodes the identifiers and labels of the accessibility elements drawn where
/// they are.
enum IdentifierMatcher {
    static func assign(_ elements: [AccessibilityElement], to nodes: inout [Node]) {
        // An identifier set on a container reaches every element inside it (SwiftUI propagates
        // it): such a group names the nodes' lowest common ancestor, not each of them.
        var groups: [String: [AccessibilityElement]] = [:]
        for element in elements {
            if let id = element.identifier { groups[id, default: []].append(element) }
        }
        for element in elements where element.identifier == nil || groups[element.identifier!]!.count == 1 {
            if let path = bestPath(for: element, in: nodes) { apply(element, at: path, to: &nodes) }
        }
        for (id, members) in groups where members.count > 1 {
            let paths = members.compactMap { bestPath(for: $0, in: nodes) }
            guard var common = paths.first else { continue }
            for path in paths.dropFirst() {
                common = Array(zip(common, path).prefix(while: { $0 == $1 }).map(\.0))
            }
            guard !common.isEmpty else { continue }
            // `.background(…).accessibilityIdentifier(…)` names the decorated view: climb from
            // the common ancestor while the parent is a modifier whose other children are shapes.
            while common.count > 1 {
                let parentPath = Array(common.dropLast())
                let parent = node(at: parentPath, in: nodes)
                let others = parent.children.indices.filter { $0 != common.last! }.map { parent.children[$0] }
                guard parent.type.hasPrefix("."), others.allSatisfy({ $0.role == .shape }) else { break }
                common = parentPath
            }
            apply(AccessibilityElement(frame: .zero, identifier: id, label: nil, isButton: false), at: common, to: &nodes)
        }
    }

    private static func node(at path: [Int], in nodes: [Node]) -> Node {
        var list = nodes
        var current = nodes[path[0]]
        for index in path {
            current = list[index]
            list = current.children
        }
        return current
    }

    /// The node whose frame matches the element best: controls first, then the outermost of
    /// equal frames, and not one that already has an identifier.
    private static func bestPath(for element: AccessibilityElement, in nodes: [Node]) -> [Int]? {
        var best: (path: [Int], score: Double)?
        func score(_ a: Rect, _ b: Rect) -> Double {
            guard let i = a.intersection(b) else { return 0 }
            return i.area / max(a.area + b.area - i.area, 0.0001)
        }
        func search(_ list: [Node], path: [Int]) {
            for (index, node) in list.enumerated() {
                var s = score(node.frame, element.frame)
                if s > 0.85 {
                    if element.isButton, node.role == .control { s += 0.2 }
                    if node.identifier != nil { s -= 0.5 }
                    if best == nil || s > best!.score + 0.0001 { best = (path + [index], s) }
                }
                search(node.children, path: path + [index])
            }
        }
        search(nodes, path: [])
        if let best { return best.path }
        // `.offset` moves what is drawn (and its accessibility frame) but not the layout frame
        // SwiftUI reports, so the frames no longer overlap enough. Fall back to the nearest node
        // of the same size that shows the same text.
        guard let label = element.label, !label.isEmpty else { return nil }
        var near: (path: [Int], distance: Double)?
        func searchMoved(_ list: [Node], path: [Int]) {
            for (index, node) in list.enumerated() {
                if node.identifier == nil, node.text?.string == label || node.label == label,
                   abs(node.frame.width - element.frame.width) < 1, abs(node.frame.height - element.frame.height) < 1 {
                    let d = abs(node.frame.x - element.frame.x) + abs(node.frame.y - element.frame.y)
                    if near == nil || d < near!.distance { near = (path + [index], d) }
                }
                searchMoved(node.children, path: path + [index])
            }
        }
        searchMoved(nodes, path: [])
        return near?.path
    }

    private static func apply(_ element: AccessibilityElement, at path: [Int], to nodes: inout [Node]) {
        func update(_ list: inout [Node], _ path: ArraySlice<Int>) {
            guard let first = path.first else { return }
            if path.count == 1 {
                if let id = element.identifier, list[first].identifier == nil { list[first].identifier = id }
                // The debug data holds a Text's localization key; accessibility holds what is shown.
                if list[first].type == "Text", let label = element.label, !label.isEmpty, element.frame != .zero {
                    list[first].text?.string = label
                    return
                }
                if let label = element.label, label != list[first].text?.string, list[first].label == nil,
                   list[first].role == .control || element.identifier != nil {
                    list[first].label = label
                }
            } else {
                update(&list[first].children, path.dropFirst())
            }
        }
        update(&nodes, path[...])
    }
}

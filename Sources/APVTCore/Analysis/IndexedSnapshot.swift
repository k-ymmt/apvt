import APVTModel
import Foundation

/// A snapshot with every node numbered (`@N`, pre-order over all windows) and the context
/// each node lives in: ancestors, clipping, scrolling, visibility, system chrome.
public struct IndexedSnapshot: Sendable {
    public struct Entry: Sendable {
        public var ref: Int
        /// The node without its children (they are entries of their own).
        public var node: Node
        public var parent: Int?
        public var ancestors: [Int]
        public var depth: Int
        public var childRefs: [Int]
        /// The visible area left after clipping ancestors that are not scroll views and do
        /// not cover the whole screen (those are the screen's job). nil = not clipped.
        public var clipRect: Rect?
        /// The nearest clipping ancestor that produced `clipRect`.
        public var clipper: Int?
        /// The nearest ancestor that scrolls (a UIScrollView that is not a text view).
        public var scrollAncestor: Int?
        /// Hidden, or fully transparent, itself or through an ancestor.
        public var hidden: Bool
        /// System chrome (bars, keyboard) or a framework's private view.
        public var system: Bool
        public var `internal`: Bool
        /// The nearest ancestor that is a control (a text inside a button is the button's).
        public var controlAncestor: Int?

        public var frame: Rect { node.frame }
        public var isAppContent: Bool { !system && !`internal` && !hidden }
        public var visibleFrame: Rect? {
            guard let clipRect else { return node.frame }
            return node.frame.intersection(clipRect)
        }
    }

    public var snapshot: Snapshot
    public var entries: [Entry]

    public init(_ snapshot: Snapshot) {
        var numbered = snapshot
        var entries: [Entry] = []
        var counter = 0
        let screen = snapshot.screen.bounds

        func visit(_ node: inout Node, parent: Int?, ancestors: [Int], clip: Rect?, clipper: Int?, scroll: Int?,
                   hidden: Bool, system: Bool, internalFlag: Bool, control: Int?) {
            counter += 1
            let ref = counter
            node.ref = ref
            let isHidden = hidden || node.has("hidden") || (node.alpha ?? 1) < 0.01
            let isSystem = system || node.has("system")
            let isInternal = internalFlag || node.has("internal")
            var entry = Entry(ref: ref, node: node, parent: parent, ancestors: ancestors, depth: ancestors.count,
                              childRefs: [], clipRect: clip, clipper: clipper, scrollAncestor: scroll, hidden: isHidden,
                              system: isSystem, internal: isInternal, controlAncestor: control)
            entry.node.children = []
            let index = entries.count
            entries.append(entry)
            if let parent { entries[parent - 1].childRefs.append(ref) }

            // What this node imposes on its descendants.
            var childClip = clip
            var childClipper = clipper
            var childScroll = scroll
            let scrolls = node.scroll != nil
            if scrolls {
                childScroll = ref
            } else if node.has("clips"), !node.frame.contains(screen, tolerance: 1) {
                childClip = clip.flatMap { $0.intersection(node.frame) } ?? (clip == nil ? node.frame : Rect.zero)
                childClipper = ref
            }
            let childControl = node.role == .control ? ref : control
            for i in node.children.indices {
                visit(&node.children[i], parent: ref, ancestors: ancestors + [ref], clip: childClip, clipper: childClipper,
                      scroll: childScroll, hidden: isHidden, system: isSystem, internalFlag: isInternal, control: childControl)
            }
            entries[index].node.ref = ref
        }
        for i in numbered.windows.indices {
            visit(&numbered.windows[i], parent: nil, ancestors: [], clip: nil, clipper: nil, scroll: nil,
                  hidden: false, system: false, internalFlag: false, control: nil)
        }
        self.snapshot = numbered
        self.entries = entries
    }

    public subscript(ref: Int) -> Entry {
        entries[ref - 1]
    }

    public func entry(_ ref: Int) -> Entry? {
        ref >= 1 && ref <= entries.count ? entries[ref - 1] : nil
    }

    public func isAncestor(_ a: Int, of b: Int) -> Bool {
        self[b].ancestors.contains(a)
    }

    public func descendants(of ref: Int) -> [Entry] {
        var result: [Entry] = []
        var stack = self[ref].childRefs.reversed().map { $0 }
        while let next = stack.popLast() {
            result.append(self[next])
            stack.append(contentsOf: self[next].childRefs.reversed())
        }
        return result
    }
}

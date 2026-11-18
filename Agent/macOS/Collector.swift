import AppKit
import ApplicationServices
import Foundation

/// Walks one window: NSViews as they are, SwiftUI from each hosting view's debug data.
/// Frames are in window points from the window's top-left corner, title bar included.
@MainActor
struct Collector {
    private let selection: Windows.Selection
    private var window: NSWindow { selection.window }
    private var notes: [String] = []
    private var emptyHostingViews = 0
    /// Toolbar items found inside the title bar: reported next to it, as the app's content.
    private var toolbarItems: [NSView] = []
    private var accessibility: [AccessibilityElement]?

    init(_ selection: Windows.Selection) {
        self.selection = selection
    }

    // MARK: - Snapshot

    mutating func snapshot() -> Snapshot {
        let size = window.frame.size
        let className = NSStringFromClass(type(of: window))
        let shortName = String(describing: type(of: window))
        var root = Node(source: .appkit, type: shortName, detail: className == shortName ? nil : className, role: .window,
                        frame: Rect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)))
        if !window.title.isEmpty { root.label = window.title }
        if let top = window.contentView?.superview ?? window.contentView {
            root.children.append(collect(top, system: false, chrome: false, depth: 0))
        }
        if !toolbarItems.isEmpty {
            let items = toolbarItems
            toolbarItems = []
            let nodes = items.map { collect($0, system: false, chrome: false, depth: 1) }
            var frame = nodes[0].frame
            for node in nodes.dropFirst() { frame = union(frame, node.frame) }
            root.children.append(Node(source: .appkit, type: "NSToolbar", role: .container, frame: frame, children: nodes))
        }
        if emptyHostingViews > 0 {
            notes.append("SwiftUI layout is missing for \(emptyHostingViews) hosting view(s): their view graph was built before the agent asked SwiftUI to record it. Relaunch the app with `apvt launch` to see SwiftUI views; AppKit views are complete.")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        return Snapshot(
            platform: Snapshot.macOS,
            app: AppInfo(bundleId: Bundle.main.bundleIdentifier ?? "", name: ProcessInfo.processInfo.processName, pid: getpid(), osVersion: os),
            screen: ScreenInfo(width: Double(size.width), height: Double(size.height), scale: Double(window.backingScaleFactor),
                               safeArea: EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
            window: selection.info,
            otherWindows: selection.others,
            windows: [root],
            constraintBreaks: ConstraintMonitor.recorded,
            notes: notes
        )
    }

    /// `[{"view": class, "frame": [x,y,w,h], "data": <makeViewDebugData JSON>}]`, for fixtures.
    func rawSwiftUIData() -> Data {
        var out = Data("{\"ok\":true,\"hostingViews\":[".utf8)
        var first = true
        func visit(_ view: NSView) {
            if let result = SwiftUIDebugData.read(view) {
                let f = view.apvtFrame()
                if !first { out.append(Data(",".utf8)) }
                first = false
                let rebuilt = (try? JSONSerialization.data(withJSONObject: result.rebuilt)) ?? Data("[]".utf8)
                let header = "{\"view\":\(jsonString(NSStringFromClass(type(of: view)))),\"frame\":[\(f.x),\(f.y),\(f.width),\(f.height)],\"rebuilt\":\(String(decoding: rebuilt, as: UTF8.self)),\"data\":"
                out.append(Data(header.utf8))
                out.append((try? JSONSerialization.data(withJSONObject: result.nodes)) ?? Data("[]".utf8))
                out.append(Data("}".utf8))
            }
            view.subviews.forEach(visit)
        }
        if let top = window.contentView?.superview ?? window.contentView { visit(top) }
        out.append(Data("]}".utf8))
        return out
    }

    private func jsonString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private func union(_ a: Rect, _ b: Rect) -> Rect {
        let minX = min(a.minX, b.minX), minY = min(a.minY, b.minY)
        return Rect(x: minX, y: minY, width: max(a.maxX, b.maxX) - minX, height: max(a.maxY, b.maxY) - minY)
    }

    // MARK: - AppKit

    /// The window's own furniture: the title bar with its buttons and title, the toolbar's frame.
    private static let chromePrefixes = ["NSTitlebar", "_NSTitlebar", "NSToolbarView", "_NSToolbar", "NSToolbarFullScreen",
                                         "_NSThemeWidget", "NSThemeWidget", "NSTabBar", "_NSFullScreen"]

    private mutating func collect(_ view: NSView, system: Bool, chrome: Bool, depth: Int) -> Node {
        let className = NSStringFromClass(type(of: view))
        let swiftName = String(describing: type(of: view))
        let shortName = SwiftUIDebugParser.splitGeneric(swiftName).base
        let hosting = isHostingView(view)
        let isChrome = chrome || Self.chromePrefixes.contains(where: className.hasPrefix)
        var system = system || isChrome
        // AppKit draws its own controls with SwiftUI: those hosting views are not the app's.
        if hosting && isAppKitModuleClass(className) { system = true }

        var node = Node(source: .appkit, type: shortName, detail: className == shortName ? nil : className,
                        role: role(of: view, hosting: hosting), frame: view.apvtFrame())
        let identifier = view.accessibilityIdentifier()
        if !identifier.isEmpty, !identifier.hasPrefix("_NS:") { node.identifier = identifier }
        if view.isHidden { node.addTrait("hidden") }
        if clips(view, frame: node.frame) { node.addTrait("clips") }
        if system { node.addTrait("system") }
        if className.hasPrefix("_"), !hosting, !isPlatformViewHost(className) { node.addTrait("internal") }
        // A scroller belongs to its scroll view: it lies over the content by design.
        if view is NSScroller { node.addTrait("internal") }
        if view.alphaValue < 0.999 { node.alpha = Double(view.alphaValue) }
        if !system, !view.translatesAutoresizingMaskIntoConstraints, view.hasAmbiguousLayout { node.addTrait("ambiguousLayout") }
        if let control = view as? NSControl, !isLabel(view) {
            node.addTrait("interactive")
            if !control.isEnabled { node.addTrait("disabled") }
        }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let visible = scroll.contentView.bounds
            let offsetY = document.isFlipped ? visible.minY : document.frame.height - visible.maxY
            node.scroll = ScrollInfo(contentWidth: Double(document.frame.width), contentHeight: Double(document.frame.height),
                                     offsetX: Double(visible.minX), offsetY: Double(offsetY), enabled: true)
        }
        node.text = text(of: view)
        if view is NSControl || view is NSImageView, !isLabel(view) {
            if let label = view.accessibilityLabel(), !label.isEmpty, label != node.text?.string { node.label = label }
        }

        var children: [Node] = []
        if hosting {
            children += swiftUINodes(in: view, system: system)
        }
        if depth < 200 {
            // A control draws itself (cells, private subviews): its insides are not the app's layout.
            let opaqueControl = view is NSControl
            for sub in view.subviews {
                let subName = NSStringFromClass(type(of: sub))
                if isChrome, subName.hasPrefix("NSToolbarItemViewer") {
                    toolbarItems.append(sub)
                    continue
                }
                var child = collect(sub, system: system, chrome: isChrome, depth: depth + 1)
                if opaqueControl { child = markInternal(child) }
                if hosting, isSwiftUIModuleClass(subName), !isPlatformViewHost(subName) {
                    child.addTrait("internal")
                }
                children.append(child)
            }
        }
        node.children = children
        return node
    }

    private func markInternal(_ node: Node) -> Node {
        var node = node
        node.addTrait("internal")
        node.children = node.children.map(markInternal)
        return node
    }

    /// A view that cuts off what its subviews draw outside it. One that covers the window's whole
    /// content area is left out: being cut there is being cut by the window.
    private func clips(_ view: NSView, frame: Rect) -> Bool {
        // A scroll view's clip view shows part of its document by design: that is scrolling.
        if let scroll = view.superview as? NSScrollView, scroll.contentView === view { return false }
        guard view is NSClipView || view.clipsToBounds || view.layer?.masksToBounds == true else { return false }
        guard let content = window.contentView else { return true }
        return !frame.contains(content.apvtFrame(), tolerance: 1)
    }

    /// An NSTextField that only shows text.
    private func isLabel(_ view: NSView) -> Bool {
        guard let field = view as? NSTextField else { return false }
        return !field.isEditable
    }

    private func role(of view: NSView, hosting: Bool) -> Role {
        if hosting { return .hosting }
        switch view {
        case is NSTextField: return isLabel(view) ? .text : .control
        case is NSTextView: return .text
        case is NSImageView: return .image
        case is NSControl: return .control
        case is NSScrollView: return .scroll
        default: return .container
        }
    }

    private func text(of view: NSView) -> TextInfo? {
        if let field = view as? NSTextField {
            if field.isEditable {
                var info = TextInfo(string: field.stringValue)
                info.placeholder = field.placeholderString ?? field.placeholderAttributedString?.string
                if let font = field.font { info.fontName = font.fontName; info.fontSize = Double(font.pointSize) }
                return info
            }
            let string = field.stringValue
            guard !string.isEmpty else { return nil }
            var info = TextInfo(string: string)
            let wraps = field.cell?.wraps ?? false
            info.maxLines = wraps ? field.maximumNumberOfLines : 1
            let font = field.font ?? TextMeasure.body()
            TextMeasure.fill(&info, font: font, width: Double(field.bounds.width))
            // The cell lays the text out with its own insets and attributes: trust it over NSString.
            if let cell = field.cell {
                let unbounded = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100_000))
                info.singleLineWidth = Double(ceil(unbounded.width))
                let wrapped = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(field.bounds.width, 1), height: 100_000))
                info.requiredHeight = Double(ceil(wraps ? wrapped.height : unbounded.height))
            }
            return info
        }
        if let button = view as? NSButton {
            let title = button.title
            guard !title.isEmpty else { return nil }
            var info = TextInfo(string: title)
            info.maxLines = 1
            let font = button.font ?? TextMeasure.body()
            TextMeasure.fill(&info, font: font, width: Double(button.bounds.width))
            // What the button needs for its title, bezel and image on one line.
            let needed = button.intrinsicContentSize
            if needed.width > 0 { info.singleLineWidth = Double(ceil(needed.width)) }
            info.requiredHeight = info.lineHeight
            return info
        }
        if let textView = view as? NSTextView {
            let string = textView.string
            guard !string.isEmpty else { return nil }
            var info = TextInfo(string: string)
            if let font = textView.font { info.fontName = font.fontName; info.fontSize = Double(font.pointSize) }
            return info
        }
        return nil
    }

    // MARK: - SwiftUI

    private func isHostingView(_ view: NSView) -> Bool {
        SwiftUIDebugData.isHostingView(view)
    }

    private func isSwiftUIModuleClass(_ name: String) -> Bool {
        name.hasPrefix("_TtC7SwiftUI") || name.hasPrefix("_TtGC7SwiftUI") || name.hasPrefix("SwiftUI.")
            || name.hasPrefix("_TtCC7SwiftUI") || name.hasPrefix("_TtCGC7SwiftUI")
    }

    private func isAppKitModuleClass(_ name: String) -> Bool {
        name.hasPrefix("_TtGC6AppKit") || name.hasPrefix("_TtC6AppKit") || name.hasPrefix("AppKit.") || name.hasPrefix("_NSCoreHosting")
    }

    private func isPlatformViewHost(_ name: String) -> Bool {
        name.contains("PlatformViewHost") || name.contains("PlatformGroupContainer")
    }

    private mutating func swiftUINodes(in view: NSView, system: Bool) -> [Node] {
        guard let debugData = SwiftUIDebugData.read(view) else {
            if !system { notes.append("SwiftUI's layout of \(String(describing: type(of: view)).prefix(60)) could not be read (its debug data is not in a form apvt knows); AppKit views are complete.") }
            return []
        }
        var nodes = SwiftUIDebugParser.parse(nodes: debugData.nodes, localize: Localizer.localize)
        if nodes.isEmpty {
            if !system { emptyHostingViews += 1 }
            return []
        }
        // Coordinate spaces: a ScrollView's content was recorded in its own; the document view of
        // the NSScrollView SwiftUI built for it (same size) converts that to the window.
        var scrollViews: [NSScrollView] = []
        func gather(_ v: NSView) {
            for sub in v.subviews {
                if let sv = sub as? NSScrollView, sv.documentView != nil, !(sv.documentView is NSTextView) { scrollViews.append(sv) }
                gather(sub)
            }
        }
        gather(view)
        var spaces: [Int: NSScrollView] = [:]
        func matchSpaces(_ list: [Node]) {
            for node in list {
                if let k = node.contentSpace, let content = node.scroll {
                    if let index = scrollViews.firstIndex(where: {
                        guard let size = $0.documentView?.frame.size else { return false }
                        return abs(Double(size.width) - content.contentWidth) < 1.5 && abs(Double(size.height) - content.contentHeight) < 1.5
                    }) {
                        spaces[k] = scrollViews.remove(at: index)
                    } else {
                        notes.append("could not find the NSScrollView of a SwiftUI ScrollView (content \(Int(content.contentWidth))x\(Int(content.contentHeight))); its content frames may be off")
                    }
                }
                matchSpaces(node.children)
            }
        }
        matchSpaces(nodes)
        nodes = nodes.map { place($0, in: view, spaces: spaces, system: system) }

        if !system {
            if accessibility == nil { accessibility = accessibilityElements() }
            IdentifierMatcher.assign(accessibility ?? [], to: &nodes)
        }
        return nodes.map(measure)
    }

    /// Recorded coordinates to window points; system subtrees marked.
    private func place(_ node: Node, in view: NSView, spaces: [Int: NSScrollView], system: Bool) -> Node {
        var node = node
        let f = NSRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
        if let k = node.space, let document = spaces[k]?.documentView {
            node.frame = document.apvtFrame(f, flippedInput: true)
        } else {
            node.frame = view.apvtFrame(f, flippedInput: true)
        }
        node.space = nil
        if let k = node.contentSpace, let scrollView = spaces[k], let document = scrollView.documentView {
            let visible = scrollView.contentView.bounds
            let offsetY = document.isFlipped ? visible.minY : document.frame.height - visible.maxY
            node.scroll = ScrollInfo(contentWidth: Double(document.frame.width), contentHeight: Double(document.frame.height),
                                     offsetX: Double(visible.minX), offsetY: Double(offsetY), enabled: true)
        }
        node.contentSpace = nil
        if system { node.addTrait("system") }
        node.children = node.children.map { place($0, in: view, spaces: spaces, system: system) }
        return node
    }

    /// Text metrics, with the font the debug data names (or one guessed from the frame).
    private func measure(_ node: Node) -> Node {
        var node = node
        if var info = node.text, node.type == "Text" || node.has("textNotLaidOut") {
            // Text that was not laid out says nothing about its font through the frame: body.
            let (font, guessed) = node.has("textNotLaidOut") && info.textStyle == nil && info.fontSize == nil
                ? (TextMeasure.body(), true)
                : TextMeasure.swiftUIFont(for: info, frame: node.frame)
            TextMeasure.fill(&info, font: font, width: node.frame.width)
            if guessed { info.fontGuessed = true }
            node.text = info
        }
        node.children = node.children.map(measure)
        return node
    }

    // MARK: - Accessibility

    private static let windowRoles: Set<String> = ["AXWindow", "AXSheet", "AXPopover", "AXDrawer", "AXSystemDialog", "AXDialog"]
    private static let buttonRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
                                                    "AXDisclosureTriangle", "AXSwitch", "AXToggle"]
    private static let attributes = ["AXRole", "AXIdentifier", "AXPosition", "AXSize", "AXTitle", "AXDescription", "AXValue", "AXChildren"]

    /// Identifiers and shown strings of this window's elements, in window points.
    ///
    /// SwiftUI answers accessibility through a private bridge that the in-process NSAccessibility
    /// walk does not reach (measured: AppKit identifiers only). The app asking the accessibility
    /// API about itself gets everything, and needs no accessibility permission for it.
    private mutating func accessibilityElements() -> [AccessibilityElement] {
        struct Found {
            var element: AccessibilityElement
            var container: Int
        }
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = CGPoint(x: window.frame.minX, y: screenHeight - window.frame.maxY)
        let windowRect = Rect(x: 0, y: 0, width: Double(window.frame.width), height: Double(window.frame.height))

        var found: [Found] = []
        // Windows, sheets and popovers: each element belongs to the nearest one above it.
        var containers: [Rect] = []
        var queue: [(element: AXUIElement, container: Int, depth: Int)] = [(app, -1, 0)]
        var next = 0
        var failures = 0
        while next < queue.count, next < 6000 {
            let (element, parentContainer, depth) = queue[next]
            next += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray, [], &raw) == .success,
                  let values = raw as? [Any], values.count == Self.attributes.count else {
                failures += 1
                continue
            }
            let role = values[0] as? String ?? ""
            if role == "AXMenuBar" || role == "AXMenu" { continue }
            var frame: Rect?
            if let position = point(values[2]), let size = size(values[3]) {
                frame = Rect(x: Double(position.x - origin.x), y: Double(position.y - origin.y), width: Double(size.width), height: Double(size.height))
            }
            var container = parentContainer
            if Self.windowRoles.contains(role), let frame {
                containers.append(frame)
                container = containers.count - 1
            } else if let frame {
                let identifier = (values[1] as? String).flatMap { $0.isEmpty || $0.hasPrefix("_NS:") ? nil : $0 }
                let title = values[4] as? String
                let description = values[5] as? String
                let value = values[6] as? String
                var label = role == "AXStaticText" ? value : nil
                if label?.isEmpty != false { label = title?.isEmpty == false ? title : description }
                if identifier != nil || label?.isEmpty == false {
                    found.append(Found(element: AccessibilityElement(frame: frame, identifier: identifier, label: label?.isEmpty == false ? label : nil,
                                                                     isButton: Self.buttonRoles.contains(role)),
                                       container: container))
                }
            }
            if depth < 60, let children = values[7] as? [AXUIElement] {
                for child in children { queue.append((child, container, depth + 1)) }
            }
        }
        if next <= 1, failures > 0 {
            notes.append("the app's accessibility elements could not be read; SwiftUI views have no identifiers (#id selectors will not match them)")
            return []
        }
        // The container drawn where this window is; without one, whatever lies inside the window.
        func overlap(_ a: Rect, _ b: Rect) -> Double {
            guard let i = a.intersection(b) else { return 0 }
            return i.area / max(a.area + b.area - i.area, 0.0001)
        }
        if let best = containers.indices.max(by: { overlap(containers[$0], windowRect) < overlap(containers[$1], windowRect) }),
           overlap(containers[best], windowRect) > 0.7 {
            return found.filter { $0.container == best }.map(\.element)
        }
        return found.filter { windowRect.contains($0.element.frame, tolerance: 1) }.map(\.element)
    }

    private func point(_ any: Any) -> CGPoint? {
        let object = any as AnyObject
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(object, to: AXValue.self)
        var result = CGPoint.zero
        return AXValueGetType(value) == .cgPoint && AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }

    private func size(_ any: Any) -> CGSize? {
        let object = any as AnyObject
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(object, to: AXValue.self)
        var result = CGSize.zero
        return AXValueGetType(value) == .cgSize && AXValueGetValue(value, .cgSize, &result) ? result : nil
    }
}

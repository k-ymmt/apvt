import Foundation
import UIKit

/// Walks every window: UIViews as they are, SwiftUI from each hosting view's debug data.
@MainActor
struct Collector {
    private let screen: UIScreen
    private let space: UICoordinateSpace
    private var notes: [String] = []
    private var emptyHostingViews = 0

    init() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        screen = scene?.screen ?? UIScreen.main
        space = screen.coordinateSpace
    }

    // MARK: - Snapshot

    mutating func snapshot() -> Snapshot {
        let windows = allWindows()
        let key = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden })
        let insets = key?.safeAreaInsets ?? .zero
        var nodes: [Node] = []
        for window in windows {
            let system = !isAppWindow(window)
            var node = collect(window, system: system, depth: 0)
            if system { node.addTrait("system") }
            nodes.append(node)
        }
        if emptyHostingViews > 0 {
            notes.append("SwiftUI layout is missing for \(emptyHostingViews) hosting view(s): their view graph was built before the agent asked SwiftUI to record it. Relaunch the app (with `apvt setup` done) to see SwiftUI views; UIKit views are complete.")
        }
        let bounds = screen.bounds
        return Snapshot(
            platform: "ios-simulator",
            app: AppInfo(bundleId: Bundle.main.bundleIdentifier ?? "", name: ProcessInfo.processInfo.processName,
                         pid: getpid(), osVersion: UIDevice.current.systemVersion),
            screen: ScreenInfo(width: bounds.width, height: bounds.height, scale: screen.scale,
                               safeArea: EdgeInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)),
            windows: nodes,
            constraintBreaks: ConstraintMonitor.recorded,
            notes: notes
        )
    }

    /// `[{"view": class, "frame": [x,y,w,h], "data": <makeViewDebugData JSON>}]`, for fixtures.
    func rawSwiftUIData() -> Data {
        var out = Data("{\"ok\":true,\"hostingViews\":[".utf8)
        var first = true
        func visit(_ view: UIView) {
            if let data = debugData(of: view) {
                let f = view.convert(view.bounds, to: space)
                if !first { out.append(Data(",".utf8)) }
                first = false
                let header = "{\"view\":\(jsonString(NSStringFromClass(type(of: view)))),\"frame\":[\(f.minX),\(f.minY),\(f.width),\(f.height)],\"data\":"
                out.append(Data(header.utf8))
                out.append(data.isEmpty ? Data("[]".utf8) : data)
                out.append(Data("}".utf8))
            }
            view.subviews.forEach(visit)
        }
        allWindows().forEach(visit)
        out.append(Data("]}".utf8))
        return out
    }

    private func jsonString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // MARK: - Windows

    private func allWindows() -> [UIWindow] {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows where !windows.contains(window) { windows.append(window) }
        }
        return windows.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    /// Keyboard, text-effects and status-bar windows belong to the system.
    private func isAppWindow(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return !(name.contains("Keyboard") || name.contains("TextEffects") || name.contains("StatusBar")) && window.windowLevel.rawValue < UIWindow.Level.statusBar.rawValue
    }

    // MARK: - UIKit

    private static let systemContainers = ["UINavigationBar", "UITabBar", "UIToolbar", "_UIFloatingBar", "_UITabBar"]

    private mutating func collect(_ view: UIView, system: Bool, depth: Int) -> Node {
        let className = NSStringFromClass(type(of: view))
        let swiftName = String(describing: type(of: view))
        let shortName = SwiftUIDebugParser.splitGeneric(swiftName).base
        let hosting = isHostingView(view)
        var system = system || view is UINavigationBar || view is UITabBar || view is UIToolbar
            || Self.systemContainers.contains(where: { className.hasPrefix($0) })
        if hosting && isUIKitModuleClass(className) { system = true }

        var node = Node(source: .uikit, type: shortName, detail: className == shortName ? nil : className,
                        role: role(of: view, hosting: hosting), frame: rect(view.convert(view.bounds, to: space)))
        if let id = view.accessibilityIdentifier, !id.isEmpty { node.identifier = id }
        if view.isHidden { node.addTrait("hidden") }
        if view.clipsToBounds || view.layer.masksToBounds { node.addTrait("clips") }
        if system { node.addTrait("system") }
        if className.hasPrefix("_") && !hosting && !isPlatformViewHost(className) { node.addTrait("internal") }
        if view.alpha < 0.999 { node.alpha = Double(view.alpha) }
        if !view.translatesAutoresizingMaskIntoConstraints, view.hasAmbiguousLayout { node.addTrait("ambiguousLayout") }
        if let control = view as? UIControl {
            node.addTrait("interactive")
            if !control.isEnabled { node.addTrait("disabled") }
        }
        if let scroll = view as? UIScrollView, !(view is UITextView) {
            node.scroll = ScrollInfo(contentWidth: scroll.contentSize.width, contentHeight: scroll.contentSize.height,
                                     offsetX: scroll.contentOffset.x, offsetY: scroll.contentOffset.y, enabled: scroll.isScrollEnabled)
        }
        node.text = text(of: view)
        if let label = view as? UILabel, label.adjustsFontSizeToFitWidth { node.addTrait("shrinksToFit") }
        if let label = view.accessibilityLabel, !label.isEmpty, label != node.text?.string, !(view is UILabel) {
            node.label = label
        }

        var children: [Node] = []
        if hosting {
            children += swiftUINodes(in: view, system: system)
        }
        if depth < 200 {
            // A control draws itself with private subviews (a UISwitch holds a 630pt image view):
            // only buttons and text fields have insides worth reading.
            let opaqueControl = view is UIControl && !(view is UIButton) && !(view is UITextField)
            for sub in view.subviews {
                var child = collect(sub, system: system, depth: depth + 1)
                if opaqueControl { child = markInternal(child) }
                if hosting, isSwiftUIModuleClass(NSStringFromClass(type(of: sub))), !isPlatformViewHost(NSStringFromClass(type(of: sub))) {
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

    private func rect(_ r: CGRect) -> Rect {
        Rect(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    private func role(of view: UIView, hosting: Bool) -> Role {
        if hosting { return .hosting }
        switch view {
        case is UIWindow: return .window
        case is UILabel, is UITextView: return .text
        case is UIImageView: return .image
        case is UIControl: return .control
        case is UIScrollView: return .scroll
        default: return .container
        }
    }

    private func text(of view: UIView) -> TextInfo? {
        if let label = view as? UILabel {
            guard let string = label.attributedText?.string ?? label.text, !string.isEmpty else { return nil }
            var info = TextInfo(string: string)
            info.maxLines = label.numberOfLines
            TextMeasure.fill(&info, font: label.font, width: Double(label.bounds.width))
            // UILabel lays out with its own rules (attributes, minimum scale); trust it over NSString.
            let needed = label.textRect(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude),
                                        limitedToNumberOfLines: 0)
            info.requiredHeight = Double(ceil(needed.height))
            return info
        }
        if let field = view as? UITextField {
            var info = TextInfo(string: field.text ?? "")
            info.placeholder = field.placeholder
            if let font = field.font { info.fontName = font.fontName; info.fontSize = Double(font.pointSize) }
            return info
        }
        if let textView = view as? UITextView {
            guard let string = textView.text, !string.isEmpty else { return nil }
            var info = TextInfo(string: string)
            if let font = textView.font { info.fontName = font.fontName; info.fontSize = Double(font.pointSize) }
            return info
        }
        return nil
    }

    // MARK: - SwiftUI

    private static let debugSelector = NSSelectorFromString("makeViewDebugData")
    private static let identifierSelector = NSSelectorFromString("accessibilityIdentifier")

    private func isHostingView(_ view: UIView) -> Bool {
        view.responds(to: Self.debugSelector)
    }

    private func isSwiftUIModuleClass(_ name: String) -> Bool {
        name.hasPrefix("_TtC7SwiftUI") || name.hasPrefix("_TtGC7SwiftUI") || name.hasPrefix("SwiftUI.")
            || name.hasPrefix("_TtCC7SwiftUI") || name.hasPrefix("_TtCGC7SwiftUI")
    }

    private func isUIKitModuleClass(_ name: String) -> Bool {
        name.hasPrefix("_TtGC5UIKit") || name.hasPrefix("_TtC5UIKit") || name.hasPrefix("UIKit.")
    }

    private func isPlatformViewHost(_ name: String) -> Bool {
        name.contains("PlatformViewHost") || name.contains("PlatformGroupContainer")
    }

    private func debugData(of view: UIView) -> Data? {
        guard view.responds(to: Self.debugSelector) else { return nil }
        return view.perform(Self.debugSelector)?.takeUnretainedValue() as? Data
    }

    private mutating func swiftUINodes(in view: UIView, system: Bool) -> [Node] {
        guard let data = debugData(of: view) else { return [] }
        var nodes: [Node]
        do {
            nodes = try SwiftUIDebugParser.parse(data, localize: Localizer.localize)
        } catch {
            notes.append("SwiftUI debug data of \(NSStringFromClass(type(of: view))) did not parse: \(error)")
            return []
        }
        if nodes.isEmpty {
            if !system { emptyHostingViews += 1 }
            return []
        }
        // Coordinate spaces: a ScrollView's content was recorded in its own; the UIScrollView
        // SwiftUI built for it (same content size) converts that to the screen.
        var scrollViews: [UIScrollView] = []
        func gather(_ v: UIView) {
            for sub in v.subviews {
                if let sv = sub as? UIScrollView, !(sub is UITextView) { scrollViews.append(sv) }
                gather(sub)
            }
        }
        gather(view)
        var spaces: [Int: UIScrollView] = [:]
        func matchSpaces(_ list: [Node]) {
            for node in list {
                if let k = node.contentSpace, let content = node.scroll {
                    if let index = scrollViews.firstIndex(where: {
                        abs($0.contentSize.width - content.contentWidth) < 1.5 && abs($0.contentSize.height - content.contentHeight) < 1.5
                    }) {
                        spaces[k] = scrollViews.remove(at: index)
                    } else {
                        notes.append("could not find the UIScrollView of a SwiftUI ScrollView (content \(Int(content.contentWidth))x\(Int(content.contentHeight))); its content frames may be off")
                    }
                }
                matchSpaces(node.children)
            }
        }
        matchSpaces(nodes)
        nodes = nodes.map { place($0, in: view, spaces: spaces, system: system) }

        // An identifier set on a container reaches every element inside it (SwiftUI propagates
        // it): such a group names the nodes' lowest common ancestor, not each of them.
        let axElements = accessibilityElements(of: view)
        var groups: [String: [AXElement]] = [:]
        for element in axElements {
            if let id = element.identifier { groups[id, default: []].append(element) }
        }
        for element in axElements where element.identifier == nil || groups[element.identifier!]!.count == 1 {
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
            apply(AXElement(frame: .zero, identifier: id, label: nil, isButton: false), at: common, to: &nodes)
        }
        return nodes.map(measure)
    }

    private func node(at path: [Int], in nodes: [Node]) -> Node {
        var list = nodes
        var current = nodes[path[0]]
        for index in path {
            current = list[index]
            list = current.children
        }
        return current
    }

    /// Recorded coordinates to screen points; system subtrees marked.
    private func place(_ node: Node, in view: UIView, spaces: [Int: UIScrollView], system: Bool) -> Node {
        var node = node
        let f = CGRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
        if let k = node.space, let scrollView = spaces[k] {
            node.frame = rect(scrollView.convert(f, to: space))
        } else {
            node.frame = rect(view.convert(f, to: space))
        }
        node.space = nil
        if let k = node.contentSpace, let scrollView = spaces[k] {
            node.scroll = ScrollInfo(contentWidth: scrollView.contentSize.width, contentHeight: scrollView.contentSize.height,
                                     offsetX: scrollView.contentOffset.x, offsetY: scrollView.contentOffset.y,
                                     enabled: scrollView.isScrollEnabled)
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
                ? (UIFont.preferredFont(forTextStyle: .body), true)
                : TextMeasure.swiftUIFont(for: info, frame: node.frame)
            TextMeasure.fill(&info, font: font, width: node.frame.width)
            if guessed { info.fontGuessed = true }
            node.text = info
        }
        node.children = node.children.map(measure)
        return node
    }

    private struct AXElement {
        var frame: Rect
        var identifier: String?
        var label: String?
        var isButton: Bool
    }

    /// Accessibility answers, for identifiers: SwiftUI's debug data does not carry them.
    private func accessibilityElements(of view: UIView) -> [AXElement] {
        var result: [AXElement] = []
        var visited = 0
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int) {
            visited += 1
            guard depth < 40, visited < 5000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            // SwiftUI's nodes answer accessibilityIdentifier without declaring the protocol.
            let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
                ?? (object.responds(to: Self.identifierSelector) ? object.perform(Self.identifierSelector)?.takeUnretainedValue() as? String : nil)
            let label = object.accessibilityLabel
            if (identifier?.isEmpty == false) || (label?.isEmpty == false) {
                result.append(AXElement(frame: rect(object.accessibilityFrame), identifier: identifier?.isEmpty == false ? identifier : nil,
                                        label: label, isButton: object.accessibilityTraits.contains(.button)))
            }
            let children: [Any]
            if let elements = object.accessibilityElements {
                children = elements
            } else {
                let count = object.accessibilityElementCount()
                children = count > 0 && count != NSNotFound && count < 2000 ? (0..<count).compactMap { object.accessibilityElement(at: $0) } : []
            }
            for child in children {
                if let child = child as? NSObject, !(child is UIView) { visit(child, depth: depth + 1) }
            }
        }
        visit(view, depth: 0)
        // A ScrollView's elements hang off the UIScrollView SwiftUI made for it, not the hosting
        // view: visit the UIKit views under this hosting view too, up to the next hosting view.
        func walk(_ v: UIView) {
            for sub in v.subviews where !isHostingView(sub) && !(sub is UINavigationBar) && !(sub is UITabBar) && !(sub is UIToolbar) {
                // SwiftUI's own UIKit containers (PlatformContainer, HostingScrollView) only:
                // UIKit's navigation views announce elements of their own ("Toolbar").
                if isSwiftUIModuleClass(NSStringFromClass(type(of: sub))) { visit(sub, depth: 0) }
                walk(sub)
            }
        }
        walk(view)
        return result
    }

    /// The node whose frame matches the element best: controls first, then the outermost of
    /// equal frames, and not one that already has an identifier.
    private func bestPath(for element: AXElement, in nodes: [Node]) -> [Int]? {
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
        return best?.path
    }

    private func apply(_ element: AXElement, at path: [Int], to nodes: inout [Node]) {
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

/// What a `LocalizedStringKey` shows in the app's current language. SwiftUI looks keys up in
/// `Localizable` of the main bundle unless a view names another bundle — which the debug data
/// does not say, so the other loaded bundles (Swift packages' resources) are tried next.
@MainActor
enum Localizer {
    private static var cache: [String: String?] = [:]
    private static let missing = "\u{1}apvt-missing\u{1}"

    static func localize(_ key: String) -> String? {
        MainActor.assumeIsolated {
            if let hit = cache[key] { return hit }
            var result: String?
            for bundle in [Bundle.main] + Bundle.allBundles + resourceBundles() {
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                if value != missing { result = value; break }
            }
            cache[key] = result
            return result
        }
    }

    private static var resources: [Bundle]?

    /// `*.bundle` resource bundles inside the app (SwiftPM `Bundle.module`s), loaded lazily by the app.
    private static func resourceBundles() -> [Bundle] {
        if let resources { return resources }
        let urls = (try? FileManager.default.contentsOfDirectory(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)) ?? []
        let found = urls.filter { $0.pathExtension == "bundle" }.compactMap(Bundle.init(url:))
        resources = found
        return found
    }
}

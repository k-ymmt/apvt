import Foundation

/// Turns what `_UIHostingView.makeViewDebugData()` returns into `Node`s.
///
/// SwiftUI records this only when `SWIFTUI_VIEW_DEBUG` is set before a view graph is created
/// (measured on iOS 27.0: setting `_ViewDebug.properties` later does not reach existing graphs).
/// Each raw node carries properties by id — 0 type, 1 value, 2 transform, 3 position, 4 size —
/// where position and size are the layout frame in the hosting view's coordinate space.
///
/// Every raw node with a position and a size becomes a `Node`. The raw nodes between two such
/// nodes are modifiers and SwiftUI internals: the ones a developer would recognise are kept as
/// `modifiers` (`clipped`, `offset`, `button`, …), the rest are dropped. Children come out in
/// declaration order (the raw data lists them last-first).
public enum SwiftUIDebugParser {
    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Nodes in the hosting view's coordinate space.
    public static func parse(_ data: Data) throws -> [Node] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let roots = json as? [[String: Any]] else {
            throw ParseError(description: "view debug data is not an array of nodes")
        }
        var nodes: [Node] = []
        for root in roots {
            nodes += convert(root, font: nil)
        }
        return nodes
    }

    // MARK: - Raw access

    private static func attribute(_ raw: [String: Any], _ id: Int) -> [String: Any]? {
        guard let properties = raw["properties"] as? [[String: Any]] else { return nil }
        for p in properties where (p["id"] as? Int) == id {
            return p["attribute"] as? [String: Any]
        }
        return nil
    }

    private static func pair(_ attr: [String: Any]?) -> (Double, Double)? {
        guard let v = attr?["value"] as? [Any], v.count == 2,
              let a = number(v[0]), let b = number(v[1]) else { return nil }
        return (a, b)
    }

    /// JSON numbers arrive as NSNumber, and an NSNumber 0 or 1 also casts to Bool: ask CF.
    static func number(_ any: Any) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func children(_ raw: [String: Any]) -> [[String: Any]] {
        (raw["children"] as? [[String: Any]] ?? []).reversed()
    }

    /// `_ShapeView<Circle, Color>` → (`_ShapeView`, [`Circle`, `Color`]).
    static func splitGeneric(_ type: String) -> (base: String, arguments: [String]) {
        guard let open = type.firstIndex(of: "<"), type.hasSuffix(">") else { return (type, []) }
        let base = String(type[..<open])
        let inner = type[type.index(after: open)..<type.index(before: type.endIndex)]
        var args: [String] = []
        var depth = 0
        var current = ""
        for ch in inner {
            switch ch {
            case "<", "(": depth += 1; current.append(ch)
            case ">", ")": depth -= 1; current.append(ch)
            case "," where depth == 0:
                args.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current.trimmingCharacters(in: .whitespaces)) }
        return (base, args)
    }

    // MARK: - Conversion

    private static func convert(_ raw: [String: Any], font: FontHint?) -> [Node] {
        let readable = attribute(raw, 0)?["readableType"] as? String ?? "?"
        let value = attribute(raw, 1)
        var font = font
        if readable.hasPrefix("_EnvironmentKeyWritingModifier<Optional<Font>>"), let value {
            font = FontHint(value) ?? font
        }
        guard let position = pair(attribute(raw, 3)), let size = pair(attribute(raw, 4)) else {
            return children(raw).flatMap { convert($0, font: font) }
        }

        let frame = Rect(x: position.0, y: position.1, width: size.0, height: size.1)
        var modifierNames: [String] = []
        var kids: [Node] = []
        var childFont = font
        // Content SwiftUI did not lay out on its own (a Text inside a collapsed label, a
        // button's background shape): it still belongs to this node.
        var looseText: TextInfo?
        var looseShape: String?
        // Walk the frameless chain under this node: its modifiers, then the next framed nodes.
        func descend(_ list: [[String: Any]]) {
            for child in list {
                if pair(attribute(child, 3)) != nil, pair(attribute(child, 4)) != nil {
                    kids += convert(child, font: childFont)
                } else {
                    let name = attribute(child, 0)?["readableType"] as? String ?? ""
                    if name.hasPrefix("_EnvironmentKeyWritingModifier<Optional<Font>>"),
                       let v = attribute(child, 1), let f = FontHint(v) {
                        childFont = f
                    }
                    if let m = modifierName(name) {
                        // Keep the arguments that explain a size: frame(width: 150), padding(…), offset(…).
                        if ["frame", "padding", "offset"].contains(m), let v = attribute(child, 1), let summary = scalarSummary(v) {
                            modifierNames.append("\(m)(\(summary))")
                        } else {
                            modifierNames.append(m)
                        }
                    }
                    let (base, args) = splitGeneric(name)
                    if base == "Text", looseText == nil, let v = attribute(child, 1) {
                        var info = TextInfo(string: textString(v))
                        let hint = FontHint(v) ?? childFont
                        info.textStyle = hint?.style
                        info.fontSize = hint?.size
                        info.bold = hint?.bold
                        if !info.string.isEmpty { looseText = info }
                    } else if base == "_ShapeView" || base == "StrokeShapeView", looseShape == nil {
                        looseShape = shapeName(args.first)
                    }
                    descend(children(child))
                }
            }
        }
        descend(children(raw))

        var node = makeNode(readable: readable, value: value, frame: frame, font: font)
        var seen = Set<String>()
        let modifiers = modifierNames.filter { seen.insert($0).inserted }
        if !modifiers.isEmpty { node.modifiers = modifiers }
        node.children = kids
        if modifiers.contains("button") {
            node.type = "Button"
            node.role = .control
            node.addTrait("interactive")
            node.traits?.removeAll { $0 == "wrapper" }
        }
        // A text field's insides (its placeholder ZStack, …) are drawn by the UIKit text field
        // it hosts, which the UIKit walk reports; SwiftUI does not lay them out.
        if node.role == .control, node.type.hasSuffix("Field") {
            node.children = node.children.map(markInternal)
        }
        if modifiers.contains("clipped") { node.addTrait("clips") }
        if modifiers.contains("hidden") { node.addTrait("hidden") }
        if kids.isEmpty, node.has("wrapper"), node.role != .control, let looseShape {
            node.type = looseShape
            node.role = .shape
            node.traits?.removeAll { $0 == "wrapper" }
        }
        if kids.isEmpty, node.has("wrapper"), node.role != .control, let looseText {
            // A Text whose frame SwiftUI recorded on the modifier around it.
            node.type = "Text"
            node.role = .text
            node.text = looseText
            node.traits?.removeAll { $0 == "wrapper" }
        } else if node.text == nil, let looseText, kids.allSatisfy({ $0.text == nil }) {
            // Owned, not laid out: measuring it against this node's frame tells whether it fits.
            node.text = looseText
            node.addTrait("textNotLaidOut")
        }

        // A wrapper (AccessibilityAttachmentModifier, ModifiedContent, …) that holds exactly one
        // node with the same frame says nothing on its own: fold it into that node.
        if node.has("wrapper"), node.role != .control, kids.count == 1, sameFrame(kids[0].frame, frame) {
            var only = kids[0]
            if let mods = node.modifiers {
                var merged = mods
                for m in only.modifiers ?? [] where !merged.contains(m) { merged.append(m) }
                only.modifiers = merged
                if merged.contains("clipped") { only.addTrait("clips") }
            }
            return [only]
        }
        if node.has("wrapper"), node.role != .control {
            node.type = wrapperName(node.modifiers ?? [], fallback: node.type)
        }
        return [node]
    }

    private static func markInternal(_ node: Node) -> Node {
        var node = node
        node.addTrait("internal")
        node.children = node.children.map(markInternal)
        return node
    }

    private static func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    private static func wrapperName(_ modifiers: [String], fallback: String) -> String {
        for preferred in ["clipped", "offset", "overlay", "background", "mask", "padding", "frame"]
        where modifiers.contains(where: { $0 == preferred || $0.hasPrefix(preferred + "(") }) {
            return "." + preferred
        }
        return fallback
    }

    private static let containers: Set<String> = [
        "HStack", "VStack", "ZStack", "LazyHStack", "LazyVStack", "LazyHGrid", "LazyVGrid",
        "Grid", "GridRow", "ViewThatFits", "Group", "Form", "Section",
    ]

    private static let layoutModifiers: [String: String] = [
        "_FrameLayout": ".frame", "_FlexFrameLayout": ".frame", "_PaddingLayout": ".padding",
        "_FixedSizeLayout": ".fixedSize", "_AspectRatioLayout": ".aspectRatio", "_OffsetEffect": ".offset",
        "_BackgroundModifier": ".background", "_BackgroundStyleModifier": ".background",
        "_OverlayModifier": ".overlay", "_PositionLayout": ".position", "_SafeAreaInsetsModifier": ".safeArea",
    ]

    private static func makeNode(readable: String, value: [String: Any]?, frame: Rect, font: FontHint?) -> Node {
        let (base, args) = splitGeneric(readable)
        func node(_ type: String, _ role: Role, traits: [String]? = nil) -> Node {
            Node(source: .swiftui, type: type, detail: readable == type ? nil : readable, role: role, frame: frame, traits: traits)
        }
        switch base {
        case "Text":
            var n = node("Text", .text)
            var info = TextInfo(string: value.map(textString) ?? "")
            let hint = value.flatMap(FontHint.init) ?? font
            info.textStyle = hint?.style
            info.fontSize = hint?.size
            info.bold = hint?.bold
            n.text = info
            return n
        case "Image", "_ImageView", "ImageLayout":
            return node("Image", .image)
        case "_ShapeView":
            return node(shapeName(args.first), .shape)
        case "StrokeShapeView", "_StrokedShape":
            return node(shapeName(args.first) + ".stroke", .shape)
        case "Color", "_ColorView":
            return node("Color", .shape)
        case "Spacer":
            return node("Spacer", .spacer)
        case "ConditionalSpacer":
            return node("Spacer", .spacer, traits: ["internal"])
        case "SystemTextField", "TextField", "SystemSecureField", "SecureField":
            return node(base.replacingOccurrences(of: "System", with: ""), .control, traits: ["interactive"])
        case "Divider":
            return node("Divider", .shape)
        default:
            if containers.contains(base) { return node(base, .container) }
            if let name = layoutModifiers[base] {
                var n = node(name, .container)
                if let value, let summary = scalarSummary(value) { n.detail = "\(name)(\(summary))" }
                return n
            }
            let cleaned = base.hasPrefix("_") ? String(base.drop(while: { $0 == "_" })) : base
            return node(cleaned, .container, traits: ["wrapper"])
        }
    }

    private static func shapeName(_ arg: String?) -> String {
        guard let arg else { return "Shape" }
        let (base, _) = splitGeneric(arg)
        return base.split(separator: ".").last.map(String.init) ?? base
    }

    /// The modifiers a reader of SwiftUI code would recognise, by the name they write.
    static func modifierName(_ readable: String) -> String? {
        let (base, args) = splitGeneric(readable)
        switch base {
        case "ButtonActionModifier": return "button"
        case "_ClipEffect": return "clipped"
        case "_OffsetEffect": return "offset"
        case "_BackgroundModifier", "_BackgroundStyleModifier", "_BackgroundShapeModifier": return "background"
        case "_OverlayModifier", "_OverlayStyleModifier", "_OverlayShapeModifier": return "overlay"
        case "_PaddingLayout": return "padding"
        case "_FrameLayout", "_FlexFrameLayout": return "frame"
        case "_FixedSizeLayout": return "fixedSize"
        case "_AspectRatioLayout": return "aspectRatio"
        case "_OpacityEffect": return "opacity"
        case "_SafeAreaRegionsIgnoringLayout", "_SafeAreaIgnoringLayout": return "ignoresSafeArea"
        case "_RotationEffect", "_Rotation3DEffect": return "rotationEffect"
        case "_ScaleEffect": return "scaleEffect"
        case "_ShadowEffect": return "shadow"
        case "_MaskEffect": return "mask"
        case "_HiddenModifier": return "hidden"
        case "_PositionLayout": return "position"
        case "_AllowsHitTestingModifier": return "allowsHitTesting"
        case "_TraitWritingModifier":
            if args.first?.contains("LayoutPriority") == true { return "layoutPriority" }
            if args.first?.contains("ZIndex") == true { return "zIndex" }
            return nil
        case "_EnvironmentKeyWritingModifier":
            if args.first == "Optional<Font>" { return "font" }
            return nil
        default: return nil
        }
    }

    // MARK: - Values

    /// The string a `Text` shows: its `verbatim` / localized `key` values, joined.
    static func textString(_ value: [String: Any]) -> String {
        var parts: [String] = []
        func walk(_ attr: [String: Any]) {
            if let name = attr["name"] as? String, name == "key" || name == "verbatim" || name == "string",
               let s = attr["value"] as? String {
                parts.append(s)
                return
            }
            for sub in attr["subattributes"] as? [[String: Any]] ?? [] { walk(sub) }
        }
        walk(value)
        return parts.joined()
    }

    /// `width: 150, height: 140` from a layout modifier's value.
    private static func scalarSummary(_ value: [String: Any]) -> String? {
        var parts: [String] = []
        for sub in value["subattributes"] as? [[String: Any]] ?? [] {
            guard let name = sub["name"] as? String else { continue }
            if let v = sub["value"], let n = number(v) {
                parts.append("\(name): \(format(n))")
            } else if let inner = sub["subattributes"] as? [[String: Any]], name == "insets" || name == "edges" {
                let vals = inner.compactMap { s -> String? in
                    guard let n = s["name"] as? String, let v = s["value"], let d = number(v) else { return nil }
                    return "\(n): \(format(d))"
                }
                if !vals.isEmpty { parts.append(vals.joined(separator: ", ")) }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}

/// What the debug data says about a font. SwiftUI serializes fonts only partly: a `.bold()`
/// font loses its base style, so this is a hint the agent completes or guesses.
struct FontHint {
    var style: String?
    var size: Double?
    var bold: Bool

    init?(_ value: [String: Any]) {
        var style: String?
        var size: Double?
        var bold = false
        var sawFont = false
        func walk(_ attr: [String: Any]) {
            let readable = attr["readableType"] as? String ?? ""
            if readable == "Font" || readable.hasPrefix("FontBox") { sawFont = true }
            if readable.contains("BoldModifier") { bold = true }
            if readable == "Font.TextStyle", let v = attr["value"] as? [String: Any], let key = v.keys.first {
                style = key
            }
            if attr["name"] as? String == "size", readable == "CGFloat", let v = attr["value"], let n = SwiftUIDebugParser.number(v) {
                size = n
            }
            if readable == "Font.Weight" || readable.hasSuffix("Weight"), let sub = attr["subattributes"] as? [[String: Any]],
               let v = sub.first?["value"], let n = SwiftUIDebugParser.number(v), n >= 0.3 {
                bold = true
            }
            for sub in attr["subattributes"] as? [[String: Any]] ?? [] { walk(sub) }
        }
        walk(value)
        guard sawFont else { return nil }
        self.style = style
        self.size = size
        self.bold = bold
    }
}

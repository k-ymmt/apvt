import AppKit
import Foundation
import SwiftUI

/// A hosting view of any content type, asked for SwiftUI's own record of its view tree.
@MainActor
protocol ViewDebugDataSource {
    func apvtViewDebugData() -> [_ViewDebug.Data]
}

extension NSHostingView: ViewDebugDataSource {
    func apvtViewDebugData() -> [_ViewDebug.Data] { _viewDebugData() }
}

/// SwiftUI's view debug data as the JSON nodes `SwiftUIDebugParser` reads.
///
/// `makeViewDebugData` serializes the whole tree at once, and on macOS one value SwiftUI cannot
/// encode makes it answer `{"error": …}` for all of it (measured on macOS 27 with a Picker or a
/// Button in a grouped Form, and with NavigationSplitView). So the tree is serialized here in
/// parts: whatever serializes is taken as it is, and a node that does not is rebuilt from its
/// type, position and size, with its children serialized on their own.
@MainActor
enum SwiftUIDebugData {
    struct Result {
        var nodes: [[String: Any]]
        /// Nodes SwiftUI could not serialize, rebuilt without their value.
        var rebuilt: [String] = []
    }

    private static let selector = NSSelectorFromString("makeViewDebugData")

    static func isHostingView(_ view: NSView) -> Bool {
        view.responds(to: selector)
    }

    /// nil: the view is not a hosting view, or its data is not what apvt understands.
    static func read(_ view: NSView) -> Result? {
        // The selector first: it is what SwiftUI itself offers, and it reads inside the update lock.
        guard view.responds(to: selector), let data = view.perform(selector)?.takeUnretainedValue() as? Data else { return nil }
        if let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return Result(nodes: nodes) }
        // `{"error": …}`: read the tree unserialized. `_viewDebugData()` does not take the update
        // lock, and without it SwiftUI traps on a value it has to compute (measured: a Picker in
        // a grouped Form) — so only with the lock, the way `makeViewDebugData` does it.
        guard let source = view as? any ViewDebugDataSource, let lock = UpdateLock.shared else { return nil }
        lock.begin()
        let list = source.apvtViewDebugData()
        lock.end()
        var result = Result(nodes: [])
        result.nodes = convert(list, &result.rebuilt)
        return result
    }

    private static func convert(_ list: [_ViewDebug.Data], _ rebuilt: inout [String]) -> [[String: Any]] {
        if list.isEmpty { return [] }
        if let data = _ViewDebug.serializedData(list), let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return nodes
        }
        if list.count > 1 { return list.flatMap { convert([$0], &rebuilt) } }
        // This node, or something below it, does not serialize: rebuild it and go on below.
        let mirror = Mirror(reflecting: list[0])
        let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
        let children = mirror.descendant("childData") as? [_ViewDebug.Data] ?? []
        var out: [[String: Any]] = []
        var name = "?"
        if let type = properties[.type] as? Any.Type {
            name = _typeName(type, qualified: false)
            out.append(["id": 0, "attribute": ["type": String(reflecting: type), "readableType": name, "flags": 0] as [String: Any]])
        }
        if let value = properties[.value] {
            out.append(["id": 1, "attribute": attribute(name: nil, value, depth: 0)])
        }
        if let position = properties[.position] as? CGPoint, position.x.isFinite, position.y.isFinite {
            out.append(["id": 3, "attribute": ["value": [Double(position.x), Double(position.y)]] as [String: Any]])
        }
        if let size = properties[.size] as? CGSize, size.width.isFinite, size.height.isFinite {
            out.append(["id": 4, "attribute": ["value": [Double(size.width), Double(size.height)]] as [String: Any]])
        }
        rebuilt.append(name)
        return [["properties": out, "children": convert(children, &rebuilt)]]
    }

    /// A value as SwiftUI's serializer shapes it, as far as the parser reads it: the type, a
    /// scalar or string value, and the stored properties below it.
    private static func attribute(name: String?, _ value: Any, depth: Int) -> [String: Any] {
        var result: [String: Any] = ["readableType": _typeName(type(of: value), qualified: false)]
        if let name { result["name"] = name }
        switch value {
        case let v as String: result["value"] = v
        case let v as Bool: result["value"] = v
        case let v as CGFloat: if v.isFinite { result["value"] = Double(v) }
        case let v as Double: if v.isFinite { result["value"] = v }
        case let v as Int: result["value"] = v
        default:
            guard depth < 12 else { break }
            let mirror = Mirror(reflecting: value)
            // An enum case reads like a Codable enum: {"body": {}}.
            if mirror.displayStyle == .enum, mirror.children.isEmpty {
                result["value"] = [String(describing: value): [String: Any]()] as [String: Any]
            }
            let children = mirror.children.prefix(40).map { attribute(name: $0.label, $0.value, depth: depth + 1) }
            if !children.isEmpty { result["subattributes"] = children }
        }
        return result
    }
}

/// SwiftUI's update lock, `UpdateGroup.main`: `begin()` … `end()` is what its `ensure { }` does
/// around `makeViewDebugData`. The symbols are exported by SwiftUICore for SwiftUI, not declared
/// for apps, so they are looked up at run time; nil where SwiftUI has none of them.
@MainActor
struct UpdateLock {
    let begin: () -> Void
    let end: () -> Void

    static let shared: UpdateLock? = {
        let image = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let main = dlsym(image, "$s7SwiftUI11UpdateGroupC4mainACvgZ"),
              let begin = dlsym(image, "$s7SwiftUI11UpdateGroupC5beginyyF"),
              let end = dlsym(image, "$s7SwiftUI11UpdateGroupC3endyyF") else { return nil }
        // `static var main: UpdateGroup { get }`: no arguments, the object comes back owned.
        typealias Getter = @convention(c) () -> UnsafeRawPointer?
        guard let object = unsafeBitCast(main, to: Getter.self)() else { return nil }
        let group = Unmanaged<AnyObject>.fromOpaque(object).takeRetainedValue()
        // A method takes `self` in the context register: the same shape as a closure whose
        // context is the object.
        struct Method { var function: UnsafeRawPointer; var context: AnyObject }
        return UpdateLock(begin: unsafeBitCast(Method(function: UnsafeRawPointer(begin), context: group), to: (() -> Void).self),
                          end: unsafeBitCast(Method(function: UnsafeRawPointer(end), context: group), to: (() -> Void).self))
    }()
}

import AppKit
import Foundation

/// Records every `Unable to simultaneously satisfy constraints` AppKit reports.
///
/// AppKit calls `-[NSView engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:]` — the
/// selector UIKit has — on the view that owns the engine right before it breaks one; the agent
/// wraps it, records, and calls the original. Installed at load, before the app's first window.
enum ConstraintMonitor {
    nonisolated(unsafe) private static var breaks: [ConstraintBreak] = []
    private static let lock = NSLock()
    private static let limit = 100

    static var recorded: [ConstraintBreak] {
        lock.lock(); defer { lock.unlock() }
        return breaks
    }

    static func install() {
        let selector = NSSelectorFromString("engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:")
        guard let method = class_getInstanceMethod(NSView.self, selector) else {
            return APVTAgent.log("NSView lacks \(NSStringFromSelector(selector)); constraint breaks are not recorded")
        }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSLayoutConstraint, NSArray) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject, NSLayoutConstraint, NSArray) -> Void = { view, engine, constraint, constraints in
            // Auto Layout runs on the main thread; recording reads AppKit properties.
            nonisolated(unsafe) let (broken, all) = (constraint, constraints)
            if Thread.isMainThread { MainActor.assumeIsolated { record(broken, all) } }
            original(view, selector, engine, constraint, constraints)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    @MainActor
    private static func record(_ broken: NSLayoutConstraint, _ all: NSArray) {
        let list = all.compactMap { $0 as? NSLayoutConstraint }
        var views: [String] = []
        var allSystem = true
        for c in list + [broken] {
            for item in [c.firstItem, c.secondItem] {
                guard let item else { continue }
                let view = (item as? NSView) ?? (item as? NSLayoutGuide)?.owningView
                if let view, !isSystem(view) { allSystem = false }
                guard let d = describe(item), !views.contains(d) else { continue }
                views.append(d)
            }
        }
        let entry = ConstraintBreak(broken: broken.description, conflicting: list.map(\.description), views: views, system: allSystem)
        lock.lock()
        if breaks.count < limit { breaks.append(entry) }
        lock.unlock()
    }

    private static let systemPrefixes = ["NSTitlebar", "_NSTitlebar", "NSToolbar", "_NSToolbar", "_NSAlert", "NSAlert",
                                         "NSTouchBar", "NSMenu", "_NSMenu", "NSPopover", "_NSPopover", "NSSavePanel", "NSOpenPanel",
                                         "NSRemoteView", "NSTabBar", "NSScrubber", "NSColorPanel", "NSFontPanel"]

    /// AppKit's own view: the title bar's, an alert's or a panel's insides, at any depth.
    @MainActor
    private static func isSystem(_ view: NSView) -> Bool {
        if let window = view.window {
            let name = NSStringFromClass(type(of: window))
            if name.contains("Alert") || name.contains("SavePanel") || name.contains("OpenPanel") || name.contains("Menu") { return true }
        }
        // The frame view around the content is AppKit's; what it contains is the app's.
        if NSStringFromClass(type(of: view)).hasPrefix("NSThemeFrame") { return true }
        var current: NSView? = view
        while let v = current {
            let name = NSStringFromClass(type(of: v))
            if systemPrefixes.contains(where: name.hasPrefix) { return true }
            current = v.superview
        }
        return false
    }

    @MainActor
    private static func describe(_ item: AnyObject?) -> String? {
        guard let item else { return nil }
        if let view = item as? NSView {
            let name = String(describing: type(of: view))
            let id = view.accessibilityIdentifier()
            if !id.isEmpty, !id.hasPrefix("_NS:") { return "\(name)#\(id)" }
            if let button = view as? NSButton, !button.title.isEmpty { return "\(name)\"\(button.title.prefix(30))\"" }
            if let field = view as? NSTextField, !field.stringValue.isEmpty { return "\(name)\"\(field.stringValue.prefix(30))\"" }
            return name
        }
        if let guide = item as? NSLayoutGuide {
            let owner = guide.owningView.map { String(describing: type(of: $0)) } ?? "?"
            let name = guide.identifier.rawValue
            return "\(name.isEmpty ? "NSLayoutGuide" : name) of \(owner)"
        }
        return String(describing: type(of: item))
    }
}

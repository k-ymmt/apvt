import Foundation
import UIKit

/// Records every `Unable to simultaneously satisfy constraints` UIKit reports.
///
/// UIKit calls `-[UIView engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:]` on the
/// view that owns the engine right before it breaks one; the agent wraps it, records, and calls
/// the original. Installed at load, before the app builds its first screen.
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
        guard let method = class_getInstanceMethod(UIView.self, selector) else {
            return APVTAgent.log("UIView lacks \(NSStringFromSelector(selector)); constraint breaks are not recorded")
        }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSLayoutConstraint, NSArray) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject, NSLayoutConstraint, NSArray) -> Void = { view, engine, constraint, constraints in
            // Auto Layout runs on the main thread; recording reads UIKit properties.
            nonisolated(unsafe) let all = constraints
            MainActor.assumeIsolated { record(constraint, all) }
            original(view, selector, engine, constraint, constraints)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    @MainActor
    private static func record(_ broken: NSLayoutConstraint, _ all: NSArray) {
        let list = all.compactMap { $0 as? NSLayoutConstraint }
        var views: [String] = []
        for c in list + [broken] {
            for item in [c.firstItem, c.secondItem] {
                guard let d = describe(item), !views.contains(d) else { continue }
                views.append(d)
            }
        }
        let entry = ConstraintBreak(broken: broken.description, conflicting: list.map(\.description), views: views)
        lock.lock()
        if breaks.count < limit { breaks.append(entry) }
        lock.unlock()
    }

    @MainActor
    private static func describe(_ item: AnyObject?) -> String? {
        guard let item else { return nil }
        if let view = item as? UIView {
            let name = String(describing: type(of: view))
            if let id = view.accessibilityIdentifier, !id.isEmpty { return "\(name)#\(id)" }
            if let label = view as? UILabel, let text = label.text { return "\(name)\"\(text.prefix(30))\"" }
            if let button = view as? UIButton, let title = button.currentTitle { return "\(name)\"\(title.prefix(30))\"" }
            return name
        }
        if let guide = item as? UILayoutGuide {
            let owner = guide.owningView.map { String(describing: type(of: $0)) } ?? "?"
            return "\(guide.identifier.isEmpty ? "UILayoutGuide" : guide.identifier) of \(owner)"
        }
        return String(describing: type(of: item))
    }
}

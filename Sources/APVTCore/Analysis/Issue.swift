import APVTModel
import Foundation

public enum Severity: String, Codable, Sendable, Comparable {
    case error, warning

    public static func < (a: Severity, b: Severity) -> Bool {
        a == .warning && b == .error
    }
}

/// What apvt checks. The raw value is what output and `--rule` use.
public enum Rule: String, Codable, Sendable, CaseIterable {
    case offscreen
    case widerThanScreen = "wider-than-screen"
    case clipped
    case truncated
    case squeezed
    case overlap
    case unsafeArea = "unsafe-area"
    case smallTarget = "small-target"
    case ambiguousLayout = "ambiguous-layout"
    case brokenConstraint = "broken-constraint"

    public var summary: String {
        switch self {
        case .offscreen: "content is cut off by, or lies beyond, the screen edge"
        case .widerThanScreen: "a container is wider than the screen, pushing its content off-screen"
        case .clipped: "content is hidden by an ancestor that clips (clipsToBounds / .clipped())"
        case .truncated: "text needs more room than it has, so it is truncated (…) or cut"
        case .squeezed: "text or a control is narrower than its content: words break mid-word or vanish"
        case .overlap: "two texts or controls are drawn on top of each other (an error when text crosses a control's edge)"
        case .unsafeArea: "text or a control sits under the status bar / Dynamic Island / home indicator"
        case .smallTarget: "a control is smaller than 24x24pt (WCAG 2.5.8), hard to tap"
        case .ambiguousLayout: "Auto Layout cannot decide the view's frame (UIKit hasAmbiguousLayout)"
        case .brokenConstraint: "UIKit broke a constraint because the constraints conflict"
        }
    }

    /// How to fix it, for both UI frameworks.
    public var hint: String {
        switch self {
        case .offscreen:
            "Find the container that grew wider than the screen (see wider-than-screen) or the fixed size/offset that moved it. SwiftUI: remove .fixedSize() / fixed .frame(width:) on long content, let Text wrap, or use ViewThatFits / a ScrollView. UIKit: pin leading AND trailing to the superview (or safe area) instead of a fixed width."
        case .widerThanScreen:
            "The listed suspects are fixed-size children. SwiftUI: drop .fixedSize(), replace .frame(width: N) with .frame(maxWidth: .infinity), add .lineLimit/.minimumScaleFactor, or wrap in ScrollView(.horizontal). UIKit: replace width constants with leading/trailing constraints or lower their priority."
        case .clipped:
            "Grow the clipping container (or drop its fixed height) so its content fits, or remove clipping. SwiftUI: remove .frame(height:) + .clipped() on text; UIKit: give the container a height that follows its content (constraints to the content's bottom) instead of a constant."
        case .truncated:
            "Give the text room: SwiftUI — remove fixed .frame(width:/height:), .lineLimit(1) or let it wrap with .fixedSize(horizontal: false, vertical: true); UIKit — numberOfLines = 0 and pin leading/trailing instead of a fixed width/height. If one line is intended, shorten the text or add minimumScaleFactor."
        case .squeezed:
            "A sibling took the space. SwiftUI: give the squeezed view .layoutPriority(1) or .fixedSize(), and let the long sibling truncate (.lineLimit(1)) or wrap; UIKit: raise its contentCompressionResistancePriority."
        case .overlap:
            "Two views share space. SwiftUI: an .offset() or ZStack moved one onto another — position it with .overlay(alignment:) on the right view, or use padding/alignment instead of offset. UIKit: constrain one below/beside the other instead of to the same anchors."
        case .unsafeArea:
            "Keep text and controls inside the safe area: SwiftUI — apply .ignoresSafeArea() only to the background (e.g. .background(Color.x.ignoresSafeArea())), not the content; UIKit — constrain to view.safeAreaLayoutGuide."
        case .smallTarget:
            "Make the tappable area at least 44x44pt (HIG; 24pt is the WCAG minimum): SwiftUI — .frame(minWidth: 44, minHeight: 44) and .contentShape(Rectangle()); UIKit — larger bounds or override point(inside:with:)."
        case .ambiguousLayout:
            "Add the missing constraints so x, y, width and height are each determined (e.g. a width or trailing constraint, or a height for a view without intrinsic size)."
        case .brokenConstraint:
            "Two or more constraints ask for different things (the list shows them). Remove one, or lower one's priority below 1000."
        }
    }
}

public struct Issue: Codable, Sendable {
    public var rule: Rule
    public var severity: Severity
    /// The node it is about.
    public var ref: Int?
    /// Other nodes involved (the other side of an overlap, the clipping ancestor, suspects).
    public var related: [Int]
    public var message: String
    public var frame: Rect?

    public init(rule: Rule, severity: Severity, ref: Int?, related: [Int] = [], message: String, frame: Rect?) {
        self.rule = rule
        self.severity = severity
        self.ref = ref
        self.related = related
        self.message = message
        self.frame = frame
    }
}

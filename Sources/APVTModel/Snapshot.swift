import Foundation

/// Everything the in-app agent reports about one moment of the UI.
///
/// The agent collects; it never judges. Roles, traits and text metrics are facts read from
/// the platform. Issues, selectors and assertions are the host's (`APVTCore`).
public struct Snapshot: Codable, Sendable {
    public static let currentFormat = "apvt-snapshot/1"

    public var format: String
    /// `ios-simulator` today; the model itself carries nothing iOS-specific.
    public var platform: String
    public var app: AppInfo
    public var device: DeviceInfo?
    public var screen: ScreenInfo
    public var windows: [Node]
    /// Auto Layout constraints UIKit broke because they could not all be satisfied.
    public var constraintBreaks: [ConstraintBreak]
    /// Things the reader should know about how complete this snapshot is.
    public var notes: [String]

    public init(platform: String, app: AppInfo, device: DeviceInfo? = nil, screen: ScreenInfo,
                windows: [Node], constraintBreaks: [ConstraintBreak] = [], notes: [String] = []) {
        self.format = Snapshot.currentFormat
        self.platform = platform
        self.app = app
        self.device = device
        self.screen = screen
        self.windows = windows
        self.constraintBreaks = constraintBreaks
        self.notes = notes
    }
}

public struct AppInfo: Codable, Sendable {
    public var bundleId: String
    public var name: String
    public var pid: Int32
    public var osVersion: String

    public init(bundleId: String, name: String, pid: Int32, osVersion: String) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
        self.osVersion = osVersion
    }
}

public struct DeviceInfo: Codable, Sendable {
    public var name: String
    public var udid: String
    public var runtime: String

    public init(name: String, udid: String, runtime: String) {
        self.name = name
        self.udid = udid
        self.runtime = runtime
    }
}

public struct ScreenInfo: Codable, Sendable {
    public var width: Double
    public var height: Double
    public var scale: Double
    /// The key window's safe area insets (status bar / Dynamic Island, home indicator).
    public var safeArea: EdgeInsets

    public init(width: Double, height: Double, scale: Double, safeArea: EdgeInsets) {
        self.width = width
        self.height = height
        self.scale = scale
        self.safeArea = safeArea
    }

    public var bounds: Rect { Rect(x: 0, y: 0, width: width, height: height) }
    public var safeBounds: Rect { bounds.insetBy(safeArea) }
}

public enum NodeSource: String, Codable, Sendable {
    case uikit
    case swiftui
}

public enum Role: String, Codable, Sendable {
    case window, container, text, image, control, shape, spacer, scroll, hosting, other
}

/// One view: a UIView, or a SwiftUI view that has a layout frame.
public struct Node: Codable, Sendable {
    /// `@N` in output; assigned by the host in pre-order, so the same UI numbers the same way.
    public var ref: Int?
    public var source: NodeSource
    /// Short type: `UILabel`, `Text`, `HStack`, `Button`, `.frame`, `Circle`.
    public var type: String
    /// The runtime class (UIKit) or the full SwiftUI type, for when `type` is not enough.
    public var detail: String?
    public var role: Role
    /// Screen points. For SwiftUI this is the layout frame; `.offset` moves descendants only.
    public var frame: Rect
    /// accessibilityIdentifier.
    public var identifier: String?
    /// accessibilityLabel, when it differs from the text.
    public var label: String?
    public var text: TextInfo?
    /// SwiftUI modifiers between this node and the next node with a frame (`clipped`, `offset`, …).
    public var modifiers: [String]?
    /// `hidden`, `clips`, `system`, `internal`, `ambiguousLayout`, `disabled`, `interactive`, …
    public var traits: [String]?
    public var alpha: Double?
    public var scroll: ScrollInfo?
    /// SwiftUI only: the coordinate space `frame` was recorded in, when it is a ScrollView's
    /// content (nil = the hosting view). The agent resolves it; snapshots carry screen points.
    public var space: Int?
    /// SwiftUI only: the coordinate space of this ScrollView's content.
    public var contentSpace: Int?
    public var children: [Node]

    public init(source: NodeSource, type: String, detail: String? = nil, role: Role, frame: Rect,
                identifier: String? = nil, label: String? = nil, text: TextInfo? = nil,
                modifiers: [String]? = nil, traits: [String]? = nil, alpha: Double? = nil,
                scroll: ScrollInfo? = nil, children: [Node] = []) {
        self.source = source
        self.type = type
        self.detail = detail
        self.role = role
        self.frame = frame
        self.identifier = identifier
        self.label = label
        self.text = text
        self.modifiers = modifiers
        self.traits = traits
        self.alpha = alpha
        self.scroll = scroll
        self.children = children
    }

    public func has(_ trait: String) -> Bool { traits?.contains(trait) ?? false }
    /// `frame` matches `frame` and `frame(width: 150)`.
    public func hasModifier(_ modifier: String) -> Bool {
        modifiers?.contains { $0 == modifier || $0.hasPrefix(modifier + "(") } ?? false
    }

    public mutating func addTrait(_ trait: String) {
        if !has(trait) { traits = (traits ?? []) + [trait] }
    }
}

/// A string as it is laid out, and what it would need to be shown in full.
public struct TextInfo: Codable, Sendable {
    public var string: String
    public var fontName: String?
    public var fontSize: Double?
    public var bold: Bool?
    /// SwiftUI / UIKit text style (`body`, `headline`, …) when the font was declared as one.
    public var textStyle: String?
    /// The font was not declared in what the platform reports and was guessed (`body`).
    public var fontGuessed: Bool?
    /// UILabel.numberOfLines (0 = unlimited). Unknown for SwiftUI.
    public var maxLines: Int?
    /// Width the string needs on one line.
    public var singleLineWidth: Double?
    public var lineHeight: Double?
    /// Height the string needs at the frame's width with no line limit.
    public var requiredHeight: Double?
    /// Width of the longest word: narrower than this and words break mid-word.
    public var longestWordWidth: Double?
    /// A text field's placeholder; `string` is its text.
    public var placeholder: String?

    public init(string: String) {
        self.string = string
    }
}

public struct ScrollInfo: Codable, Sendable {
    public var contentWidth: Double
    public var contentHeight: Double
    public var offsetX: Double
    public var offsetY: Double
    public var enabled: Bool

    public init(contentWidth: Double, contentHeight: Double, offsetX: Double, offsetY: Double, enabled: Bool) {
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.enabled = enabled
    }
}

/// One `Unable to simultaneously satisfy constraints` event.
public struct ConstraintBreak: Codable, Sendable {
    /// The constraint UIKit chose to break.
    public var broken: String
    /// All constraints in the conflict, as `NSLayoutConstraint.description`.
    public var conflicting: [String]
    /// The views involved: class and identifier, e.g. `UIButton#uikit-manage`.
    public var views: [String]
    /// Every view involved belongs to UIKit itself (an alert's insides, the keyboard).
    public var system: Bool?

    public init(broken: String, conflicting: [String], views: [String], system: Bool? = nil) {
        self.broken = broken
        self.conflicting = conflicting
        self.views = views
        self.system = system
    }
}

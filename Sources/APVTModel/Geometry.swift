import Foundation

/// A rectangle in points, in the screen's coordinate space (origin top-left).
public struct Rect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ other: Rect) -> Rect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func contains(_ other: Rect, tolerance: Double = 0) -> Bool {
        other.minX >= minX - tolerance && other.minY >= minY - tolerance
            && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }

    public func insetBy(_ insets: EdgeInsets) -> Rect {
        Rect(x: x + insets.left, y: y + insets.top,
             width: width - insets.left - insets.right, height: height - insets.top - insets.bottom)
    }

    /// Rounded to 0.1pt, which is what output shows and what fixtures compare.
    public var rounded: Rect {
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return Rect(x: r(x), y: r(y), width: r(width), height: r(height))
    }
}

public struct EdgeInsets: Codable, Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}

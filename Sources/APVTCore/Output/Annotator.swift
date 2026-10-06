import APVTModel
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws issues (and optionally every visible element) onto a screenshot, labelled `@N`, so a
/// model that reads images can connect what it sees with `apvt tree` / `apvt query`.
public enum Annotator {
    public enum Outline: String, Sendable {
        /// Only the nodes issues are about (and the nodes they involve).
        case issues
        /// Also every visible text, image, control and shape of the app.
        case all
    }

    public static func annotate(screenshot: URL, output: URL, snapshot s: IndexedSnapshot, issues: [Issue],
                                outline: Outline) throws {
        guard let source = CGImageSourceCreateWithURL(screenshot as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw APVTError(.io, "could not read the screenshot \(screenshot.path)")
        }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw APVTError(.io, "could not create a drawing context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = Double(width) / max(s.snapshot.screen.width, 1)
        // Points (origin top-left) → pixels (CoreGraphics origin bottom-left).
        func pixels(_ r: Rect) -> CGRect {
            CGRect(x: r.x * scale, y: Double(height) - (r.y + r.height) * scale, width: r.width * scale, height: r.height * scale)
        }

        if outline == .all {
            let analyzer = Analyzer()
            for e in s.entries where analyzer.isContent(e) && !e.frame.isEmpty {
                stroke(context, pixels(e.frame), color: CGColor(srgbRed: 0.1, green: 0.5, blue: 1, alpha: 0.7), width: max(1, scale / 2))
                label(context, "@\(e.ref)", at: pixels(e.frame), color: CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 0.85), scale: scale * 0.8)
            }
        }
        var labelled = Set<Int>()
        for issue in issues.reversed() {
            guard let frame = issue.frame else { continue }
            let color = issue.severity == .error
                ? CGColor(srgbRed: 0.95, green: 0.1, blue: 0.1, alpha: 0.95)
                : CGColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 0.95)
            let rect = pixels(frame.isEmpty ? Rect(x: frame.x - 1, y: frame.y - 1, width: max(frame.width, 2), height: max(frame.height, 2)) : frame)
            stroke(context, rect, color: color, width: max(2, scale))
            for related in issue.related {
                if let e = s.entry(related) {
                    stroke(context, pixels(e.frame), color: color.copy(alpha: 0.5)!, width: max(1, scale / 2), dashed: true)
                }
            }
            let key = issue.ref ?? -1
            let text = "@\(issue.ref.map(String.init) ?? "-") \(issue.rule.rawValue)"
            label(context, text, at: rect, color: color, scale: scale, offset: labelled.contains(key) ? 1 : 0)
            labelled.insert(key)
        }

        guard let result = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw APVTError(.io, "could not write \(output.path)")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw APVTError(.io, "could not write \(output.path)") }
    }

    private static func stroke(_ context: CGContext, _ rect: CGRect, color: CGColor, width: Double, dashed: Bool = false) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(width)
        if dashed { context.setLineDash(phase: 0, lengths: [width * 4, width * 3]) }
        context.stroke(rect.insetBy(dx: -width / 2, dy: -width / 2))
        context.restoreGState()
    }

    /// A filled tag above the rectangle's top-left corner (inside it when there is no room).
    private static func label(_ context: CGContext, _ text: String, at rect: CGRect, color: CGColor, scale: Double, offset: Int = 0) {
        let fontSize = 10 * scale
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        let pad = 2 * scale
        let w = bounds.width + pad * 2, h = fontSize + pad
        var y = rect.maxY + Double(offset) * h
        if y + h > Double(context.height) { y = rect.maxY - h - Double(offset) * h }
        let x = min(max(rect.minX, 0), Double(context.width) - w)
        context.saveGState()
        context.setFillColor(color)
        context.fill(CGRect(x: x, y: y, width: w, height: h))
        context.textPosition = CGPoint(x: x + pad, y: y + pad * 0.9)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

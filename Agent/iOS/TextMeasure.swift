import Foundation
import UIKit

/// What a string needs to be shown in full, measured with the font it is drawn in (UIKit) or
/// the font SwiftUI's debug data names — completed from the frame's height when it does not.
@MainActor
enum TextMeasure {
    private static let styles: [(String, UIFont.TextStyle)] = [
        ("largeTitle", .largeTitle), ("title", .title1), ("title2", .title2), ("title3", .title3),
        ("headline", .headline), ("body", .body), ("callout", .callout), ("subheadline", .subheadline),
        ("footnote", .footnote), ("caption", .caption1), ("caption2", .caption2),
    ]

    static func fill(_ info: inout TextInfo, font: UIFont, width: Double) {
        let string = info.string
        guard !string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let ns = string as NSString
        info.fontName = font.fontName
        info.fontSize = Double(font.pointSize)
        info.lineHeight = Double(font.lineHeight)
        info.singleLineWidth = Double(ceil(ns.size(withAttributes: attributes).width))
        let bounding = ns.boundingRect(
            with: CGSize(width: max(width, 0.01), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        info.requiredHeight = Double(ceil(bounding.height))
        let words = string.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        info.longestWordWidth = words.map { Double(ceil(($0 as NSString).size(withAttributes: attributes).width)) }.max()
    }

    /// The font a SwiftUI `Text` is drawn in, as far as the debug data and its frame tell.
    static func swiftUIFont(for info: TextInfo, frameHeight: Double) -> (UIFont, guessed: Bool) {
        let bold = info.bold ?? false
        if let style = info.textStyle, let ui = styles.first(where: { $0.0 == style })?.1 {
            return (apply(bold: bold, to: UIFont.preferredFont(forTextStyle: ui)), false)
        }
        if let size = info.fontSize {
            return (UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), false)
        }
        // No declared font: pick the text style whose line height best divides the frame.
        var best: (UIFont, Double)?
        for (_, style) in styles {
            let font = apply(bold: bold, to: UIFont.preferredFont(forTextStyle: style))
            let lines = max(1, (frameHeight / font.lineHeight).rounded())
            let error = abs(frameHeight - lines * font.lineHeight) / lines
            if best == nil || error < best!.1 { best = (font, error) }
        }
        let body = apply(bold: bold, to: UIFont.preferredFont(forTextStyle: .body))
        // Body is SwiftUI's default; keep it unless another style fits clearly better.
        let bodyLines = max(1, (frameHeight / body.lineHeight).rounded())
        let bodyError = abs(frameHeight - bodyLines * body.lineHeight) / bodyLines
        if let best, best.1 + 0.5 < bodyError { return (best.0, true) }
        return (body, true)
    }

    private static func apply(bold: Bool, to font: UIFont) -> UIFont {
        guard bold, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

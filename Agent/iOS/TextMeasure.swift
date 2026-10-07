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
        // The longest piece a line cannot break inside: words as the system splits them, so
        // "Montgomery-Williamson" is two (it wraps at the hyphen) and CJK text is not one.
        var widest = 0.0
        var widestWord: String?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .localized]) { word, _, _, _ in
            guard let word else { return }
            let width = Double(ceil((word as NSString).size(withAttributes: attributes).width))
            if width > widest { widest = width; widestWord = word }
        }
        info.longestWordWidth = widest
        info.longestWord = widestWord
    }

    /// The font a SwiftUI `Text` is drawn in, as far as the debug data and its frame tell.
    ///
    /// Without a declared font (a style set by a List section, a button style, …) the guess is
    /// the text style under which the string, wrapped at the frame's width, is as tall as the
    /// frame: the font that explains the layout SwiftUI made. Body wins ties (SwiftUI's default).
    static func swiftUIFont(for info: TextInfo, frame: Rect) -> (UIFont, guessed: Bool) {
        let bold = info.bold ?? false
        if let style = info.textStyle, let ui = styles.first(where: { $0.0 == style })?.1 {
            return (apply(bold: bold, to: UIFont.preferredFont(forTextStyle: ui)), false)
        }
        if let size = info.fontSize {
            return (UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), false)
        }
        let ns = info.string as NSString
        let width = max(frame.width, 0.01)
        func error(_ font: UIFont) -> Double {
            let height = ns.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: font], context: nil).height
            return abs(Double(ceil(height)) - frame.height)
        }
        let body = apply(bold: bold, to: UIFont.preferredFont(forTextStyle: .body))
        var best = (font: body, error: error(body))
        for (_, style) in styles {
            let font = apply(bold: bold, to: UIFont.preferredFont(forTextStyle: style))
            let e = error(font)
            if e + 0.5 < best.error { best = (font, e) }
        }
        return (best.font, true)
    }

    private static func apply(bold: Bool, to font: UIFont) -> UIFont {
        guard bold, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

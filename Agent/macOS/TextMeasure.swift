import AppKit
import Foundation

/// What a string needs to be shown in full, measured with the font it is drawn in (AppKit) or
/// the font SwiftUI's debug data names — completed from the frame's height when it does not.
@MainActor
enum TextMeasure {
    private static let styles: [(String, NSFont.TextStyle)] = [
        ("largeTitle", .largeTitle), ("title", .title1), ("title2", .title2), ("title3", .title3),
        ("headline", .headline), ("body", .body), ("callout", .callout), ("subheadline", .subheadline),
        ("footnote", .footnote), ("caption", .caption1), ("caption2", .caption2),
    ]
    private static let layoutManager = NSLayoutManager()

    static func lineHeight(_ font: NSFont) -> Double {
        Double(layoutManager.defaultLineHeight(for: font))
    }

    static func fill(_ info: inout TextInfo, font: NSFont, width: Double) {
        let string = info.string
        guard !string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let ns = string as NSString
        info.fontName = font.fontName
        info.fontSize = Double(font.pointSize)
        info.lineHeight = lineHeight(font)
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
    static func swiftUIFont(for info: TextInfo, frame: Rect) -> (NSFont, guessed: Bool) {
        // The font SwiftUI resolved, when its debug data names it: no guessing.
        if let name = info.fontName, let size = info.fontSize {
            if name.hasPrefix(".") { return (NSFont.systemFont(ofSize: size, weight: weight(of: name)), false) }
            if let font = NSFont(name: name, size: size) { return (font, false) }
        }
        let bold = info.bold ?? false
        if let style = info.textStyle, let ns = styles.first(where: { $0.0 == style })?.1 {
            return (apply(bold: bold, to: NSFont.preferredFont(forTextStyle: ns)), false)
        }
        if let size = info.fontSize {
            return (NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), false)
        }
        let ns = info.string as NSString
        let width = max(frame.width, 0.01)
        func error(_ font: NSFont) -> Double {
            let height = ns.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: font], context: nil).height
            return abs(Double(ceil(height)) - frame.height)
        }
        let body = apply(bold: bold, to: NSFont.preferredFont(forTextStyle: .body))
        var best = (font: body, error: error(body))
        for (_, style) in styles {
            let font = apply(bold: bold, to: NSFont.preferredFont(forTextStyle: style))
            let e = error(font)
            if e + 0.5 < best.error { best = (font, e) }
        }
        return (best.font, true)
    }

    /// `.SFNS-Semibold` → semibold: the system font is asked for by weight, not by its private name.
    private static func weight(of name: String) -> NSFont.Weight {
        let weights: [(String, NSFont.Weight)] = [("Ultralight", .ultraLight), ("Thin", .thin), ("Light", .light), ("Regular", .regular),
                                                  ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black)]
        return weights.first { name.hasSuffix("-" + $0.0) }?.1 ?? .regular
    }

    static func body() -> NSFont { NSFont.preferredFont(forTextStyle: .body) }

    private static func apply(bold: Bool, to font: NSFont) -> NSFont {
        guard bold else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}

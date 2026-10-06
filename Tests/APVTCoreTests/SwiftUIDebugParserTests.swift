@testable import APVTModel
import Foundation
import Testing

@Suite("SwiftUI debug data")
struct SwiftUIDebugParserTests {
    func nodes() throws -> [Node] {
        try SwiftUIDebugParser.parse(Data(contentsOf: Fixture.url("swiftui-profile-navigation")))
    }

    func all(_ nodes: [Node]) -> [Node] {
        nodes.flatMap { [$0] + all($0.children) }
    }

    @Test func framesAndTypesOfTheProfileCard() throws {
        let flat = all(try nodes())
        let name = try #require(flat.first { $0.text?.string == "Alexandra Montgomery-Williamson" })
        #expect(name.type == "Text")
        #expect(name.frame.rounded == Rect(x: 77.3, y: 199.8, width: 279.3, height: 20.3))
        #expect(flat.contains { $0.type == ".fixedSize" && $0.children.first?.text?.string == name.text?.string })
        #expect(flat.contains { $0.type == "Circle" && $0.frame.width == 56 })
    }

    @Test func aButtonIsAControlAndKeepsItsCollapsedLabel() throws {
        let flat = all(try nodes())
        let button = try #require(flat.first { $0.type == "Button" })
        #expect(button.role == .control)
        #expect(button.hasModifier("padding"))
        let label = try #require(all(button.children).first { $0.text?.string == "Follow" })
        #expect(label.has("textNotLaidOut"))
        #expect(label.frame.width == 0)
    }

    @Test func childrenAreInDeclarationOrder() throws {
        let flat = all(try nodes())
        let stack = try #require(flat.first { $0.type == "VStack" && $0.children.count == 3 })
        #expect(stack.children.map(\.type) == [".background", "Text", "Spacer"])
    }

    @Test func zeroIsANumberNotABool() {
        #expect(SwiftUIDebugParser.number(NSNumber(value: 0)) == 0)
        #expect(SwiftUIDebugParser.number(NSNumber(value: 1.5)) == 1.5)
        #expect(SwiftUIDebugParser.number(kCFBooleanTrue as Any) == nil)
    }

    @Test func formatsInterpolatedKeys() {
        #expect(SwiftUIDebugParser.format("Post number %lld with a title", arguments: ["25"]) == "Post number 25 with a title")
        #expect(SwiftUIDebugParser.format("%2$@ and %1$@", arguments: ["a", "b"]) == "b and a")
        #expect(SwiftUIDebugParser.format("100%% of %@", arguments: ["x"]) == "100% of x")
        #expect(SwiftUIDebugParser.format("no args", arguments: []) == "no args")
    }

    @Test func modifierNamesAreTheOnesDevelopersWrite() {
        #expect(SwiftUIDebugParser.modifierName("_ClipEffect<Rectangle>") == "clipped")
        #expect(SwiftUIDebugParser.modifierName("_OffsetEffect") == "offset")
        #expect(SwiftUIDebugParser.modifierName("_EnvironmentKeyWritingModifier<Optional<Font>>") == "font")
        #expect(SwiftUIDebugParser.modifierName("AccessibilityAttachmentModifier") == nil)
    }

    @Test func splitsGenericTypes() {
        let (base, args) = SwiftUIDebugParser.splitGeneric("_ShapeView<Circle, Color>")
        #expect(base == "_ShapeView")
        #expect(args == ["Circle", "Color"])
        #expect(SwiftUIDebugParser.splitGeneric("A<B<C, D>, E>").arguments == ["B<C, D>", "E"])
    }
}

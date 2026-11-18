@testable import APVTCore
@testable import APVTModel
import Foundation
import Testing

@Suite("macOS platform pieces")
struct MacOSTests {
    // MARK: - Code signature

    static func entitlements(_ keys: [String]) -> Data {
        let body = keys.map { "<key>\($0)</key><true/>" }.joined()
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>\(body)</dict></plist>".utf8)
    }

    /// An Xcode Debug build signed "to run locally": no Hardened Runtime, so any agent loads.
    @Test func anAdHocBuildWithoutTheHardenedRuntimeLoadsAnAdHocAgent() throws {
        let details = """
        Executable=/tmp/MyApp.app/Contents/MacOS/MyApp
        CodeDirectory v=20400 size=1024 flags=0x2(adhoc) hashes=20+7 location=embedded
        Signature=adhoc
        TeamIdentifier=not set
        """
        let signature = CodeSignature.parse(details: details, entitlements: Self.entitlements(["com.apple.security.app-sandbox", "com.apple.security.get-task-allow"]))
        #expect(signature.adhoc && !signature.hardenedRuntime && signature.teamIdentifier == nil)
        #expect(signature.sandboxed && signature.getTaskAllow)
        #expect(try signature.agentSignature(app: "MyApp.app") == .adhoc)
    }

    /// A development-signed Debug build with the Hardened Runtime: the agent needs the team's signature.
    @Test func aHardenedDebugBuildWantsTheAgentSignedByItsTeam() throws {
        let details = """
        CodeDirectory v=20500 size=1024 flags=0x10000(runtime) hashes=20+7 location=embedded
        Authority=Apple Development: Jane Appleseed (AAAAAAAAAA)
        Authority=Apple Worldwide Developer Relations Certification Authority
        TeamIdentifier=ABCDE12345
        """
        let signature = CodeSignature.parse(details: details, entitlements: Self.entitlements(["com.apple.security.get-task-allow"]))
        #expect(signature.hardenedRuntime && signature.authority == "Apple Development: Jane Appleseed (AAAAAAAAAA)")
        #expect(try signature.agentSignature(app: "MyApp.app") == .team("ABCDE12345"))

        var relaxed = signature
        relaxed.disableLibraryValidation = true
        #expect(try relaxed.agentSignature(app: "MyApp.app") == .adhoc)
    }

    /// A release build: dyld ignores the variable, so apvt says so instead of launching.
    @Test func aHardenedBuildWithoutGetTaskAllowIsRefusedWithAFix() {
        let details = "CodeDirectory v=20500 size=1024 flags=0x10000(runtime) hashes=20+7 location=embedded\nTeamIdentifier=ABCDE12345\n"
        let signature = CodeSignature.parse(details: details, entitlements: nil)
        let error = #expect(throws: APVTError.self) { try signature.agentSignature(app: "MyApp.app") }
        #expect(error?.description.contains("without get-task-allow") == true)
        #expect(error?.description.contains("fix: build the app's Debug configuration") == true)

        // Hardened, debuggable, but signed ad hoc: no team a library could share.
        let adhoc = CodeSignature.parse(details: "CodeDirectory v=20500 flags=0x10002(adhoc,runtime) hashes=1\nSignature=adhoc\nTeamIdentifier=not set\n",
                                        entitlements: Self.entitlements(["com.apple.security.get-task-allow"]))
        #expect(throws: APVTError.self) { try adhoc.agentSignature(app: "MyApp.app") }
    }

    @Test func signingIdentitiesAreReadFromSecurityFindIdentity() {
        let output = """
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Jane Appleseed (AAAAAAAAAA)"
          2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Developer ID Application: Example, Inc. (ABCDE12345)"
          2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Developer ID Application: Example, Inc. (ABCDE12345)"
             2 valid identities found
        """
        let identities = SigningIdentity.parse(output)
        #expect(identities.map(\.name) == ["Apple Development: Jane Appleseed (AAAAAAAAAA)", "Developer ID Application: Example, Inc. (ABCDE12345)"])
        #expect(identities.first?.hash == "0123456789ABCDEF0123456789ABCDEF01234567")
    }

    // MARK: - App bundles

    func bundle(_ info: [String: Any], flat: Bool = false) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "apvt-test-\(UUID().uuidString)/My App.app")
        let folder = flat ? app : app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appending(path: "Info.plist"))
        return app
    }

    /// `apvt launch <App.app>` picks the platform from the bundle, not from a flag.
    @Test func theBundleSaysWhichPlatformItIsFor() throws {
        let base: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "MyApp", "CFBundleName": "My App"]
        let mac = try AppBundle(path: bundle(base.merging(["CFBundleSupportedPlatforms": ["MacOSX"]]) { $1 }).path)
        #expect(mac.platform == .macOS && mac.bundleId == "com.example.app")
        #expect(mac.executable.path.hasSuffix("My App.app/Contents/MacOS/MyApp"))
        #expect((try Session.platform(forApp: mac.url.path, named: nil)).id == Snapshot.macOS)

        let simulator = try AppBundle(path: bundle(base.merging(["CFBundleSupportedPlatforms": ["iPhoneSimulator"]]) { $1 }, flat: true).path)
        #expect(simulator.platform == .iOSSimulator)
        #expect((try Session.platform(forApp: simulator.url.path, named: nil)).id == Snapshot.iOSSimulator)

        let catalyst = try AppBundle(path: bundle(base.merging(["CFBundleSupportedPlatforms": ["MacOSX"], "UIDeviceFamily": [2]]) { $1 }).path)
        #expect(catalyst.platform == .macCatalyst)
        #expect(catalyst.platformDescription.contains("Catalyst"))

        // A bundle id may end in ".app": it is a path only when it names something on disk.
        #expect(AppBundle.looksLikePath("build/MyApp.app") && AppBundle.looksLikePath(mac.url.path))
        #expect(!AppBundle.looksLikePath("com.example.app") && !AppBundle.looksLikePath("dev.apvt.sample"))
        #expect(throws: APVTError.self) { try AppBundle(path: "/no/such/MyApp.app") }
    }

    // MARK: - Wire

    /// An agent from before macOS support announces neither platform nor transport.
    @Test func oldAnnouncementsAreIOSOverASocket() throws {
        let old = try JSONDecoder().decode(AgentAnnouncement.self, from: Data(#"""
        {"wire":1,"pid":42,"bundleId":"com.example.app","name":"App","socket":"/tmp/apvt-501/42.sock","swiftUIDebug":true,"startedAt":0,"loadedBy":"setup"}
        """#.utf8))
        #expect(old.platform == nil && old.transport == nil && old.bundlePath == nil)
        let agent = RunningAgent(old, platform: Snapshot.iOSSimulator)
        #expect(agent.platform == Snapshot.iOSSimulator && agent.transport != AgentWire.transportPipe)

        let request = AgentRequest(cmd: "snapshot", window: "Inspector")
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.window == "Inspector")
        #expect(AgentWire.pipeInPath(uid: 501, pid: 42) == "/tmp/apvt-501/42.in")
    }

    // MARK: - Output

    @Test func theHeaderNamesTheWindowAndWhereItIs() throws {
        let snapshot = try Fixture.macSnapshot("profile").snapshot
        let header = InspectReport.header(snapshot)
        #expect(header.contains("· macOS 27.0.1 · window 1 \"Profile card\" 420x552pt @2x at (525,200)"))
        #expect(snapshot.surfaceName == "window" && snapshot.layoutFramework == "AppKit")
    }

    // MARK: - Agent

    /// Builds the embedded agent sources for macOS (both architectures): `swift build` does not.
    @Test(.enabled(if: (try? Shell.xcrun(["--sdk", "macosx", "--show-sdk-path"]).ok) == true))
    func theAgentBuildsForMacOS() throws {
        let products = try MacAgentBuilder.ensure()
        #expect(FileManager.default.fileExists(atPath: products.agent.path))
        let archs = try Shell.run("/usr/bin/lipo", ["-archs", products.agent.path]).stdout
        #expect(archs.contains("arm64") && archs.contains("x86_64"))
    }
}

/// What macOS's SwiftUI records differently from iOS's.
@Suite("SwiftUI debug data on macOS")
struct MacSwiftUIDebugParserTests {
    /// One node of `makeViewDebugData`: a type, an optional frame and value, children.
    func node(_ type: String, frame: [Double]? = nil, value: [String: Any]? = nil, _ children: [[String: Any]] = []) -> [String: Any] {
        var properties: [[String: Any]] = [["id": 0, "attribute": ["readableType": type, "type": "SwiftUI.\(type)", "flags": 0]]]
        if let value { properties.append(["id": 1, "attribute": value]) }
        if let frame {
            properties.append(["id": 3, "attribute": ["value": [frame[0], frame[1]]]])
            properties.append(["id": 4, "attribute": ["value": [frame[2], frame[3]]]])
        }
        return ["properties": properties, "children": children]
    }

    func text(_ string: String, frame: [Double], _ children: [[String: Any]] = []) -> [String: Any] {
        let storage: [String: Any] = ["name": "storage", "readableType": "Text.Storage",
                                      "subattributes": [["name": "verbatim", "readableType": "String", "value": string]]]
        return node("Text", frame: frame, value: ["readableType": "Text", "subattributes": [storage]], children)
    }

    func all(_ nodes: [Node]) -> [Node] {
        nodes.flatMap { [$0] + all($0.children) }
    }

    /// A menu-style Picker lays out a hidden copy with every option to size itself.
    @Test func theCopyAControlLaysOutOnlyToSizeItselfIsHidden() {
        let sizing = node("ModifiedContent<PlaceholderContentView<OpacityTransition>, OpacityRendererEffect>", frame: [0, 0, 90, 24], [
            node("HiddenForLayoutModifier", [
                node("ZStack<ForEach>", frame: [10, 4, 45, 16], [text("System", frame: [10, 4, 45, 16]), text("Light", frame: [10, 4, 31, 16])]),
            ]),
        ])
        let shown = node("_PaddingLayout", frame: [0, 0, 90, 24], [text("System", frame: [10, 4, 45, 16])])
        let nodes = SwiftUIDebugParser.parse(nodes: [node("HStack<TupleView>", frame: [0, 0, 90, 24], [sizing, shown])])
        let window = Node(source: .appkit, type: "NSWindow", role: .window, frame: Rect(x: 0, y: 0, width: 200, height: 100), children: nodes)
        let snapshot = Snapshot(platform: Snapshot.macOS, app: AppInfo(bundleId: "x", name: "X", pid: 1, osVersion: "27.0"),
                                screen: ScreenInfo(width: 200, height: 100, scale: 2, safeArea: .zero), windows: [window])
        let indexed = IndexedSnapshot(snapshot)
        // The hidden copy's "System" and the shown one.
        #expect(indexed.entries.filter { $0.node.text?.string == "System" }.map(\.hidden).sorted { !$0 && $1 } == [false, true])
        #expect(indexed.entries.first { $0.node.text?.string == "Light" }?.hidden == true)
        #expect(Analyzer(for: snapshot).analyze(indexed).isEmpty)
    }

    /// `.opacity(0)` on the way to a view: not drawn, so not judged.
    @Test func fullyTransparentContentIsNotAppContent() {
        let opacity: [String: Any] = ["readableType": "_OpacityEffect", "subattributes": [["name": "opacity", "readableType": "Double", "value": 0]]]
        let nodes = SwiftUIDebugParser.parse(nodes: [
            node("VStack<TupleView>", frame: [0, 0, 100, 40], [
                node("_OpacityEffect", value: opacity, [text("Ghost", frame: [0, 0, 40, 16])]),
                text("Shown", frame: [0, 20, 40, 16]),
            ]),
        ])
        let flat = all(nodes)
        #expect(flat.first { $0.text?.string == "Ghost" }?.alpha == 0)
        #expect(flat.first { $0.text?.string == "Shown" }?.alpha == nil)
    }

    /// macOS builds a TextField or a pop-up button without a framed node of that name: the
    /// wrapper that carries the frame is the control.
    @Test func aControlNamedOnlyOnTheFramelessChainIsAControl() {
        let field = node("ScrollEdgeEffectTagModifier", frame: [0, 0, 200, 24], [
            node("PrimitiveSystemTextField", [
                node("ModifiedContent<PlatformTextFieldAdaptor>", frame: [0, 0, 200, 24]),
                node("ZStack<Text>", frame: [0, 0, 0, 0]),
            ]),
        ])
        let popUp = node("ScrollEdgeEffectTagModifier", frame: [0, 30, 90, 24], [
            node("MenuButtonInteractionModifier", [node("_PaddingLayout", frame: [0, 30, 80, 24], [text("System", frame: [10, 34, 45, 16])])]),
        ])
        let nodes = SwiftUIDebugParser.parse(nodes: [node("VStack<TupleView>", frame: [0, 0, 200, 60], [field, popUp])])
        let flat = all(nodes)
        let textField = try? #require(flat.first { $0.type == "TextField" })
        #expect(textField?.role == .control)
        #expect(textField?.children.allSatisfy { $0.has("internal") } == true)
        let button = try? #require(flat.first { $0.type == "PopUpButton" })
        #expect(button?.role == .control)
        // The value a pop-up button shows is the app's text: still checked.
        #expect(all(button?.children ?? []).contains { $0.text?.string == "System" && !$0.has("internal") })
    }

    /// AppKit's attributed string names the exact font; UIKit's only a family and "bold".
    @Test func theResolvedFontIsReadFromTheAttributedString() {
        let appKit = "Share calendar{\n    NSColor = \"sRGB 1 1 1 0.85\";\n    NSFont = \"\\\".SFNS-Semibold 13.00 pt. P [] (0x7c71625b80) fobj=0x7c71625b80, spc=3.58\\\"\";\n    NSLanguage = en;\n}"
        let font = ResolvedText.font(in: appKit)
        #expect(font?.name == ".SFNS-Semibold" && font?.size == 13 && font?.bold == true)
        let named = ResolvedText.font(in: "x{\n    NSFont = \"\\\"Helvetica Neue 18.50 pt. P [] (0x1) fobj=0x1, spc=5\\\"\";\n}")
        #expect(named?.name == "Helvetica Neue" && named?.size == 18.5 && named?.bold == false)
        let uiKit = ResolvedText.font(in: "x{\n    NSFont = \"<UICTFont: 0x1> font-family: \\\"UICTFontTextStyleTitle2\\\"; font-weight: bold; font-style: normal; font-size: 22.00pt\";\n}")
        #expect(uiKit?.name == nil && uiKit?.size == nil)
        #expect(ResolvedText.font(in: "plain string") == nil)

        let resolved = ResolvedText(["readableType": "StyledTextContentView", "subattributes": [
            ["name": "text", "subattributes": [["name": "cache", "subattributes": [
                ["name": "string", "value": appKit], ["name": "lineLimit", "value": 1], ["name": "minScaleFactor", "value": 1],
            ]]]],
        ]])
        var info: TextInfo? = TextInfo(string: "Share calendar")
        resolved?.apply(to: &info)
        #expect(info?.fontName == ".SFNS-Semibold" && info?.fontSize == 13 && info?.maxLines == 1)
        #expect(resolved?.shrinks == false)
    }

    /// The recorded macOS screens carry what the parser took from that data.
    @Test func recordedScreensNameControlsAndFonts() throws {
        let header = try Fixture.macSnapshot("header")
        let title = try #require(header.entries.first { $0.node.identifier == "header-title" })
        #expect(title.node.text?.fontSize == 22 && title.node.text?.maxLines == 1 && title.node.text?.fontGuessed != true)
        let form = try Fixture.macSnapshot("form")
        let email = try #require(form.entries.first { $0.node.identifier == "email" && $0.node.source == .swiftui })
        #expect(email.node.type == "TextField" && email.node.role == .control)
    }
}

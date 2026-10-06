import APVTCore
import APVTModel
import Testing

/// Every defect Examples/APVTSample plants is found, and nothing else: the clean screens
/// (a Form and a scrolling feed) report no issue.
@Suite("Analyzer on the sample app's screens")
struct AnalyzerTests {
    /// (rule, text the message starts with) per screen.
    static let expected: [String: [(Rule, String)]] = [
        "profile": [
            (.widerThanScreen, "@14 .frame"),
            (.squeezed, "@27 HStack \"Follow\""),
            (.offscreen, "@29 RoundedRectangle"),
            (.offscreen, "@30 Text \"Recent posts\""),
        ],
        "pricing": [
            (.widerThanScreen, "@14 .frame"),
            (.offscreen, "@24 RoundedRectangle.stroke"),
            (.offscreen, "@38 RoundedRectangle.stroke"),
        ],
        "badge": [
            (.truncated, "@22 Text #description"),
            (.overlap, "@18 Text \"Inbox messages\""),
        ],
        "header": [(.unsafeArea, "@21 Text #header-title \"Today\"")],
        "form": [(.smallTarget, "@22 Button #help")],
        "uikit": [
            (.offscreen, "@20 UILabel #uikit-title"),
            (.truncated, "@21 UILabel #uikit-subtitle"),
            (.clipped, "@23 UILabel #uikit-footer"),
            (.brokenConstraint, "UIKit broke <uikit-manage.width == 200"),
            (.overlap, "@24 UIButton #uikit-manage"),
        ],
        "settings": [],
        "feed": [],
    ]

    @Test(arguments: ["profile", "pricing", "badge", "header", "form", "uikit", "settings", "feed"])
    func findsWhatTheScreenPlants(screen: String) throws {
        let issues = try Fixture.issues(screen)
        let expected = Self.expected[screen]!
        #expect(issues.count == expected.count, "\(issues.summary)")
        for (rule, prefix) in expected {
            #expect(issues.contains { $0.rule == rule && $0.message.hasPrefix(prefix) }, "missing \(rule.rawValue) \(prefix) in \(issues.summary)")
        }
    }

    @Test func widerThanScreenNamesTheFixedSizeChild() throws {
        let profile = try Fixture.issues("profile").first { $0.rule == .widerThanScreen }!
        #expect(profile.message.contains("@22 .fixedSize 279.3pt"))
        let pricing = try Fixture.issues("pricing").first { $0.rule == .widerThanScreen }!
        #expect(pricing.message.contains("frame(width: 150, height: 140)"))
        #expect(pricing.related.count == 3)
    }

    @Test func squeezedTextSaysWhichWordDoesNotFit() throws {
        let issue = try Fixture.issues("profile").first { $0.rule == .squeezed }!
        #expect(issue.message.contains("inside @25 Button #follow"))
        #expect(issue.message.contains("the word \"Follow\""))
    }

    @Test func clippedNamesTheClippingAncestor() throws {
        let issue = try Fixture.issues("uikit").first { $0.rule == .clipped }!
        #expect(issue.related == [22])
        #expect(issue.message.contains("entirely hidden"))
    }

    @Test func rulesCanBeSelected() throws {
        var analyzer = Analyzer()
        analyzer.rules = [.overlap]
        let issues = analyzer.analyze(try Fixture.snapshot("uikit"))
        #expect(issues.map(\.rule) == [.overlap])
    }

    @Test func smallTargetThresholdIsConfigurable() throws {
        var analyzer = Analyzer()
        analyzer.minimumTarget = 10
        #expect(!analyzer.analyze(try Fixture.snapshot("form")).contains { $0.rule == .smallTarget })
    }

    @Test func errorsComeBeforeWarnings() throws {
        let issues = try Fixture.issues("uikit")
        let firstWarning = issues.firstIndex { $0.severity == .warning } ?? issues.count
        #expect(issues[firstWarning...].allSatisfy { $0.severity == .warning })
    }
}

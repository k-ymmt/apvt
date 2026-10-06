import APVTCore
import APVTModel
import Testing

@Suite("Selectors and assertions")
struct QueryTests {
    @Test func selectorsFindByIdentifierTextTypeAndRef() throws {
        let s = try Fixture.snapshot("uikit")
        #expect(try NodeSelector("#uikit-manage").select(in: s).map(\.ref) == [24])
        #expect(try NodeSelector("text:renews").select(in: s).map(\.ref) == [21])
        #expect(try NodeSelector("text=Cancel anytime").select(in: s).map(\.ref) == [23])
        #expect(try NodeSelector("type:UIButton").select(in: s).count == 2)
        #expect(try NodeSelector("type:UILabel,text:Monthly").select(in: s).map(\.ref) == [20])
        #expect(try NodeSelector("uikit-footer").select(in: s).map(\.ref) == [23])
        #expect(try NodeSelector("@24").select(in: s).first?.node.identifier == "uikit-manage")
    }

    @Test func systemChromeIsLeftOutUnlessAsked() throws {
        let s = try Fixture.snapshot("uikit")
        let all = try NodeSelector("text:UIKit Auto Layout").select(in: s, includeSystem: true)
        let app = try NodeSelector("text:UIKit Auto Layout").select(in: s)
        #expect(all.count > app.count)
    }

    @Test func badSelectorsSayHowToWriteThem() {
        #expect(throws: APVTError.self) { try NodeSelector("") }
        #expect(throws: APVTError.self) { try NodeSelector("role:button") }
    }

    func evaluate(_ selector: String, _ configure: (inout AssertionSpec) throws -> Void) throws -> [AssertionResult] {
        let s = try Fixture.snapshot("uikit")
        var spec = AssertionSpec()
        try configure(&spec)
        return try Assertions.evaluate(spec, selector: try NodeSelector(selector), in: s, issues: Analyzer().analyze(s), includeSystem: false)
    }

    @Test func insideScreenFailsWithTheOverflow() throws {
        let results = try evaluate("#uikit-title") { $0.inside = [.screen] }
        #expect(results.count == 1)
        #expect(!results[0].passed)
        #expect(results[0].detail.contains("right by 38pt"))
    }

    @Test func sizesAlignmentAndRelations() throws {
        let manage = try evaluate("#uikit-manage") {
            $0.width = try .init("140")
            $0.height = try .init(">=44")
            $0.aligned = [(.leading, try .init("#uikit-title"))]
            $0.relative = [(.leftOf, try .init("#uikit-upgrade"))]
        }
        #expect(manage.map(\.passed) == [true, false, true, false])
        #expect(manage[3].detail.contains("overlap"))
    }

    @Test func issueBackedChecks() throws {
        let subtitle = try evaluate("#uikit-subtitle") { $0.notTruncated = true; $0.visible = true }
        #expect(subtitle.map(\.passed) == [true, false])
        let footer = try evaluate("#uikit-footer") { $0.visible = true }
        #expect(footer.map(\.passed) == [false])
        let manage = try evaluate("#uikit-manage") { $0.noOverlap = true; $0.noIssues = true }
        #expect(manage.map(\.passed) == [false, false])
    }

    @Test func countAndExistence() throws {
        #expect(try evaluate("type:UIButton") { $0.count = 2 }.allSatisfy(\.passed))
        let missing = try evaluate("#nope") { _ in }
        #expect(missing.count == 1 && !missing[0].passed)
    }

    @Test func comparisonsParse() throws {
        #expect(try AssertionSpec.Comparison(">=44").description == ">= 44")
        #expect(try AssertionSpec.Comparison("<= 10.5").description == "<= 10.5")
        #expect(throws: APVTError.self) { try AssertionSpec.Comparison("wide") }
    }

    @Test func referenceMustBeUnique() throws {
        #expect(throws: APVTError.self) {
            _ = try evaluate("#uikit-manage") { $0.aligned = [(.top, try .init("type:UIButton"))] }
        }
    }
}

import APVTCore
import APVTModel
import CoreGraphics
import ImageIO
import Foundation
import Testing

@Suite("Output")
struct OutputTests {
    @Test func treeFoldsChainsHidesPrivateViewsAndMarksIssues() throws {
        let s = try Fixture.snapshot("profile")
        let text = TreeFormatter().format(s, issues: Analyzer().analyze(s))
        #expect(text.contains("@1 UIWindow > @2 UITransitionView"))
        #expect(text.contains("@30 Text \"Recent posts\" (-6.7,324.3 124.7x26.3) !offscreen"))
        #expect(text.contains("system chrome"))
        #expect(!text.contains("{internal"))
    }

    @Test func inspectReportEndsWithFixesAndNextStep() throws {
        let s = try Fixture.snapshot("badge")
        let report = InspectReport(s, issues: Analyzer().analyze(s))
        let text = report.text(limit: nil)
        #expect(text.hasPrefix("1 error, 1 warning:"))
        #expect(text.contains("how to fix:\n- truncated:"))
        #expect(text.contains("next: apvt query @22"))
        #expect(report.hints.keys.sorted() == ["overlap", "truncated"])
    }

    @Test func queryShowsMetricsAncestorsAndIssues() throws {
        let s = try Fixture.snapshot("uikit")
        let issues = Analyzer().analyze(s)
        let text = QueryFormatter.text(try NodeSelector("#uikit-subtitle").select(in: s), in: s, issues: issues)
        #expect(text.contains("numberOfLines 1"))
        #expect(text.contains("E truncated:"))
        #expect(text.contains("in: "))
    }

    @Test func annotatesAScreenshot() throws {
        let s = try Fixture.snapshot("uikit")
        let directory = FileManager.default.temporaryDirectory.appending(path: "apvt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A blank 3x "screenshot" of the right size.
        let width = Int(s.snapshot.screen.width * 3), height = Int(s.snapshot.screen.height * 3)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let blank = directory.appending(path: "blank.png")
        let destination = CGImageDestinationCreateWithURL(blank as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let output = directory.appending(path: "annotated.png")
        try Annotator.annotate(screenshot: blank, output: output, snapshot: s, issues: Analyzer().analyze(s), outline: .all)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

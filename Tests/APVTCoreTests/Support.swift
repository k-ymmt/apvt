import APVTCore
import APVTModel
import Foundation

/// Fixtures were recorded from Examples/APVTSample on an iPhone 17 Pro (iOS 27.0) simulator:
///
///     apvt setup
///     xcrun simctl launch booted dev.apvt.sample -screen <name>
///     apvt inspect --save Tests/APVTCoreTests/Fixtures/sample-<name>.json
///
/// `swiftui-profile-navigation.json` is the NavigationStack hosting view's `makeViewDebugData`
/// on the profile screen (`apvt debug swiftui-raw`, that hosting view's `data`).
enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    }

    static func snapshot(_ screen: String) throws -> IndexedSnapshot {
        let data = try Data(contentsOf: url("sample-\(screen)"))
        return IndexedSnapshot(try JSONDecoder().decode(Snapshot.self, from: data))
    }

    static func issues(_ screen: String) throws -> [Issue] {
        Analyzer().analyze(try snapshot(screen))
    }
}

extension Array where Element == Issue {
    /// `rule: node description` pairs, for comparing with what a screen plants.
    var summary: [String] {
        map { "\($0.rule.rawValue) \($0.message.split(separator: " (").first ?? "")" }
    }
}

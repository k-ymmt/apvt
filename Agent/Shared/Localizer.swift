import Foundation

/// What a `LocalizedStringKey` shows in the app's current language. SwiftUI looks keys up in
/// `Localizable` of the main bundle unless a view names another bundle — which the debug data
/// does not say, so the other loaded bundles (Swift packages' resources) are tried next.
@MainActor
enum Localizer {
    private static var cache: [String: String?] = [:]
    private static let missing = "\u{1}apvt-missing\u{1}"

    static func localize(_ key: String) -> String? {
        MainActor.assumeIsolated {
            if let hit = cache[key] { return hit }
            var result: String?
            for bundle in [Bundle.main] + Bundle.allBundles + resourceBundles() {
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                if value != missing { result = value; break }
            }
            cache[key] = result
            return result
        }
    }

    private static var resources: [Bundle]?

    /// `*.bundle` resource bundles inside the app (SwiftPM `Bundle.module`s), loaded lazily by the app.
    private static func resourceBundles() -> [Bundle] {
        if let resources { return resources }
        let roots = [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap { $0 }
        var found: [Bundle] = []
        for root in roots {
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            found += urls.filter { $0.pathExtension == "bundle" }.compactMap(Bundle.init(url:))
        }
        resources = found
        return found
    }
}

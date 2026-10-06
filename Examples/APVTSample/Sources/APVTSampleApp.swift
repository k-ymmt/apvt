import SwiftUI

/// A sample app whose screens hold the layout mistakes an AI agent tends to make.
/// Every defect is planted on purpose; `Examples/APVTSample/README.md` lists them.
///
/// `-screen <name>` opens one screen directly (e.g. `simctl launch … -screen pricing`).
@main
struct APVTSampleApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(initial: Screen(rawValue: UserDefaults.standard.string(forKey: "screen") ?? ""))
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case profile, pricing, badge, header, form, uikit, settings, feed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile card"
        case .pricing: "Pricing columns"
        case .badge: "Badge and clipped text"
        case .header: "Header under the status bar"
        case .form: "Form"
        case .uikit: "UIKit Auto Layout"
        case .settings: "Settings (clean)"
        case .feed: "Feed (clean)"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .profile: ProfileScreen()
        case .pricing: PricingScreen()
        case .badge: BadgeScreen()
        case .header: HeaderScreen()
        case .form: FormScreen()
        case .uikit: UIKitScreen().ignoresSafeArea(edges: .bottom)
        case .settings: SettingsScreen()
        case .feed: FeedScreen()
        }
    }
}

struct RootView: View {
    let initial: Screen?

    var body: some View {
        if let initial {
            NavigationStack {
                initial.view.navigationTitle(initial.title).navigationBarTitleDisplayMode(.inline)
            }
        } else {
            NavigationStack {
                List(Screen.allCases) { screen in
                    NavigationLink(screen.title) {
                        screen.view.navigationTitle(screen.title).navigationBarTitleDisplayMode(.inline)
                    }
                }
                .navigationTitle("APVT Sample")
            }
        }
    }
}

import SwiftUI

/// A sample macOS app whose screens hold the layout mistakes an AI agent tends to make.
/// Every defect is planted on purpose; `Examples/APVTMacSample/README.md` lists them.
///
/// `-screen <name>` opens one screen directly (`apvt launch APVTMacSample.app -- -screen pricing`).
/// `-inspector YES` also opens a second window, and `-sheet YES` a sheet, for `--window`.
@main
struct APVTMacSampleApp: App {
    var body: some Scene {
        WindowGroup("APVT Mac Sample") {
            RootView(initial: Screen(rawValue: UserDefaults.standard.string(forKey: "screen") ?? ""))
                .frame(width: Screen.windowWidth, height: Screen.windowHeight)
        }
        .windowResizability(.contentSize)

        Window("Inspector", id: "inspector") {
            InspectorView()
        }
        .windowResizability(.contentSize)
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case profile, pricing, badge, header, form, appkit, settings, feed

    /// Every screen is laid out in a window of this fixed content size.
    static let windowWidth: CGFloat = 420
    static let windowHeight: CGFloat = 520

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile card"
        case .pricing: "Pricing columns"
        case .badge: "Badge and clipped text"
        case .header: "Header with a truncated title"
        case .form: "Form"
        case .appkit: "AppKit Auto Layout"
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
        case .appkit: AppKitScreen()
        case .settings: SettingsScreen()
        case .feed: FeedScreen()
        }
    }
}

struct RootView: View {
    let initial: Screen?
    @Environment(\.openWindow) private var openWindow
    @State private var sheet = UserDefaults.standard.bool(forKey: "sheet")

    var body: some View {
        Group {
            if let initial {
                initial.view.navigationTitle(initial.title)
            } else {
                NavigationStack {
                    List(Screen.allCases) { screen in
                        NavigationLink(screen.title) {
                            screen.view.navigationTitle(screen.title)
                        }
                    }
                    .navigationTitle("APVT Mac Sample")
                }
            }
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "inspector") { openWindow(id: "inspector") }
        }
        .sheet(isPresented: $sheet) {
            VStack(spacing: 12) {
                Text("Export finished").font(.headline)
                Text("3 files were written to the Downloads folder.")
                Button("Done") { sheet = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sheet-done")
            }
            .padding(24)
        }
    }
}

/// A second window, laid out correctly.
struct InspectorView: View {
    @State private var opacity = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector").font(.headline)
            Slider(value: $opacity) { Text("Opacity") }
            Text("Changes apply to the selected layer.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("inspector-note")
        }
        .padding()
        .frame(width: 300)
    }
}

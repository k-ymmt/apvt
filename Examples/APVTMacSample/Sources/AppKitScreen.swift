import AppKit
import SwiftUI

struct AppKitScreen: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> LayoutViewController { LayoutViewController() }
    func updateNSViewController(_ controller: LayoutViewController, context: Context) {}
}

/// Planted defects, Auto Layout flavour:
/// - `titleLabel` has a fixed 440pt width inside a 420pt window (protrudes on the right).
/// - `subtitleLabel` is single-line in a 160pt box with a long sentence (truncated "…").
/// - `card` clips to bounds and its `footerLabel` sits below the card's height (hidden).
/// - `overlapButton` is pinned on top of `actionButton`.
/// - `actionButton` has two conflicting width constraints (AppKit breaks one at runtime).
final class LayoutViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let titleLabel = NSTextField(labelWithString: "Monthly subscription summary")
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.setAccessibilityIdentifier("appkit-title")

        let subtitleLabel = NSTextField(labelWithString: "Your plan renews automatically on the first day of every month")
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setAccessibilityIdentifier("appkit-subtitle")

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 0
        card.fillColor = .quaternaryLabelColor
        card.contentViewMargins = .zero
        card.clipsToBounds = true
        card.setAccessibilityIdentifier("appkit-card")

        let footerLabel = NSTextField(labelWithString: "Cancel anytime")
        footerLabel.setAccessibilityIdentifier("appkit-footer")
        card.addSubview(footerLabel)

        let actionButton = NSButton(title: "Manage", target: nil, action: nil)
        actionButton.bezelStyle = .push
        actionButton.keyEquivalent = "\r"
        actionButton.setAccessibilityIdentifier("appkit-manage")

        let overlapButton = NSButton(title: "Upgrade", target: nil, action: nil)
        overlapButton.bezelStyle = .push
        overlapButton.setAccessibilityIdentifier("appkit-upgrade")

        for v in [titleLabel, subtitleLabel, card, actionButton, overlapButton] {
            view.addSubview(v)
        }
        for v in [titleLabel, subtitleLabel, card, footerLabel, actionButton, overlapButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.widthAnchor.constraint(equalToConstant: 440),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            subtitleLabel.widthAnchor.constraint(equalToConstant: 160),

            card.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            card.heightAnchor.constraint(equalToConstant: 80),
            footerLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            footerLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 96),

            actionButton.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 24),
            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            actionButton.widthAnchor.constraint(equalToConstant: 140),
            actionButton.widthAnchor.constraint(equalToConstant: 200),

            overlapButton.topAnchor.constraint(equalTo: actionButton.topAnchor, constant: 10),
            overlapButton.leadingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: 60),
        ])
    }
}

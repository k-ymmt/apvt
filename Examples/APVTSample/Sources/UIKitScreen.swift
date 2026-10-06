import SwiftUI
import UIKit

struct UIKitScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LayoutViewController { LayoutViewController() }
    func updateUIViewController(_ controller: LayoutViewController, context: Context) {}
}

/// Planted defects, Auto Layout flavour:
/// - `titleLabel` has a fixed 420pt width inside a 402pt screen (protrudes on the right).
/// - `subtitleLabel` is single-line in a 160pt box with a long sentence (truncated "…").
/// - `card` clips to bounds and its `footerLabel` sits below the card's height (hidden).
/// - `overlapButton` is pinned on top of `actionButton`.
/// - `actionButton` has two conflicting width constraints (UIKit breaks one at runtime).
final class LayoutViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Monthly subscription summary"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.accessibilityIdentifier = "uikit-title"

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Your plan renews automatically on the first day of every month"
        subtitleLabel.numberOfLines = 1
        subtitleLabel.accessibilityIdentifier = "uikit-subtitle"

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        card.accessibilityIdentifier = "uikit-card"

        let footerLabel = UILabel()
        footerLabel.text = "Cancel anytime"
        footerLabel.accessibilityIdentifier = "uikit-footer"
        card.addSubview(footerLabel)

        let actionButton = UIButton(configuration: .filled())
        actionButton.setTitle("Manage", for: .normal)
        actionButton.accessibilityIdentifier = "uikit-manage"

        let overlapButton = UIButton(configuration: .tinted())
        overlapButton.setTitle("Upgrade", for: .normal)
        overlapButton.accessibilityIdentifier = "uikit-upgrade"

        for v in [titleLabel, subtitleLabel, card, actionButton, overlapButton] {
            view.addSubview(v)
        }
        for v in [titleLabel, subtitleLabel, card, footerLabel, actionButton, overlapButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.widthAnchor.constraint(equalToConstant: 420),

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

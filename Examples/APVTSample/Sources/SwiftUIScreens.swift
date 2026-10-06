import SwiftUI

// MARK: - Profile card
// Planted: the name is `.fixedSize()`, so it never truncates and pushes the
// Follow button past the right edge of the screen.

struct ProfileScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Circle().fill(.orange).frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Alexandra Montgomery-Williamson")
                        .font(.headline)
                        .fixedSize()
                    Text("iOS engineer")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Follow") {}
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("follow")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.95)))
            Text("Recent posts").font(.title2)
            Spacer()
        }
        .padding()
    }
}

// MARK: - Pricing columns
// Planted: three columns of a fixed 150pt each (450pt + spacing) in a 402pt screen.

struct PricingScreen: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Choose a plan").font(.largeTitle.bold())
            HStack(spacing: 12) {
                PlanColumn(name: "Free", price: "$0")
                PlanColumn(name: "Pro", price: "$9")
                PlanColumn(name: "Team", price: "$29")
            }
            Spacer()
        }
        .padding(.top)
    }
}

private struct PlanColumn: View {
    let name: String
    let price: String

    var body: some View {
        VStack(spacing: 8) {
            Text(name).font(.headline)
            Text(price).font(.title.bold())
            Text("per month").font(.caption)
        }
        .frame(width: 150, height: 140)
        .background(RoundedRectangle(cornerRadius: 12).stroke(.blue))
        .accessibilityIdentifier("plan-\(name.lowercased())")
    }
}

// MARK: - Badge and clipped text
// Planted: the badge is moved with `.offset` and covers the title; the description
// is given a fixed 20pt height and `.clipped()`, so only part of its first line shows.

struct BadgeScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                Text("Inbox messages")
                    .font(.title)
                Text("99+")
                    .font(.caption.bold())
                    .padding(6)
                    .background(Capsule().fill(.red))
                    .foregroundStyle(.white)
                    .offset(x: 60, y: 4)
                    .accessibilityIdentifier("badge")
            }
            Text("Messages from your team appear here. Swipe left on a message to archive it, or right to mark it as read.")
                .font(.body)
                .frame(height: 20)
                .clipped()
                .accessibilityIdentifier("description")
            Spacer()
        }
        .padding()
    }
}

// MARK: - Header under the status bar
// Planted: the header ignores the safe area, so its title sits under the status bar.

struct HeaderScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.indigo
                Text("Today")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .padding(.leading)
                    .accessibilityIdentifier("header-title")
            }
            .frame(height: 120)
            .ignoresSafeArea(edges: .top)
            List(1..<6) { Text("Row \($0)") }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Form
// Planted: the hint is near-white on white, the help icon is a 14pt tap target, and the
// Submit button's label is the same colour as its background.

struct FormScreen: View {
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                Button {
                } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 12))
                }
                .frame(width: 14, height: 14)
                .accessibilityIdentifier("help")
            }
            Text("We never share your address.")
                .font(.footnote)
                .foregroundStyle(Color(white: 0.9))
                .accessibilityIdentifier("hint")
            Button {
            } label: {
                Text("Submit")
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 10).fill(.blue))
            }
            .accessibilityIdentifier("submit")
            Spacer()
        }
        .padding()
    }
}

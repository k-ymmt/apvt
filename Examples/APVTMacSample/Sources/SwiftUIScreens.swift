import SwiftUI

// MARK: - Profile card
// Planted: the name is `.fixedSize()`, so it never truncates and pushes the
// Follow button past the right edge of the window.

struct ProfileScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Circle().fill(.orange).frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Alexandra Montgomery-Williamson")
                        .font(.title)
                        .fixedSize()
                    Text("macOS engineer")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Follow") {}
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("follow")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15)))
            Text("Recent posts").font(.title2)
            Spacer()
        }
        .padding()
    }
}

// MARK: - Pricing columns
// Planted: three columns of a fixed 150pt each (450pt + spacing) in a 420pt window.

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
// is given a fixed 16pt height and `.clipped()`, so only its first line shows.

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
            Text("Messages from your team appear here. Select a message and press Delete to archive it, or Return to open it in its own window.")
                .font(.body)
                .frame(height: 16)
                .clipped()
                .accessibilityIdentifier("description")
            Spacer()
        }
        .padding()
    }
}

// MARK: - Header with a truncated title
// Planted: the header's buttons are `.fixedSize()` and take what they need, so the one-line
// title next to them is cut to "Today's sch…".

struct HeaderScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Today's schedule overview")
                    .font(.title.bold())
                    .lineLimit(1)
                    .accessibilityIdentifier("header-title")
                Spacer(minLength: 0)
                Button("Add appointment") {}.fixedSize()
                Button("Share calendar") {}.fixedSize()
            }
            .padding()
            .background(Color.indigo.opacity(0.25))
            List(1..<6) { Text("Row \($0)") }
        }
    }
}

// MARK: - Form
// Planted: the hint shares a row with two `.fixedSize()` buttons and is left with less width
// than its longest word, so it breaks mid-word. (The hint is also near-white on white, which
// apvt does not check.)

struct FormScreen: View {
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("email")
            HStack(alignment: .top, spacing: 8) {
                Text("Unsubscribe whenever you like.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.9))
                    .accessibilityIdentifier("hint")
                Button("Send a verification email to this address") {}
                    .fixedSize()
                    .accessibilityIdentifier("verify")
                Button("Cancel") {}
                    .fixedSize()
            }
            Spacer()
        }
        .padding()
    }
}

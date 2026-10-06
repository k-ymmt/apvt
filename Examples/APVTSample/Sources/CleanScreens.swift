import SwiftUI

// Screens built the way they should be: apvt must report nothing here.

struct SettingsScreen: View {
    @State private var notifications = true
    @State private var theme = "System"
    @State private var count = 3
    @State private var name = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Notifications", isOn: $notifications)
                Picker("Theme", selection: $theme) {
                    ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
                }
                Stepper("Items per page: \(count)", value: $count, in: 1...10)
            }
            Section {
                TextField("Display name", text: $name)
                Button("Save changes") {}
            } footer: {
                Text("Your display name is shown to everyone in your team, including people who join later.")
            }
        }
    }
}

struct FeedScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["All", "Design", "Engineering", "Marketing", "Sales", "Support", "Research"], id: \.self) { tag in
                            Text(tag)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                        }
                    }
                    .padding(.horizontal)
                }
                ForEach(1..<26) { i in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.3)).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Post number \(i) with a title that can be fairly long")
                                .font(.headline)
                            Text("A short summary of the post that wraps onto a second line when it needs to.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

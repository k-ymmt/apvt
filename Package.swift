// swift-tools-version: 6.4
import PackageDescription

// apvt — Apple Platform View Tester: lets an AI agent see what its views really look like.
//
// - APVTModel: the snapshot model and the agent wire protocol. Foundation only; compiled into
//   the host and, as source, into the in-app agent.
// - APVTCore: the host. Platforms (iOS Simulator today), the agent build, analysis (issues),
//   selectors, assertions, output and annotated screenshots.
// - apvt: the command line.
// - Agent/ (not a target): the in-app agent and loader sources. `EmbedAgentSources` embeds them
//   (with APVTModel) into APVTCore; the host builds them for the simulator on first use.
let package = Package(
    name: "apvt",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "apvt", targets: ["apvt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "APVTModel",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "apvt-embed",
            path: "Tools/apvt-embed",
        ),
        .plugin(
            name: "EmbedAgentSources",
            capability: .buildTool(),
            dependencies: ["apvt-embed"],
        ),
        .target(
            name: "APVTCore",
            dependencies: ["APVTModel"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            plugins: ["EmbedAgentSources"],
        ),
        .executableTarget(
            name: "apvt",
            dependencies: [
                "APVTCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "APVTCoreTests",
            dependencies: ["APVTCore", "APVTModel"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)

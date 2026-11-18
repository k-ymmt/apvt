# apvt

A command line that shows an AI agent what the views of an iOS Simulator app or a macOS app look
like (issues, view tree, frames, annotated screenshots) with no code in the app. See README.md
for usage, and docs/ios-simulator.md and docs/macos.md for the measurements behind the design.

## Build and test

```bash
swift build
swift test          # includes building the agent for the simulator and for macOS (needs Xcode)
```

`Agent/` is not compiled by `swift build`: the `EmbedAgentSources` plugin embeds `Agent/**` and
`Sources/APVTModel` into the binary, and apvt compiles them at run time with `xcrun --sdk
iphonesimulator|macosx swiftc` (`apvt setup` / `apvt launch`, or the
`agentAndLoaderBuildForTheSimulator` and `theAgentBuildsForMacOS` tests). `Agent/Shared` goes
into both agents, `Agent/iOS` and `Agent/macOS` into one each. After changing agent code:
`swift build && .build/debug/apvt launch <app>` (rebuilds the agent and restarts the app with it).

## Verifying against the simulator

```bash
cd Examples/APVTSample && xcodegen generate   # project.yml is the source of the .xcodeproj
xcodebuild -project APVTSample.xcodeproj -scheme APVTSample -destination 'id=<udid>' -derivedDataPath <dir> build
xcrun simctl install booted <dir>/Build/Products/Debug-iphonesimulator/APVTSample.app
apvt setup && xcrun simctl launch booted dev.apvt.sample -screen profile && apvt inspect
```

Screens: profile, pricing, badge, header, form, uikit (planted defects), settings, feed (clean:
must report nothing). After changing collection or analysis, re-record the fixtures as described
in `Tests/APVTCoreTests/Support.swift` and keep `AnalyzerTests.expected` exact.

## Verifying against a macOS app

```bash
cd Examples/APVTMacSample && xcodegen generate
xcodebuild -project APVTMacSample.xcodeproj -scheme APVTMacSample -derivedDataPath <dir> build
apvt launch <dir>/Build/Products/Debug/APVTMacSample.app -- -screen profile && apvt inspect
```

Screens: profile, pricing, badge, header, form, appkit (planted defects), settings, feed (clean).
The fixtures are `mac-sample-<screen>.json`, the exact results `AnalyzerTests.macExpected`.
`SwiftUIDebugParser` and the analyzer are shared: after changing either, check both samples.

## Rules of the code

- The agent collects; the host judges. Verdicts, selectors and wording live in `APVTCore`.
- `APVTModel` is Foundation-only and compiles for both the host and the agent; agent files never
  `import APVTModel` (they are compiled into one module with it).
- Swift only. Private API through `NSSelectorFromString` / runtime calls; no Objective-C files.
- Output is for agents: one line per finding, `@N` node numbers, frames as `(x,y wxh)` in points,
  errors as `error:` / `why:` / `fix:` with runnable commands.
- New platforms implement `Platform`; nothing above it may assume iOS. Rules that differ per
  platform (off by default, wording) are decided in `Analyzer(for:)` / `Rule`, not in the agent.

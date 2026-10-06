# apvt

A command line that shows an AI agent what an iOS Simulator app's views look like (issues, view
tree, frames, annotated screenshots) with no code in the app. See README.md for usage and
docs/ios-simulator.md for the measurements behind the design.

## Build and test

```bash
swift build
swift test          # includes building the agent for the simulator (needs Xcode)
```

`Agent/` is not compiled by `swift build` for the simulator: the `EmbedAgentSources` plugin embeds
`Agent/**` and `Sources/APVTModel` into the binary, and `apvt setup` (or the
`agentAndLoaderBuildForTheSimulator` test) compiles them with `xcrun --sdk iphonesimulator swiftc`.
After changing agent code: `swift build && .build/debug/apvt setup` (rebuilds the agent), then
relaunch the app.

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

## Rules of the code

- The agent collects; the host judges. Verdicts, selectors and wording live in `APVTCore`.
- `APVTModel` is Foundation-only and compiles for both the host and the agent; agent files never
  `import APVTModel` (they are compiled into one module with it).
- Swift only. Private API through `NSSelectorFromString` / runtime calls; no Objective-C files.
- Output is for agents: one line per finding, `@N` node numbers, frames as `(x,y wxh)` in points,
  errors as `error:` / `why:` / `fix:` with runnable commands.
- New platforms implement `Platform`; nothing above it may assume iOS.

# apvt — Apple Platform View Tester

`apvt` lets an AI agent (or you) see what an app's views really look like: the live view tree
of an app running in the **iOS Simulator** — UIKit views and SwiftUI views alike, with frames in
screen points — and the layout mistakes in it. The app needs **no code changes**: a small agent
library is loaded into it at launch.

```text
$ apvt inspect
APVTSample (dev.apvt.sample, pid 32556) · iPhone 17 Pro, iOS 27.0 · screen 402x874pt @3x, safe area top 62 bottom 34
4 errors, 0 warnings:
E wider-than-screen: @14 .frame (-22.7,116 447.3x724) is 447.3pt wide; the screen is 402pt; 2 visible element(s) end up past the edge. Fixed-size children: @22 .fixedSize 279.3pt
E squeezed: @27 HStack "Follow" (380.7,155 0x130.3) (inside @25 Button #follow label:"Follow") has no width, but the word "Follow" needs 49pt: its characters wrap one per line or are not drawn
E offscreen: @29 RoundedRectangle (-6.7,132 415.3x176.3) is cut off: 6.7pt past the left edge, 6.7pt past the right edge
E offscreen: @30 Text "Recent posts" (-6.7,324.3 124.7x26.3) is cut off: 6.7pt past the left edge
how to fix:
- …
next: apvt query @14   # the node, its ancestors and metrics · apvt tree · apvt screenshot --annotate <file.png>
```

## Install

Requires macOS 15+, Xcode with the iOS Simulator platform, Swift 6.2+ (the agent uses `@section`).

With Homebrew:

```bash
brew install k-ymmt/tap/apvt
```

From a release (a universal binary for Apple silicon and Intel):

```bash
curl -fsSL https://github.com/k-ymmt/apvt/releases/latest/download/apvt-macos.tar.gz | tar xz
mv apvt /usr/local/bin/   # or anywhere on PATH
```

The binary is not notarized: download it with `curl` as above (a browser download is quarantined
and blocked by Gatekeeper; `xattr -d com.apple.quarantine apvt` lifts that).

From source:

```bash
swift build -c release
cp .build/release/apvt /usr/local/bin/   # or anywhere on PATH
```

The binary carries the agent's sources and builds the agent for the simulator on first use
(a few seconds, cached under `~/Library/Caches/apvt/`).

## Use

```bash
apvt setup                 # once per simulator boot
xcrun simctl launch booted <bundle-id>   # or the home screen (not Xcode's Run; relaunch after it)
apvt inspect               # issues on the current screen
apvt query @14             # one node: ancestors, text metrics, issues
apvt tree                  # the view tree with frames
apvt assert '#follow' --visible --inside screen --min-width 44
apvt screenshot shot.png   # issues outlined and labelled @N
apvt rules                 # what inspect checks and how to fix each
apvt type "Buy eggs" --submit   # type into the focused text field (tap it first)
apvt launch-env            # env vars that make an Xcode-launched app load the agent
```

### Apps launched by Xcode (Run, Xcode MCP)

Xcode replaces launchd's `DYLD_INSERT_LIBRARIES`, so an app it launches has no agent. Give that
launch the variables `apvt launch-env` prints instead — for example as the `environmentVariables`
of Xcode MCP's `DeviceInteractionInstallAndRun` (`apvt launch-env --xcode` adds
`"$(inherited)": ""` to keep the scheme's own; `--compact` prints it on one line for a shell wrapper), or in the scheme's Run > Environment Variables. The app then runs under Xcode, with its
console and `GetConsoleOutput`, and answers apvt.

### Typing

`apvt type <text>` inserts text into whatever has keyboard focus, through `UIKeyInput` as the
keyboard does, so SwiftUI bindings, delegates and `.onChange` observe it. `--replace` clears the
field first; `--submit` presses Return (`textFieldShouldReturn`, `.onSubmit`). Tools that drive
the simulator by taps (Xcode MCP's `DeviceInteractionSynthesize`) can then tap the field and let
apvt type, instead of tapping keys one by one.

Every command takes `--json`, `--device <name|udid>`, `--app <bundle-id>` and `--wait <seconds>`
(wait for a just-launched app); `inspect` and `tree` take `--save file.json`, and any command can
read it back with `--snapshot file.json`. Without `--app`, apvt picks the one app whose agent
answers — only the foreground app does, iOS suspends the others. `inspect` exits 1 when it finds
an error (`--fail-on warning|never` to change). Errors say what happened, why, and the command
that fixes it.

### What `inspect` checks

| rule | finds |
|---|---|
| `offscreen` | content cut off by, or beyond, the screen edge (not inside a scroll view) |
| `wider-than-screen` | a container wider than the screen, with the fixed-size children that pushed it |
| `clipped` | content hidden by an ancestor that clips (`clipsToBounds`, `.clipped()`) |
| `truncated` | text that needs more room than its frame (measured with its font) |
| `squeezed` | text narrower than its longest word, controls collapsed to zero |
| `overlap` | texts / controls drawn on top of each other; an error when a text crosses a control's edge, a warning when it sits wholly inside one (a badge may be meant) |
| `unsafe-area` | text / controls under the status bar, Dynamic Island or home indicator |
| `small-target` | controls smaller than 24x24pt |
| `ambiguous-layout` | UIKit views whose Auto Layout frame is ambiguous |
| `broken-constraint` | `Unable to simultaneously satisfy constraints`, with the conflicting set |

Contrast is not checked.

## How it works

- **Injection.** `apvt setup` sets `DYLD_INSERT_LIBRARIES` in the simulator's launchd to a tiny
  loader; in user-installed apps only, the loader `dlopen`s the agent. Apps launched with
  `xcrun simctl launch` or from the home screen get it. **Xcode's Run does not**: it passes its
  own `DYLD_INSERT_LIBRARIES` (Main Thread Checker), which replaces launchd's, and loading the agent
  through Xcode's debugger did not work (see the docs). Build/run with Xcode, then relaunch with
  `xcrun simctl launch <udid> <bundle-id>` — or pass `apvt launch-env`'s variables to Xcode's
  launch, which puts the agent itself into `DYLD_INSERT_LIBRARIES`.
- **SwiftUI.** The agent sets `SWIFTUI_VIEW_DEBUG` before SwiftUI builds its first view graph and
  reads each hosting view's `makeViewDebugData()`: SwiftUI's own layout (types, frames,
  modifiers, texts). ScrollView content is mapped through the UIScrollView SwiftUI made for it.
- **Agent ↔ host.** A unix socket under `/tmp/apvt-<uid>/` (the simulator shares the host's
  filesystem). The agent collects; the host judges.
- **Platforms.** `Platform` (`Sources/APVTCore/Platform/Platform.swift`) is the seam: injection,
  discovery and screenshots per platform; analysis, selectors, assertions and output are shared.
  The snapshot model (`Sources/APVTModel`) has nothing iOS-specific.

Measurements behind these choices: [docs/ios-simulator.md](docs/ios-simulator.md).

## Layout

```
Sources/APVTModel/   snapshot model, wire protocol, SwiftUI debug-data parser (host + agent)
Sources/APVTCore/    host: platforms, agent build, analysis, selectors, assertions, output
Sources/apvt/        command line
Agent/iOS/           in-app agent (built for the simulator by the host)
Agent/Loader/        launchd loader
Plugins/, Tools/     embed Agent/ + APVTModel sources into the apvt binary
Examples/APVTSample/ sample app with planted layout mistakes (and clean screens)
Tests/APVTCoreTests/ tests on snapshots recorded from the sample app
```

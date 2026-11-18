# apvt — Apple Platform View Tester

`apvt` lets an AI agent (or you) see what an app's views really look like: the live view tree
of an app running in the **iOS Simulator** or of a **macOS app** — UIKit, AppKit and SwiftUI
views alike, with frames in points — and the layout mistakes in it. The app needs **no code
changes**: a small agent library is loaded into it at launch.

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
next: apvt query @14   # the node, its ancestors and metrics · apvt tree · apvt screenshot <file.png>
```

On the Mac the same report is about one window:

```text
$ apvt launch build/Debug/APVTMacSample.app -- -screen profile && apvt inspect
APVTMacSample (dev.apvt.macsample, pid 38447) · macOS 27.0.1 · window 1 "Profile card" 420x552pt @2x at (525,200)
6 errors, 0 warnings:
E wider-than-screen: @9 .padding (-34,32 488x520) is 488pt wide; the window is 420pt; 5 visible element(s) end up past the edge. Fixed-size children: @16 .fixedSize 334pt
E offscreen: @19 Button #follow label:"Follow" (412,80 10x24) is cut off: 2pt past the right edge
…
```

## Install

Requires macOS 15+, Xcode (with the iOS Simulator platform for simulator apps), Swift 6.2+ (the
agent uses `@section`).

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

The binary carries the agent's sources and builds the agent for the simulator, or for macOS,
on first use (a few seconds, cached under `~/Library/Caches/apvt/`).

## Use

```bash
apvt launch path/to/MyApp.app   # start the app with the agent: a macOS .app, a simulator .app,
                                # or the bundle id of an app installed on the booted simulator
apvt inspect               # issues on the current screen (macOS: in the key window)
apvt query @14             # one node: ancestors, text metrics, issues
apvt tree                  # the view tree with frames
apvt assert '#follow' --visible --inside screen --min-width 44
apvt screenshot shot.png   # issues outlined and labelled @N
apvt rules                 # what inspect checks and how to fix each
apvt type "Buy eggs" --submit   # type into the focused text field (tap it first)
apvt launch-env            # env vars that make an Xcode-launched app load the agent
apvt status                # simulators, and the apps (simulator and macOS) that have the agent
```

`apvt launch` terminates a running instance first, so the app always starts with the current
agent, and waits until the agent answers (`--wait`, 15 s by default). Arguments after `--` go to
the app: `apvt launch MyApp.app -- -screen profile`.

### iOS Simulator

`apvt launch` runs `apvt setup` on the simulator when it has not been (once per simulator boot),
installs the `.app` when given one, and launches it. After `apvt setup`, apps launched with
`xcrun simctl launch` or from the home screen have the agent too (not Xcode's Run: see below).
`apvt teardown` undoes it.

### macOS

`apvt launch path/to/MyApp.app` takes a built, native AppKit or SwiftUI app (a Debug build as
Xcode makes it; not Catalyst). There is nothing to set up beforehand.

- **One window at a time**: the key window (a sheet while one is up), or `--window <number|title>`;
  the header lists the others. Frames are points from the window's top-left corner, title bar
  included, and `offscreen` / `wider-than-screen` measure against the window. Screenshots are of
  that window.
- **Code signing**: with the Hardened Runtime, the app only loads libraries of its own team, so
  apvt signs its agent with the certificate of the app's team from your keychain (`--identity`
  picks another). An app that can never load the agent — Hardened Runtime without
  `get-task-allow`, a release build — is not launched; the error says how to build one that
  can. apvt never re-signs your app.
- **App Sandbox**: supported. apvt gives the app a sandbox extension for `/tmp/apvt-<uid>/`, and
  the agent answers over pipes there instead of a socket.
- `unsafe-area` and `small-target` are off (`--rule` turns one on); `apvt rules --platform macos`
  shows the wording used on the Mac.

With an agent in a simulator app and in a macOS app at once, name one: `--app <bundle-id>` or
`--platform ios-simulator|macos`.

### Apps launched by Xcode (Run, Xcode MCP)

In the simulator, Xcode replaces launchd's `DYLD_INSERT_LIBRARIES`, so an app it launches has no
agent. Give that launch the variables `apvt launch-env` prints instead — for example as the `environmentVariables`
of Xcode MCP's `DeviceInteractionInstallAndRun` (`apvt launch-env --xcode` adds
`"$(inherited)": ""` to keep the scheme's own; `--compact` prints it on one line for a shell wrapper), or in the scheme's Run > Environment Variables. The app then runs under Xcode, with its
console and `GetConsoleOutput`, and answers apvt.

For a macOS app, `apvt launch-env path/to/MyApp.app` prints the variables for that app (the
agent signed as the app needs it and, for a sandboxed app, a sandbox extension token that is
valid until the Mac restarts). Put them into the scheme's Run > Environment Variables: Xcode
MCP's `RunProject` takes no environment. `--shell` prints quoted `KEY=value` lines.

### Typing

`apvt type <text>` inserts text into whatever has keyboard focus, through `UIKeyInput` (macOS:
`NSTextInputClient`) as the keyboard does, so SwiftUI bindings, delegates and `.onChange` observe it. `--replace` clears the
field first; `--submit` presses Return (`textFieldShouldReturn`, `.onSubmit`). Tools that drive
the simulator by taps (Xcode MCP's `DeviceInteractionSynthesize`) can then tap the field and let
apvt type, instead of tapping keys one by one.

Every command takes `--json`, `--device <name|udid>`, `--app <bundle-id>`, `--platform` and
`--wait <seconds>` (wait for an app launched some other way); `inspect` and `tree` take `--save file.json`, and any command can
read it back with `--snapshot file.json`. Without `--app`, apvt picks the one app whose agent
answers — in a simulator only the foreground app does, iOS suspends the others. `inspect` exits 1 when it finds
an error (`--fail-on warning|never` to change). Errors say what happened, why, and the command
that fixes it.

### What `inspect` checks

| rule | finds |
|---|---|
| `offscreen` | content cut off by, or beyond, the screen edge — the window's on macOS (not inside a scroll view) |
| `wider-than-screen` | a container wider than the screen (macOS: the window), with the fixed-size children that pushed it |
| `clipped` | content hidden by an ancestor that clips (`clipsToBounds`, `.clipped()`) |
| `truncated` | text that needs more room than its frame (measured with its font) |
| `squeezed` | text narrower than its longest word, controls collapsed to zero |
| `overlap` | texts / controls drawn on top of each other; an error when a text crosses a control's edge, a warning when it sits wholly inside one (a badge may be meant) |
| `unsafe-area` | text / controls under the status bar, Dynamic Island or home indicator (iOS) |
| `small-target` | controls smaller than 24x24pt (off on macOS unless `--rule small-target`) |
| `ambiguous-layout` | UIKit / AppKit views whose Auto Layout frame is ambiguous |
| `broken-constraint` | `Unable to simultaneously satisfy constraints`, with the conflicting set |

Contrast is not checked.

## How it works

- **Injection, macOS.** `apvt launch` opens the app with the agent in `DYLD_INSERT_LIBRARIES`
  (`open -n … --env`), signed for the app's team when its code signature asks for that.
- **Injection, iOS Simulator.** `apvt setup` sets `DYLD_INSERT_LIBRARIES` in the simulator's launchd to a tiny
  loader; in user-installed apps only, the loader `dlopen`s the agent. Apps launched with
  `xcrun simctl launch` or from the home screen get it. **Xcode's Run does not**: it passes its
  own `DYLD_INSERT_LIBRARIES` (Main Thread Checker), which replaces launchd's, and loading the agent
  through Xcode's debugger did not work (see the docs). Build/run with Xcode, then relaunch with
  `xcrun simctl launch <udid> <bundle-id>` — or pass `apvt launch-env`'s variables to Xcode's
  launch, which puts the agent itself into `DYLD_INSERT_LIBRARIES`.
- **SwiftUI.** The agent sets `SWIFTUI_VIEW_DEBUG` before SwiftUI builds its first view graph and
  reads each hosting view's `makeViewDebugData()`: SwiftUI's own layout (types, frames,
  modifiers, texts). ScrollView content is mapped through the UIScrollView SwiftUI made for it.
  On macOS that data is sometimes an error for the whole window; the agent then reads the tree
  unserialized, inside SwiftUI's update lock, and serializes it in parts.
- **Agent ↔ host.** A unix socket under `/tmp/apvt-<uid>/` (the simulator shares the host's
  filesystem); named pipes there for a sandboxed macOS app. The agent collects; the host judges.
- **Platforms.** `Platform` (`Sources/APVTCore/Platform/Platform.swift`) is the seam: injection,
  discovery and screenshots per platform; analysis, selectors, assertions and output are shared.
  The snapshot model (`Sources/APVTModel`) has nothing iOS-specific.

Measurements behind these choices: [docs/ios-simulator.md](docs/ios-simulator.md),
[docs/macos.md](docs/macos.md).

## Layout

```
Sources/APVTModel/   snapshot model, wire protocol, SwiftUI debug-data parser (host + agent)
Sources/APVTCore/    host: platforms, agent build, analysis, selectors, assertions, output
Sources/apvt/        command line
Agent/Shared/        in-app agent: entry point, server, identifier matching (every platform)
Agent/iOS/           in-app agent, UIKit side (built for the simulator by the host)
Agent/macOS/         in-app agent, AppKit side (built for macOS by the host)
Agent/Loader/        launchd loader (iOS Simulator)
Plugins/, Tools/     embed Agent/ + APVTModel sources into the apvt binary
Examples/APVTSample/ sample iOS app with planted layout mistakes (and clean screens)
Examples/APVTMacSample/ the same for macOS
Tests/APVTCoreTests/ tests on snapshots recorded from the sample app
```

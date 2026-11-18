# macOS: what was measured, and what it decided

Measured on macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple silicon, System Integrity Protection on
(2026-11). Native AppKit and SwiftUI apps only: Catalyst and iOS apps on the Mac, release builds
and other people's apps were left out. Nothing here was measured on an older macOS or on Intel.

## Getting into the app

There is no launchd to set up, as there is in a simulator: the agent goes into the launch itself.

| candidate | measured | decision |
|---|---|---|
| `open -n App.app --env DYLD_INSERT_LIBRARIES=…` | LaunchServices passes the variable on; the agent loads; arguments go after `--args`, output to `--stdout` / `--stderr` | **`apvt launch App.app`** |
| running the executable directly with the variable in the environment | loads too, sandboxed apps included | what Xcode's Run amounts to: **`apvt launch-env App.app`** |
| a loader in every process (`launchctl setenv` for the user's session) | not tried: it would reach every app the user starts | no `apvt setup` on macOS |
| attaching to a running app | not tried: `task_for_pid` needs more than the injection does | `apvt launch` restarts the app instead |

A running instance is terminated first (`NSRunningApplication.terminate`, then `SIGTERM`, then
`SIGKILL` after 3 s), so the one instance is the one with the current agent. `open -n` returns at
once; `apvt launch` then waits for the agent's announcement in `/tmp/apvt-<uid>/` and a ping
(about 2.3 s for the sample, of which 1.5 s is waiting for the first window to be built).

### What the code signature allows

dyld drops `DYLD_INSERT_LIBRARIES` for some apps, and library validation refuses some libraries.
Variants of one app, launched with an ad-hoc signed agent unless noted:

| app is signed | agent | result |
|---|---|---|
| ad hoc, no Hardened Runtime (also with `get-task-allow`, with the sandbox) | ad hoc | loads |
| ad hoc, `ENABLE_HARDENED_RUNTIME=YES`, built by Xcode as "Sign to Run Locally" | ad hoc | loads: Xcode leaves the `runtime` flag off an ad-hoc Debug signature (`flags=0x2(adhoc)`) |
| Hardened Runtime, no `get-task-allow`, no `allow-dyld-environment-variables` (a release build) | any | dyld ignores the variable: never loads |
| Hardened Runtime + `get-task-allow` or `allow-dyld-environment-variables`, ad hoc | ad hoc | refused by library validation (no team to match) |
| the same + `disable-library-validation` | ad hoc | loads |
| Hardened Runtime + `get-task-allow`, signed by a development certificate (Xcode Debug with a team), sandboxed | ad hoc | refused by library validation |
| the same | signed with a certificate of the app's team | loads |

So `CodeSignature` reads `codesign -dv` and the entitlements before anything is launched:

- an app that can never load the agent is **not launched**; the error names the entitlement and
  the build setting. apvt never re-signs the app.
- when library validation applies, the agent is copied and signed (`codesign -f -s <hash>
  --timestamp=none`) with the identity from `security find-identity -v -p codesigning` whose
  team is the app's — the certificate the app itself was signed with first; `--identity` picks
  another. The signed copy is kept per team (`~/Library/Caches/apvt/macos/current/signed/<team>/`).
- otherwise the linker's ad-hoc signature is used as it is.

The agent is built as a universal dylib (`arm64` + `x86_64`, minimum macOS 14) with
`xcrun --sdk macosx swiftc -emit-library`, from the same embedded sources as the simulator's.

## Talking to the app

Not sandboxed: the unix socket under `/tmp/apvt-<uid>/`, as in the simulator.

Sandboxed (`com.apple.security.app-sandbox`, which Xcode's macOS app template turns on):

| candidate | measured | decision |
|---|---|---|
| `bind` a socket in `/tmp/apvt-<uid>/` | denied by the sandbox | — |
| a socket in the app's container | binds, but the host has to reach into `~/Library/Containers/<id>/`: a privacy prompt for the terminal | no |
| `sandbox_extension_issue_file("com.apple.app-sandbox.read-write", "/private/tmp/apvt-<uid>")` in apvt, the token in `APVT_SANDBOX_TOKEN`, `sandbox_extension_consume` in the agent | files and named pipes there work; `bind` is still denied | **pipes** |

The agent tries the socket; when that fails it consumes the token, makes two FIFOs
(`<pid>.in`, `<pid>.out`) and announces `transport: pipe`. One request at a time: the host holds
`flock` on `<pid>.lock` while it writes a request and reads the answer. The extension is for the real path
(`/tmp` is a link to `/private/tmp`).

A token is not tied to the process that issued it: one printed by `apvt launch-env` still worked
in an app started after apvt had exited. It stops working when the Mac restarts.

## Windows

- A macOS app has several windows and no screen of its own, so every request is about **one
  window**: the key window (a sheet is the key window while it is up), the main window's sheet
  or the main window when the app is in the background, else the frontmost. `--window` takes a
  number (1 is the frontmost, in `NSWindow.windowNumbers` order) or a title (exact, else
  containing; an ambiguous or unknown one is an error listing the windows). The other visible
  windows are listed in the header of every report.
- Sheets, popovers, menus and panels are windows of their own (`kind` in the listing). Only
  sheets were exercised.
- Frames are points from the window's **top-left corner, title bar included**: the frame view
  (`NSThemeFrame`) is the root, so a click point on screen is the header's `at (x,y)` plus the
  frame's center. AppKit views that are not flipped are converted.
- The snapshot's `screen` is the window's size with no safe area; `offscreen` and
  `wider-than-screen` therefore measure against the window, and their wording says "window".
  `unsafe-area` has nothing to check and `small-target` is a touch rule: both are off unless
  `--rule` names them.
- Screenshots are taken by the agent: `CGWindowListCreateImage` for the app's own window needs
  no Screen Recording permission (`CGPreflightScreenCaptureAccess` false, image returned, in a
  sandboxed app too). The function is hidden from Swift in the SDK but still exported, so it is
  looked up with `dlsym`; `cacheDisplay(in:to:)` is the fallback. With `boundsIgnoreFraming` the
  image has no shadow: pixels = points × scale from the same top-left corner.

## SwiftUI's own layout

`NSHostingView` answers `makeViewDebugData` as `_UIHostingView` does, with `SWIFTUI_VIEW_DEBUG`
set before the first view graph. What differs from iOS:

- **The whole answer can be an error.** For some content `makeViewDebugData` returns
  `{"error": "The data couldn’t be written because it isn’t in the correct format."}` instead of
  the tree: a Picker or a Button in a grouped Form, a NavigationSplitView. One value SwiftUI's
  encoder cannot write spoils all of it.
- `NSHostingView._viewDebugData()` (public, underscored) returns the same tree unserialized, and
  `_ViewDebug.serializedData` serializes any part of it. The agent serializes the tree in parts:
  what serializes is taken as it is; a node that does not is rebuilt from its type, position
  and size (read with `Mirror`), and its children are tried on their own.
- `_viewDebugData()` **traps without SwiftUI's update lock** on a value it has to compute
  (`AGAttribute.syncMainIfReferences`, with a Picker in a grouped Form). `makeViewDebugData` is
  `UpdateGroup.main.ensure { … }`, that is `begin()`, the read, `end()` (from its disassembly).
  SwiftUICore exports `UpdateGroup.main`, `begin()` and `end()`; the agent looks the three up
  with `dlsym` and calls them around the read. Where they are missing it does not read at all,
  and the snapshot says that the hosting view's SwiftUI layout could not be read.
- Controls are AppKit's and mostly **named on the frameless chain** between two framed nodes:
  `PrimitiveSystemTextField` (TextField and SecureField), `MenuButtonInteractionModifier`
  (a menu-style Picker and a Menu alike: `PopUpButton`), `_SegmentedControl`,
  `AppKitDatePicker`, `BridgedColorPicker`, `AppKitTextEditor`. `Switch` and `AppKitStepper`
  have frames. The parser gives the framed wrapper the control's name and role, and marks what
  AppKit builds inside a bridged control as internal.
- A Picker and a Menu lay out **copies of their label only to size themselves**, under
  `HiddenForLayoutModifier`; other hidden content carries `_OpacityEffect(opacity: 0)`. Both are
  read (`hidden`, the node's alpha), or the copies show up as overlapping texts.
- A Text's `StyledTextContentView` (a frameless descendant) holds what SwiftUI resolved: the
  attributed string with the exact `NSFont` (`".SFNS-Regular 13.00 pt."`), `lineLimit` and
  `minScaleFactor`. On macOS the font for measuring comes from there (a `.`-prefixed system
  font name is turned back into `systemFont(ofSize:weight:)`), so `truncated` does not have to
  guess. UIKit's description has only family, weight class and size ("bold" covers semibold),
  which measured worse than the text-style guess: iOS keeps guessing, and only takes
  `lineLimit` and `minScaleFactor` from it.
- An icon-only label (a toolbar's "Hide Sidebar") keeps its title as a text with an empty frame;
  that is not `squeezed`.
- A List's rows that are scrolled out keep their frames. Overlaps are judged on what is drawn:
  a node's frame cut to the scrolling ancestors' frames. The scroll view's own clip view is not
  a clipping ancestor for `clipped`.
- A hosted AppKit view inside a SwiftUI control (the `NSTextView` of a TextEditor, scrollers)
  is the control, not something on top of it.
- Parsing recurses deeply (a NavigationSplitView is more than a thousand levels of modifiers):
  on the agent it runs on the main thread's 8 MB stack; elsewhere the parser starts a thread
  with a 64 MB stack.

Controls checked to report nothing when laid out correctly: Form (grouped and plain) with
TextField, SecureField, Toggle, Picker (menu, segmented, inline), Stepper, Slider, DatePicker,
ColorPicker; List, Table, ScrollView, NavigationSplitView, NavigationStack, TabView, toolbars,
GroupBox, DisclosureGroup, Menu, ProgressView, TextEditor, Label, Link.

## AppKit

- `-[NSView engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:]` is the selector UIKit
  has; the agent wraps it the same way. A conflict is the system's only when every view in it
  is AppKit's own (title bar, toolbar, alerts, panels, menus); the frame view around the
  content does not make what it contains the system's.
- `hasAmbiguousLayout` per Auto Layout view; `NSTextField` / `NSButton` texts are measured with
  their own fonts.
- Identifiers: `accessibilityIdentifier()` of the AppKit views. SwiftUI answers accessibility
  through a private bridge that walking `NSAccessibility` in the process does not reach (AppKit
  identifiers only), so the agent asks the accessibility API about its own process
  (`AXUIElementCreateApplication(getpid())`, one `AXUIElementCopyMultipleAttributeValues` per
  element) and matches the elements to nodes by frame, as on iOS. An app asking about itself
  needs no Accessibility permission, and it works in the sandbox. AppKit's generated
  identifiers (`_NS:…`) are ignored.

## Typing

`apvt type` inserts through `NSTextInputClient` on the window's first responder (the field
editor for a text field), so bindings and `controlTextDidChange` see it. `--replace` selects all
first; `--submit` is `doCommand(by: insertNewline:)`, which ends editing and sends the action:
measured with a SwiftUI TextField, `.onSubmit` ran and the bound text was the typed one. Nothing
focused is an error that says to click the field first.

## Xcode's Run

| launch | measured |
|---|---|
| the app's executable run directly with the variables of `apvt launch-env App.app --shell`, 3 s after apvt exited | agent `loaded by env`, sandboxed, pipes; `inspect` answers |
| Xcode's Run (through Xcode MCP's `RunProject`, debugger attached), the three variables in the scheme's Run > Environment Variables, a sandboxed Debug app | the agent answers under the debugger; `inspect` answers |

Unlike the simulator, Xcode's own `DYLD_INSERT_LIBRARIES` did not get in the way here. Xcode
MCP's `RunProject` takes no environment (only the workspace and `attachDebugger`), so for a
macOS app the scheme is where the variables go. `--shell` quotes values: the sandbox token
contains `;`.

## Left out, or not measured

- macOS before 27, and Intel Macs. The agent is built for both architectures, but only arm64 ran.
- The update-lock symbols are SwiftUICore's, not API: another SwiftUI may not have them, and
  then the screens whose debug data is an error are not read (apvt says so).
- A rebuilt node has its type, position and size, and the values `Mirror` shows: a text inside
  a node that does not serialize may lack its font.
- `PopUpButton` is both Picker(.menu) and Menu; a SecureField reads as `TextField`; a toolbar
  button may have no label.
- Popovers and menus as windows; windows on another Space; full screen.
- Apps not built by the user: no `get-task-allow`, so dyld never loads the agent.

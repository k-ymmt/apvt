# iOS Simulator: what was measured, and what it decided

Measured on Xcode 27.1 beta, macOS 27, iPhone 17 Pro simulator, iOS 27.0 (2026-10-06/07).
Reference: vlmkit's iOS Simulator work (`docs/ios-simulator.md` there) used launch-time
injection and an Objective-C agent; apvt keeps the injection idea and measures the rest again.

## Getting into the app

| candidate | measured | decision |
|---|---|---|
| `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` + `simctl launch` | loads into any app, Apple's included | works, but only for launches apvt makes |
| `simctl spawn <udid> launchctl setenv DYLD_INSERT_LIBRARIES` | every process launched afterwards loads it (apps and daemons) | **`apvt setup`**, with a loader that acts only in user apps |
| a per-launch `DYLD_INSERT_LIBRARIES` (what Xcode's Main Thread Checker passes) | replaces launchd's value: the loader is not loaded | Xcode Run needs another way |
| `lldb` attach + `expr dlopen(...)` on a running Debug build | works (3–11 s); refused while Xcode's debugger is attached | used inside Xcode instead: |
| auto-continuing `UIApplicationMain` breakpoint that `dlopen`s, set before the target exists (as `~/.lldbinit-Xcode` is) | loads the agent under a debugger with the Main Thread Checker injected; SwiftUI debug data complete | **`apvt setup --xcode`** |

LLDB breakpoint names may not contain `-` (`apvt_agent`, not `apvt-agent`).

The loader (`Agent/Loader`) links only libSystem and the Swift runtime; daemons load it and
return. It checks `_NSGetExecutablePath` for `/data/Containers/Bundle/Application/` (image 0 is
the inserted library itself, not the executable).

## Swift only, no Objective-C

`@used @section("__DATA,__mod_init_func") let f: @convention(c) () -> Void = { … }` is a working
dylib constructor in Swift 6.4 (no experimental flag; the linker turns it into `__init_offsets`).
Private API is reached with `perform(NSSelectorFromString(…))`, swizzling with
`method_setImplementation` + `imp_implementationWithBlock`. The agent has no Objective-C.

## SwiftUI's own layout

`_UIHostingView` (and every hosting view subclass) answers `makeViewDebugData` with JSON: nodes
with properties by id — 0 type, 1 value, 2 transform, 3 position, 4 size — position and size
being the layout frame in the hosting view's coordinates.

- It is empty unless `SWIFTUI_VIEW_DEBUG` is set when the view graph is created. The value is a
  bit mask (`1` gives types only; `31` gives frames). Writing `_ViewDebug.properties` (a local
  symbol in SwiftUICore, reachable from LLDB) afterwards does **not** reach existing graphs,
  even after a relayout: the agent must be in before the first graph, hence launch-time loading.
- Cost: ~1–3 s and ~1 MB for a root hosting view, ~0.1–0.2 MB per screen; a snapshot of a
  sample screen takes 4–5 s end to end.
- Children are listed last-first. Most nodes are modifiers without a frame; apvt keeps the
  framed ones and folds the modifiers in as `[clipped, offset, frame(width: 150), …]`.
- A `Button` is the framed node above a `ButtonActionModifier`; a `Text` inside a collapsed
  button label has no frame of its own (kept as `textNotLaidOut` on the nearest framed node).
- `ScrollView` content is recorded in its own coordinate space, starting below a frameless
  `SystemScrollView` node. The UIScrollView SwiftUI creates for it (`HostingScrollView`) has the
  same content size and converts those coordinates to the screen.
- `.offset` leaves the layout frame where it was; descendants carry the moved frame.
- Accessibility identifiers are not in the debug data. They come from the accessibility
  elements (`ApplicationAccessibilityEnabled` on the device, which `apvt setup` sets) matched by
  frame; an identifier set on a container reaches every element inside, so a group of elements
  with one identifier names their lowest common ancestor.
- Texts carry their `LocalizedStringKey`, not the shown string: the agent localizes with the
  app's bundles and puts interpolated arguments (`value(25, nil)`) back.
- Fonts are serialized only partly (a `.bold()` font loses its style; list section fonts are not
  there at all). Without a declared font the agent picks the text style under which the string,
  wrapped at the frame's width, is as tall as the frame; issues relying on a guessed font are
  warnings.

## UIKit

- `-[UIView engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:]` is called before every
  break; the agent wraps it and records the conflict. Conflicts inside UIKit's own views
  (alerts, the keyboard's prediction bar — seen in Laperm's "New Vault" alert) are marked
  `system` and left out of the issues.
- `hasAmbiguousLayout` per Auto Layout view.
- A control other than a button or text field is a leaf: a `UISwitch` holds a 630pt-wide image view.
- SwiftUI's List cells are private UIKit classes (`…ListCollectionViewCell`); being private hides
  their UIKit insides, not the SwiftUI content of their hosting views.

## Environment

- `xcrun simctl bootstatus <udid> -b` boots an iOS 27.0 device headless in ~6 s.
- `simctl io <udid> screenshot` is at the screen scale (1206x2622 for 402x874pt).
- The launchd environment lasts until the simulator shuts down.

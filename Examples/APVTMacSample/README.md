# APVTMacSample

The macOS counterpart of `Examples/APVTSample`: screens with the layout mistakes AI agents tend
to make, plus screens that are right, each in a fixed 420x520pt window. Open one directly with
`-screen <name>`: `apvt launch path/to/APVTMacSample.app -- -screen pricing`.

| screen | planted | apvt reports |
|---|---|---|
| profile | `.fixedSize()` on a long name pushes the card past the window; the Follow button is squeezed to 0pt | `wider-than-screen` (names the `.fixedSize`), `squeezed`, `offscreen` ×4 |
| pricing | three `.frame(width: 150)` columns in a 420pt window | `wider-than-screen` (names the three frames), `offscreen` ×2 |
| badge | a badge moved onto the title with `.offset`; a description in `.frame(height: 16)` + `.clipped()` | `overlap`, `truncated` |
| header | a one-line title next to `.fixedSize()` buttons | `truncated` |
| form | a hint sharing a row with two `.fixedSize()` buttons, left narrower than its longest word (also low-contrast, which apvt does not check) | `squeezed` |
| appkit | fixed 440pt label, single-line label in 160pt, label outside a clipping card, overlapping buttons, conflicting widths | `offscreen`, `truncated`, `clipped`, `overlap`, `broken-constraint` |
| settings | — (a grouped Form) | nothing |
| feed | — (vertical and horizontal ScrollViews) | nothing |

The iOS sample's header and form plant `unsafe-area` and `small-target`; those rules are off on
macOS, so the two screens here plant what a Mac window gets wrong instead.

`-inspector YES` also opens a second window and `-sheet YES` a sheet, for `--window`:

```bash
apvt launch path/to/APVTMacSample.app -- -screen profile -inspector YES
apvt inspect --window "Profile card"
```

The app is sandboxed and signed to run locally, as Xcode's macOS app template makes one, so its
agent answers over pipes. `project.yml` generates the Xcode project: `xcodegen generate`.

# APVTSample

Screens with the layout mistakes AI agents tend to make, plus screens that are right. Open one
directly with `-screen <name>`: `xcrun simctl launch booted dev.apvt.sample -screen pricing`.

| screen | planted | apvt reports |
|---|---|---|
| profile | `.fixedSize()` on a long name pushes the card past the screen; the Follow button is squeezed to 0pt | `wider-than-screen` (names the `.fixedSize`), `squeezed`, `offscreen` ×2 |
| pricing | three `.frame(width: 150)` columns in a 402pt screen | `wider-than-screen` (names the three frames), `offscreen` ×2 |
| badge | a badge moved onto the title with `.offset`; a description in `.frame(height: 20)` | `overlap`, `truncated` |
| header | a header title under the status bar (`.ignoresSafeArea` on the content) | `unsafe-area` |
| form | a 14x14 help button (also low-contrast text, which apvt does not check) | `small-target` |
| uikit | fixed 420pt label, single-line label in 160pt, label outside a clipping card, overlapping buttons, conflicting widths | `offscreen`, `truncated`, `clipped`, `overlap`, `broken-constraint` |
| settings | — (a Form) | nothing |
| feed | — (vertical and horizontal ScrollViews) | nothing |

`project.yml` generates the Xcode project: `xcodegen generate`.

# Score touch and techniques — 2026-11-18

Latest product commit: `822e69260f4446f05700215cb7b80ea9c2c5a93d`, 0.25.78 (122). See `docs/reviews/2026-11-17-editor-touch-techniques.md` for scope and compatibility boundaries.

- Touch scroll, cancelled pointer/compatibility click and navigation-pad drags no longer move or extend selection. Category switching and save replies retain manual scroll position. Single taps select TAB frets and staff note heads. Explicit navigation still reveals the selected position.
- Insertion has a persistent left-side entry and separate before/after note/rest controls. New notes show an explicit unknown fret until entered, preserving the original note.
- Applied techniques have individual edit/remove actions. Bend/whammy panels show a graph, presets and numeric point controls. Each point edit checks GP round-trip compatibility before changing the draft.
- Browser captures inspected: `output/editor-touch-techniques-20261117/editor-mini.png`, `editor-portrait.png`, `curve-editor.png`, `applied-techniques.png`. Landscape 1133 × 744, portrait 744 × 1133 CSS px, 2× scale. Panels and controls fit; the two-line applied-techniques sidebar label is readable but not a pixel-exact Reflow match.
- Native capture `native-editor-previous.png` from passing CI 44093630868 was inspected. It covers b8d4bbf, including the new front insertion and technique removal, not the final staff-tap follow-up. The latest full CI is blocked during upstream dependency download; local browser success does not replace that check. No physical-device install or validation this time, per user request.

Status: interaction and local visual checks passed; final full iOS verification pending upstream dependency availability.

---

# Previous Reflow-style TAB input — 2026-11-17

Source visual truth: user screenshot `C:/Users/sadada/AppData/Local/Temp/codex-clipboard-93740c0a-5f3d-4261-b06a-927769b95565.png` (2266 × 1488). Private image is not committed. Official interaction references: [entering notes](https://reflow.app/help/writing-tab/entering-notes/), [beats](https://reflow.app/help/writing-tab/beats/), [effects](https://reflow.app/help/techniques/effects/), [moving around](https://reflow.app/help/writing-tab/moving-around/).

## Captures and comparison

Implementation: `output/reflow-controls-20261117/editor-mini.png`, 1133 × 744 CSS px, deviceScaleFactor 2, 2266 × 1488 pixels. Source and implementation normalized to 1133 × 744 each in `comparison.png`; lower-control crops aligned in `controls-comparison.png`. Portrait: 744 × 1133 CSS px, 2×. These are temporary local evidence; native CI attachments are retained with the run. Synthetic score content, not the user's music.

State: effect category open, second-string fret selected, playback stopped. Full-view and focused bottom controls compared together; portrait also inspected.

## Findings and iterations

- P1 resolved: old giant technique form replaced by eight persistent categories with horizontally scrolling buttons above. H/P, slides, vibrato, palm mute, articulation, harmonics, dynamics and bend presets apply immediately; toggled state remains visible. Only custom parameters use a sheet.
- P1 resolved: insertion now explicitly appears under Beat, selects the new empty beat, and leaves it ready for fret entry. Keypad delete first removes the note, then the empty beat. Split, grouped tuplets and undo preserve note content. Cursor crosses bars; digit entry is not time-limited; Shift selects beats for batch effects and copy.
- P2 resolved: initial browser fixture served SVG as generic binary, producing broken icon captures. Server MIME corrected; browser and native tests assert every visible bundled icon loaded. Assets are unmodified licensed Lucide SVGs; music symbols use existing Bravura.
- P2 resolved: portrait category hint overlapped transport. Dock raised to 310 px above bottom; post-fix portrait capture shows separated controls and the selected note above them.

## Fidelity surfaces

- Typography: native system UI type, 11–14 px control labels and 21 px keypad; Bravura musical symbols. No copied proprietary icon designs. Fret/score engraving uses the existing alphaTab renderer.
- Spacing/layout: dark floating top actions, left editing modes, left thumb navigation, center eight categories with tool strip, right four-column keypad and transport. Minimum primary controls 44 px. Horizontal strip scroll is intentional and does not overflow the page. Portrait rearranges the tool strip above the lower controls.
- Colors: charcoal floating controls, white score, orange editing mode, cyan note selection and active techniques. Selected range is visibly highlighted across all six strings.
- Assets: sharp SVG UI icons and music font; no raster placeholders. No private reference image or third-party score redistributed.
- Copy: Chinese category labels match the supplied workflow. Explicit H/P origin vs tie destination hints. Numerical TAB keypad stays numeric; the screenshot's accidental keys belong to Reflow's staff-entry mode, which is outside this TAB-focused change.

## Validation

Browser tests cover actual score hit targets, slow two-digit fret entry, add/insert/undo/redo, direct technique toggle and bend, two-stage deletion, range selection, thumb drag, local blank bars, audible soundfont output, immediate pause/stop, replay after editing, save bridge, landscape/portrait and loaded icons. Uncaught JavaScript errors: none. State tests cover chord preservation, wrapping strings, cross-bar navigation, end-of-score extension, atomic invalid tuplets, split, range effects and undo. Existing 127 technique round trips retained.

Intentional differences: concise text labels accompany or replace specialized technique symbols; the standard staff is an engraved view and TAB is the input surface. No claim of complete Reflow feature parity (multiple voices, engraving design and staff accidental entry are not added). Existing practice playback, OCR and single-save identity are unchanged.

Native CI 44070733742 passed 351 unit and 5 UI tests. The dedicated WKWebView capture `native-editor.png` is 2266 × 1440 (status area excluded), showing the active P.M. control, engraved chord, keypad and saved incomplete draft. The full-device flow capture is 1488 × 2266 with landscape content, rotated 90° only for review; it confirms recognition-to-editor, audition and same-file save. These captures were inspected alongside the browser comparison. Native assertions verify all SVG assets loaded. Physical iPad mini 6 installed 0.25.77 (121) and independently launched; before/after/post-launch fingerprints match. Details in `docs/releases/0.25.77.md`.

final result: passed

# Reflow-style TAB input — 2026-11-17

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

Browser tests cover actual score hit targets, slow two-digit fret entry, add/insert/undo/redo, direct technique toggle and bend, two-stage deletion, range selection, thumb drag, local blank bars, audible soundfont output, immediate pause/stop, replay after editing, save bridge, landscape/portrait and loaded icons. Console errors: none. State tests cover chord preservation, wrapping strings, cross-bar navigation, end-of-score extension, atomic invalid tuplets, split, range effects and undo. Existing 127 technique round trips retained.

Intentional differences: concise text labels accompany or replace specialized technique symbols; the standard staff is an engraved view and TAB is the input surface. No claim of complete Reflow feature parity (multiple voices, engraving design and staff accidental entry are not added). Existing practice playback, OCR and single-save identity are unchanged.

Native CI and physical-device release checks are recorded in the release note after completion.

final result: passed

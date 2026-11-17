# Score editor design QA — 2026-11-17

Reference: user-provided Reflow screenshot `codex-clipboard-cf2e164a-fa3f-4dcf-8821-1fe16054ef3f.png` (2266 × 1488). Implementation captured at the matching 1133 × 744 CSS-pixel viewport, 2× scale: local `output/score-editor-20261117/editor-mini.png`. The private reference is not committed. Synthetic notes are used instead of copying the reference music.

## Visual comparison

- Full white staff + TAB score replaces the cell grid. Selected TAB string/fret is highlighted cyan; title, tempo, technique marks and multiple systems remain engraved.
- Floating dark controls follow the reference's arrangement: return/undo/redo/save at top left; source/settings/view/zoom at top right; editing categories on the left; navigation at bottom left; rhythm actions at bottom; numeric keypad and transport at bottom right.
- Uses native system text labels rather than unfamiliar icon-only buttons. Main controls have 44-pixel targets. Note targets track actual engraved string positions; zoom and string/beat navigation provide precise alternatives.
- Eight-bar synthetic score checked visually at the reference dimensions. No page-level horizontal overflow. Bottom controls intentionally float above the scrolling page, as in the reference; reading mode hides editing controls. The last system can scroll above the controls.
- Intentional differences: original RiffLoop branding/typography and concise Chinese labels; no copied reference title, score, watermark or decorative imagery. Technique categories are in a scrollable dialog rather than permanently covering the page.

## Interaction evidence

Real Chromium/alphaTab integration passed: click TAB string 2, enter fret 13, insert rest, undo/redo, palm mute and full bend, insert local blank bars, load bundled SF3, play, pause, resume, stop, edit/reload MIDI and play again. Pause/stop mute the local audio gate immediately. MIDI position remains fixed within integer rounding; stop returns to the first tick. Single Save bridge replaces separate draft/export buttons.

Native iPad simulator, persistence tests and device installation results are recorded in the release review once complete. Browser verification alone is not iPadOS audio-route or end-to-end device validation.

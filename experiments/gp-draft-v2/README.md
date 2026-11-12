# Independent new-draft rhythm experiment

This experiment creates a new GP7 score entirely in memory. It does not open or
edit existing GP files, overwrite files, connect to the iPad UI, or change the
practice player. It is not yet a product feature or an accuracy claim.

The version 2 input explicitly declares 4/4, standard six-string tuning (MIDI
40,45,50,55,59,64 from low to high), tempo, title and bars. A beat has exactly
`duration`, `dots`, and `notes`: durations are powers of two from 1 to 64;
`dots` is 0 or 1; and an empty notes array is a rest. Notes contain only
`string` (1 is high E) and `fret`. A chord may contain up to six notes on
different strings.

A triplet is an explicit group with ratio 3:2 and exactly three equal-duration,
undotted beats. Dotted triplet members, mixed-duration tuplets, other tuplets,
techniques, meter/tuning changes and existing-GP editing are intentionally
rejected. Unknown fields, sparse arrays, accessor properties, hidden keys and
symbol keys are rejected rather than discarded. Titles are limited to 256
Unicode code points. Each bar must
total exactly 3840 ticks, with 960 ticks per quarter note; incomplete or
overfilled bars cannot be exported.

As a temporary resource safeguard, a score may contain at most 64 bars, 512
flattened beats and 512 individual notes (including each note within a chord).
Inputs above any limit are rejected, never truncated. These limits are
conservative experimental bounds, not measurements of iPad mini 6 capacity.

The alphaTab exporter output is immediately re-imported and compared with the
input: meter, tempo, tuning, notes, chords, fret, pitch, rests, duration, dot,
triplet ratio and grouping, and every playback start and duration. Any mismatch
rejects the output. These checks cover the data model above, not rendering,
playing techniques or preservation of arbitrary GP content.

The synthetic new-score exporter currently emits one unmuted track with bank 0,
program 25, volume 15 and balance 8; read-back verifies these defaults as well
as its port and channel settings. This is an experimental export default, not
an instrument selection feature.

Run the synthetic regression with `node experiments/gp-draft-v2/test.cjs`.
The separate v1 editor and its saved data are not changed or upgraded. Node
synthetic round trips do not establish Guitar Pro, iPad WebKit, iPad mini 6
performance, or compatibility with arbitrary scores; those require independent
validation before integration.

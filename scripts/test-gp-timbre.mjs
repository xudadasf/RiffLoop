import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const at = createRequire(import.meta.url)('../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const source = readFileSync(new URL('../RiffLoop/Resources/GpWeb/riffloop-timbre.js', import.meta.url), 'utf8');
const scope = {};
new Function('window', source)(scope);
const timbre = scope.RiffLoopTimbre;
const track = (index, primary, secondary, percussion = false) => ({
    index, playbackInfo: { primaryChannel: primary, secondaryChannel: secondary },
    staves: [{ isPercussion: percussion }]
});

const score = { tracks: [track(0, 0, 1), track(1, 2, 3), track(2, 9, 9, true)] };
assert.equal(timbre.canChange(score, 0), true);
assert.equal(timbre.canChange(score, 2), false, 'Drums must retain their percussion bank');
assert.equal(timbre.canChange({ tracks: [track(0, 0, 1), track(1, 1, 2)] }, 0), false,
    'Shared channels must not cause a different track to change timbre');
assert.equal(timbre.canChange(score, 99), false);

const midi = new at.midi.MidiFile();
for (const event of [
    new at.midi.ControlChangeEvent(0, 0, 0, at.midi.ControllerType.BankSelectCoarse, 3),
    new at.midi.ProgramChangeEvent(0, 0, 0, 25),
    new at.midi.ProgramChangeEvent(0, 480, 1, 29),
    new at.midi.ProgramChangeEvent(1, 0, 2, 33),
    new at.midi.ProgramChangeEvent(2, 0, 9, 0),
    new at.midi.ProgramChangeEvent(0, 0, 15, 115),
    new at.midi.NoteOnEvent(0, 960, 0, 64, 90),
    new at.midi.TempoChangeEvent(0, 500000)
]) midi.addEvent(event);
const before = midi.events.map(e => ({...e}));
timbre.apply(midi, score, [[0, 30], [2, 27]], at);
const after = midi.events.map(e => ({...e}));
for (let i = 0; i < before.length; i++) {
    const event = before[i];
    if (event.track === 0 && [0, 1].includes(event.channel) && event.type === 192) {
        assert.deepEqual(after[i], {...event, program: 30}, 'Every program change on the selected track must use the selection');
    } else if (event.track === 0 && event.channel === 0 && event.type === 176 && event.controller === 0) {
        assert.deepEqual(after[i], {...event, value: 0}, 'Selected melodic track uses the bundled general MIDI bank');
    } else {
        assert.deepEqual(after[i], event, 'Other tracks, metronome, percussion, notes and timing remain unchanged');
    }
}

const shared = { tracks: [track(0, 0, 1), track(1, 1, 2)] };
const sharedMidi = new at.midi.MidiFile();
sharedMidi.addEvent(new at.midi.ProgramChangeEvent(0, 0, 0, 25));
timbre.apply(sharedMidi, shared, [[0, 30]], at);
assert.equal(sharedMidi.events[0].program, 25);

const fixture = new Uint8Array(readFileSync(new URL('../RiffLoopTests/Fixtures/transport.gp', import.meta.url)));
const originalScore = at.importer.ScoreLoader.loadScoreFromBytes(fixture);
const originalProgram = originalScore.tracks[0].playbackInfo.program;
const soundFont = new Uint8Array(readFileSync(new URL('../RiffLoop/Resources/GpWeb/soundfont/sonivox.sf3', import.meta.url)));
function render(selection) {
    const file = new at.midi.MidiFile();
    new at.midi.MidiFileGenerator(originalScore, new at.Settings(), new at.midi.AlphaSynthMidiFileHandler(file)).generate();
    const untouched = file.events.map(e => ({...e}));
    timbre.apply(file, originalScore, selection, at);
    const options = new at.synth.AudioExportOptions(); options.soundFonts = [soundFont];
    const renderer = at.synth.AlphaSynth.prototype.exportAudio.call(null, options, file, [], new Map());
    return { samples: renderer.render(1000).samples, events: file.events.map(e => ({...e})), untouched };
}
const original = render([]);
const clean = render([[0, 27]]);
const distorted = render([[0, 30]]);
assert.equal(originalScore.tracks[0].playbackInfo.program, originalProgram, 'The imported score model is not changed');
assert.deepEqual(original.events, original.untouched, 'Original sound leaves MIDI unchanged');
const different = (a, b) => a.reduce((n, sample, i) => n + Math.abs(sample - b[i]), 0);
assert.ok(different(clean.samples, distorted.samples) > 1, 'The real bundled synthesizer must produce different audio');
console.log('GP timbre: track isolation, percussion, timing and real soundfont synthesis passed');

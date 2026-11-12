"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const alphaTab = require("../../RiffLoop/Resources/GpWeb/alphaTab.min.js");
const { exportDraft, validate } = require("./draft-v2.cjs");
const v1 = require("../gp-draft-editor/draft-core.js");

const note = (string, fret) => ({ string, fret });
const beat = (duration, notes = [], dots = 0) => ({ duration, dots, notes });
const triplet = (...beats) => ({ tuplet: { numerator: 3, denominator: 2 }, beats });
const draft = {
    version: 2, title: "附点、三连音和和弦", tempo: 123,
    meter: { numerator: 4, denominator: 4 }, tuning: [40, 45, 50, 55, 59, 64],
    bars: [
        [beat(4, [note(1, 0), note(2, 1), note(3, 2)], 1), beat(8, [note(6, 3)]), beat(2)],
        [triplet(beat(8, [note(1, 12), note(2, 13)]), beat(8), beat(8, [note(1, 15)])), beat(2, [], 1)],
        [triplet(beat(8, [note(3, 0)]), beat(8, [note(3, 1)]), beat(8, [note(3, 2)])),
         triplet(beat(8, [note(3, 3)]), beat(8, [note(3, 4)]), beat(8, [note(3, 5)])), beat(2)],
    ],
};
const sharedFixture = JSON.parse(fs.readFileSync(path.join(__dirname, "../../RiffLoopTests/Fixtures/score-draft-v2.json"), "utf8"));
const fixtureScore = alphaTab.importer.ScoreLoader.loadScoreFromBytes(exportDraft(alphaTab, sharedFixture), new alphaTab.Settings());
assert.equal(fixtureScore.masterBars.length, 2);
assert.equal(fixtureScore.tracks[0].staves[0].bars[1].voices[0].beats[0].playbackDuration, 320);
const original = structuredClone(draft);
const bytes = exportDraft(alphaTab, draft);
assert.deepEqual(draft, original, "Export must not mutate the caller's draft");
assert.deepEqual(Array.from(bytes.slice(0, 4)), [0x50, 0x4b, 0x03, 0x04]);
const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
const specialTitle = "中文 ' \\\n<>&";
const specialScore = alphaTab.importer.ScoreLoader.loadScoreFromBytes(
    exportDraft(alphaTab, { ...draft, title: specialTitle }), new alphaTab.Settings());
assert.equal(specialScore.title, specialTitle);
const bars = score.tracks[0].staves[0].bars;
const view = bar => bar.voices[0].beats.map(value => ({
    duration: value.duration, dots: value.dots,
    ratio: [value.tupletNumerator, value.tupletDenominator],
    start: value.playbackStart, length: value.playbackDuration, rest: value.isRest,
    notes: value.notes.map(note => [7 - note.string, note.fret, note.realValue]),
}));
assert.deepEqual(view(bars[0]), [
    { duration: 4, dots: 1, ratio: [-1, -1], start: 0, length: 1440, rest: false, notes: [[1, 0, 64], [2, 1, 60], [3, 2, 57]] },
    { duration: 8, dots: 0, ratio: [-1, -1], start: 1440, length: 480, rest: false, notes: [[6, 3, 43]] },
    { duration: 2, dots: 0, ratio: [-1, -1], start: 1920, length: 1920, rest: true, notes: [] },
]);
assert.deepEqual(view(bars[1]), [
    { duration: 8, dots: 0, ratio: [3, 2], start: 0, length: 320, rest: false, notes: [[1, 12, 76], [2, 13, 72]] },
    { duration: 8, dots: 0, ratio: [3, 2], start: 320, length: 320, rest: true, notes: [] },
    { duration: 8, dots: 0, ratio: [3, 2], start: 640, length: 320, rest: false, notes: [[1, 15, 79]] },
    { duration: 2, dots: 1, ratio: [-1, -1], start: 960, length: 2880, rest: true, notes: [] },
]);
assert.deepEqual(view(bars[2]).map(value => [value.start, value.length]),
    [[0, 320], [320, 320], [640, 320], [960, 320], [1280, 320], [1600, 320], [1920, 1920]]);

// Reject sparse arrays and hidden, accessor or symbol keys instead of silently
// dropping JS-only fields; ordinary dense parsed JSON remains accepted.
const sparseCases = [
    { ...draft, bars: Array(2) },
    { ...draft, bars: [Array(1)] },
    { ...draft, bars: [[{ duration: 1, dots: 0, notes: Array(1) }]] },
    { ...draft, bars: [[{ tuplet: { numerator: 3, denominator: 2 }, beats: Array(3) }]] },
];
for (const invalid of sparseCases) assert.throws(() => validate(invalid));
const hiddenObject = structuredClone(draft);
Object.defineProperty(hiddenObject.bars[0][0], "slide", { value: true, enumerable: false });
assert.throws(() => exportDraft(alphaTab, hiddenObject));
const hiddenArray = structuredClone(draft);
Object.defineProperty(hiddenArray.bars[0][0].notes, "hidden", { value: true, enumerable: false });
assert.throws(() => exportDraft(alphaTab, hiddenArray));
const symbolObject = structuredClone(draft);
symbolObject.bars[0][0][Symbol("technique")] = true;
assert.throws(() => exportDraft(alphaTab, symbolObject));
const symbolArray = structuredClone(draft);
symbolArray.bars[0][0].notes[Symbol("unexpected")] = true;
assert.throws(() => exportDraft(alphaTab, symbolArray));
const hiddenIndex = structuredClone(draft);
Object.defineProperty(hiddenIndex.bars[0][0].notes, "0", { value: note(1, 0), enumerable: false });
assert.throws(() => validate(hiddenIndex));
const accessor = structuredClone(draft);
let accessorRead = false;
Object.defineProperty(accessor, "tempo", { enumerable: true, get() { accessorRead = true; return 123; } });
assert.throws(() => validate(accessor));
assert.equal(accessorRead, false);

assert.doesNotThrow(() => validate({ ...draft, title: "😀".repeat(256) }));
assert.throws(() => validate({ ...draft, title: "😀".repeat(257) }), /Invalid title/);
assert.throws(() => validate({ ...draft, title: "x".repeat(1_000_000) }), /Invalid title/);

function fillWithRests(remaining) {
    const result = [];
    for (const duration of [1, 2, 4, 8, 16, 32, 64]) {
        const ticks = 3840 / duration;
        while (remaining >= ticks) { result.push(beat(duration)); remaining -= ticks; }
    }
    assert.equal(remaining, 0);
    return result;
}
for (const duration of [2, 4, 8, 16, 32, 64]) {
    const ticks = 3840 / duration * 2 / 3;
    const bar = [triplet(beat(duration, [note(1, 0)]), beat(duration), beat(duration, [note(6, 36)])),
        ...fillWithRests(3840 - 3 * ticks)];
    const restored = alphaTab.importer.ScoreLoader.loadScoreFromBytes(
        exportDraft(alphaTab, { ...draft, bars: [bar] }), new alphaTab.Settings());
    assert.deepEqual(view(restored.tracks[0].staves[0].bars[0]).slice(0, 3).map(value => value.length), [ticks, ticks, ticks]);
}
for (const duration of [2, 4, 8, 16, 32, 64]) {
    const ticks = 3840 / duration * 3 / 2;
    // Two dotted 64ths are needed so the remaining plain rests fit exactly.
    const dotted = Array.from({ length: duration === 64 ? 2 : 1 }, () => beat(duration, [note(2, 1)], 1));
    const bar = [...dotted, ...fillWithRests(3840 - dotted.length * ticks)];
    const restored = alphaTab.importer.ScoreLoader.loadScoreFromBytes(
        exportDraft(alphaTab, { ...draft, bars: [bar] }), new alphaTab.Settings());
    assert.equal(view(restored.tracks[0].staves[0].bars[0])[0].length, ticks);
}
// Adjacent groups with the same ratio must stay distinct, including a full
// bar of 64th-note triplets. One note per group is a rest and another a chord.
for (const duration of [2, 4, 8, 16, 32, 64]) {
    const groupCount = duration / 2;
    const groups = Array.from({ length: groupCount }, (_, index) =>
        triplet(beat(duration, [note(1, index % 37), note(6, (index + 1) % 37)]),
                beat(duration), beat(duration, [note(2, (index + 2) % 37)])));
    const restored = alphaTab.importer.ScoreLoader.loadScoreFromBytes(
        exportDraft(alphaTab, { ...draft, bars: [groups] }), new alphaTab.Settings());
    const actual = restored.tracks[0].staves[0].bars[0].voices[0].beats;
    assert.equal(actual.length, groupCount * 3);
    assert.equal(new Set(actual.map(value => value.tupletGroup)).size, groupCount);
    assert.equal(actual[actual.length - 1].playbackStart + actual[actual.length - 1].playbackDuration, 3840);
}

for (const invalid of [
    { ...draft, version: 1 },
    { ...draft, unknown: true },
    { ...draft, meter: { numerator: 3, denominator: 4 } },
    { ...draft, tuning: [40, 45, 50, 55, 59, 63] },
    { ...draft, bars: [[beat(4)]] }, // incomplete
    { ...draft, bars: [[beat(1), beat(4)]] }, // overfull
    { ...draft, bars: [[beat(1, [note(1, 0), note(1, 2)])]] },
    { ...draft, bars: [[beat(1, [note(1, 0), note(2, 1), note(3, 2), note(4, 3), note(5, 4), note(6, 5), note(1, 6)])]] },
    { ...draft, bars: [[{ ...beat(1), slide: true }]] },
    { ...draft, bars: [[triplet(beat(8), beat(8)), beat(2, [], 1)]] },
    { ...draft, bars: [[triplet(beat(8), beat(8), beat(16)), beat(2, [], 1)]] },
    { ...draft, bars: [[triplet(beat(8, [], 1), beat(8), beat(8)), beat(2, [], 1)]] },
    { ...draft, bars: [[{ ...triplet(beat(8), beat(8), beat(8)), extra: true }, beat(2, [], 1)]] },
    { ...draft, bars: [[{ tuplet: { numerator: 5, denominator: 4 }, beats: [beat(8), beat(8), beat(8)] }, beat(2, [], 1)]] },
]) assert.throws(() => exportDraft(alphaTab, invalid));

// The bounds count flattened beats (including every triplet member) and every
// note in a chord. They reject excess without returning a shortened score.
const fullChord = Array.from({ length: 6 }, (_, index) => note(index + 1, index));
const maxBars = { ...draft, bars: Array.from({ length: 64 }, () => [beat(1)]) };
assert.equal(validate(maxBars).length, 64);
const maxBarsScore = alphaTab.importer.ScoreLoader.loadScoreFromBytes(exportDraft(alphaTab, maxBars), new alphaTab.Settings());
assert.equal(maxBarsScore.masterBars.length, 64, "The 64th bar must not be truncated");
const tooManyBars = { ...draft, bars: [...maxBars.bars, [beat(1)]] };
const tooManyBarsBefore = structuredClone(tooManyBars);
assert.throws(() => exportDraft(alphaTab, tooManyBars), /Invalid bars/);
assert.deepEqual(tooManyBars, tooManyBarsBefore);
const beatLimit = { ...draft, bars: Array.from({ length: 64 }, () => Array.from({ length: 8 }, () => beat(8))) };
assert.equal(validate(beatLimit).reduce((sum, bar) => sum + bar.length, 0), 512);
const tooManyBeats = { ...draft, bars: [Array.from({ length: 16 }, () => beat(16)), ...beatLimit.bars.slice(1)] };
assert.throws(() => exportDraft(alphaTab, tooManyBeats), /experimental size limits/);
const noteLimit = { ...draft, bars: [...Array.from({ length: 42 }, () => [beat(2, fullChord), beat(2, fullChord)]),
    [beat(2, fullChord.slice(0, 4)), beat(2, fullChord.slice(0, 4))]] };
assert.equal(validate(noteLimit).flat().reduce((sum, value) => sum + value.notes.length, 0), 512);
const tooManyNotes = { ...draft, bars: Array.from({ length: 43 }, () => [beat(2, fullChord), beat(2, fullChord)]) };
assert.throws(() => exportDraft(alphaTab, tooManyNotes), /experimental size limits/);

// Versions cannot be mixed or have unsupported events silently discarded.
const oldDraft = { version: 1, title: "旧草稿", tempo: 100, bars: [[{ rest: true, duration: 1 }]] };
assert.throws(() => validate(oldDraft), /draft/);
assert.throws(() => v1.exportStoredDraft(alphaTab, draft));
assert.ok(v1.exportStoredDraft(alphaTab, oldDraft).length > 0);

// The iPad bridge injects the same bundled CommonJS source into a private
// module scope after loading v1. It must not replace v1's globals.
const browser = vm.createContext({ alphaTab });
const v1Source = fs.readFileSync(path.join(__dirname, "../gp-draft-editor/draft-core.js"), "utf8");
const v2Source = fs.readFileSync(path.join(__dirname, "draft-v2.cjs"), "utf8");
vm.runInContext(v1Source, browser);
const previousV1 = browser.RiffLoopDraftEditor;
vm.runInContext(`(() => { const module = { exports: {} }; (function(module) {\n${v2Source}\n})(module); globalThis.RiffLoopDraftV2 = module.exports; })()`, browser);
assert.equal(browser.RiffLoopDraftEditor, previousV1);
assert.ok(browser.RiffLoopDraftEditor.exportStoredDraft(alphaTab, oldDraft).length > 0);
assert.ok(browser.RiffLoopDraftV2.exportDraft(alphaTab, sharedFixture).length > 0);

// Simulate exporter/importer corruption to verify failures do not return data.
for (const corrupt of [
    score => { score.tracks[0].staves[0].bars[0].voices[0].beats[0].dots = 0; },
    score => { score.tracks[0].staves[0].bars[1].voices[0].beats[0].tupletNumerator = 5; },
    score => { score.tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].fret = 20; },
    score => { score.tracks[0].staves[0].bars[1].voices[0].beats[1].playbackDuration++; },
    score => { score.tracks[0].staves[0].bars[0].voices[0].beats[0].notes.pop(); },
    score => { score.masterBars[0].timeSignatureNumerator = 3; },
    score => { score.masterBars[0].repeatCount = 2; },
    score => { score.masterBars[0].tempoAutomations[0].value = 110; },
    score => { score.tracks[0].staves[0].capo = 2; },
    score => { score.tracks[0].playbackInfo.isMute = true; },
    score => { score.tracks[0].playbackInfo.volume = 0; },
    score => { score.tracks[0].playbackInfo.program = 0; },
    score => { score.tracks[0].playbackInfo.bank = 1; },
    score => { score.tracks[0].playbackInfo.balance = 0; },
    score => { score.tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].isTieDestination = true; },
    score => { score.tracks[0].staves[0].bars[0].voices[0].beats[0].graceType = 1; },
    score => { score.tracks[0].staves[0].bars[1].voices[0].beats[0].tupletGroup.beats.reverse(); },
]) {
    const altered = { ...alphaTab, importer: { ...alphaTab.importer, ScoreLoader: { loadScoreFromBytes(...args) {
        const output = alphaTab.importer.ScoreLoader.loadScoreFromBytes(...args);
        corrupt(output);
        return output;
    } } } };
    assert.throws(() => exportDraft(altered, draft), /round-trip verification failed/);
}

console.log("Experimental GP v2 timing/chord round trips: passed");

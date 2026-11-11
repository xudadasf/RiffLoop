import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const alphaTab = require('../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const { createDraft } = require('../experiments/gp-draft-editor/draft-core.js');
const note = (string, fret, duration = 4) => ({ string, fret, duration });
const input = {
    title: '草稿示例',
    tempo: 105,
    bars: [
        [note(6, 0), note(5, 2), note(4, 3), note(3, 5)],
        [note(2, 8), note(1, 10), note(2, 3), note(1, 0)],
    ],
};

function readBack(bytes) {
    const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
    return {
        title: score.title,
        tempo: score.tempo,
        bars: score.tracks[0].staves[0].bars.map(bar => bar.voices[0].beats.map(beat => ({
            // alphaTab's internal string index counts from the low string;
            // AlphaTex and the editor use the usual high-E = 1 convention.
            string: 7 - beat.notes[0].string,
            fret: beat.notes[0].fret,
            duration: beat.duration,
        }))),
    };
}

const draft = createDraft(alphaTab, input);
assert.deepEqual(readBack(draft.exportGp()), input);
const initialScore = alphaTab.importer.ScoreLoader.loadScoreFromBytes(draft.exportGp(), new alphaTab.Settings());
assert.deepEqual(
    initialScore.tracks[0].staves[0].bars[0].voices[0].beats.map(beat => beat.notes[0].realValue),
    [40, 47, 53, 60],
);

// The draft owns its data; modifying the caller's object or the returned view
// cannot modify another note or metadata behind the editor's back.
input.title = '外部修改';
input.bars[0][0].fret = 30;
const snapshot = draft.notes();
snapshot[0][1].fret = 31;
draft.setFret(0, 1, 9);
const expected = [
    [note(6, 0), note(5, 9), note(4, 3), note(3, 5)],
    [note(2, 8), note(1, 10), note(2, 3), note(1, 0)],
];
assert.deepEqual(readBack(draft.exportGp()), { title: '草稿示例', tempo: 105, bars: expected });
const editedScore = alphaTab.importer.ScoreLoader.loadScoreFromBytes(draft.exportGp(), new alphaTab.Settings());
assert.deepEqual(
    editedScore.tracks[0].staves[0].bars[0].voices[0].beats.map(beat => beat.notes[0].realValue),
    [40, 54, 53, 60],
);

draft.setDuration(0, 0, 8);
assert.throws(() => draft.exportGp(), /每小节时值之和/);
draft.setDuration(0, 1, 8);
draft.setDuration(0, 2, 2);
expected[0][0].duration = 8;
expected[0][1].duration = 8;
expected[0][2].duration = 2;
assert.deepEqual(readBack(draft.exportGp()), { title: '草稿示例', tempo: 105, bars: expected });

const beforeInvalidEdit = draft.notes();
for (const fret of [-1, 37, 1.5, '2']) assert.throws(() => draft.setFret(0, 0, fret));
for (const duration of [0, 3, 128, '4']) assert.throws(() => draft.setDuration(0, 0, duration));
assert.throws(() => draft.setFret(2, 0, 1));
assert.throws(() => draft.setDuration(0, -1, 4));
assert.deepEqual(draft.notes(), beforeInvalidEdit);

assert.throws(() => createDraft(alphaTab, { title: 'x', tempo: 100, bars: [[{ ...note(1, 1), slide: true }]] }), /不支持/);
assert.throws(() => createDraft(alphaTab, { title: 'x', tempo: 100, bars: [[note(0, 1)]] }));
assert.throws(() => createDraft(alphaTab, { title: 'x', tempo: 100, bars: [[note(1, 1, 3)]] }));
assert.throws(() => createDraft(alphaTab, { title: 'x', tempo: 100, bars: [] }));
assert.throws(() => createDraft(alphaTab, { title: 'x', tempo: 100, bars: [[note(1, 1)]], originalGp: new Uint8Array() }), /不支持/);

// Rests must survive GP export as silence with the intended timeline; a full
// bar rest is also the representation used for an empty separation measure.
const rest = duration => ({ rest: true, duration });
const restDraft = createDraft(alphaTab, { title: '休止测试', tempo: 100, bars: [
    [note(6, 0), rest(4), note(5, 3, 2)], [rest(1)],
] });
const readTimeline = draft => alphaTab.importer.ScoreLoader.loadScoreFromBytes(
    draft.exportGp(), new alphaTab.Settings()
).tracks[0].staves[0].bars.map(bar => bar.voices[0].beats.map(beat => ({
    rest: beat.isRest, duration: beat.duration, start: beat.playbackStart,
    length: beat.playbackDuration, notes: beat.notes.map(n => ({ string: 7 - n.string, fret: n.fret })),
})));
assert.deepEqual(readTimeline(restDraft), [
    [{ rest: false, duration: 4, start: 0, length: 960, notes: [{ string: 6, fret: 0 }] },
     { rest: true, duration: 4, start: 960, length: 960, notes: [] },
     { rest: false, duration: 2, start: 1920, length: 1920, notes: [{ string: 5, fret: 3 }] }],
    [{ rest: true, duration: 1, start: 0, length: 3840, notes: [] }],
]);
assert.throws(() => restDraft.setFret(0, 1, 4), /休止符/);
restDraft.setRest(0, 0);
assert.deepEqual(restDraft.notes()[0][0], rest(4));
assert.equal(readTimeline(restDraft)[0][0].rest, true);
restDraft.setNote(0, 1, 4, 2);
assert.deepEqual(restDraft.notes()[0][1], note(4, 2));
assert.deepEqual(readTimeline(restDraft)[0][1].notes, [{ string: 4, fret: 2 }]);
const beforeInvalidRestEdit = restDraft.notes();
assert.throws(() => restDraft.setNote(0, 0, 7, 2));
assert.throws(() => restDraft.setNote(0, 0, 2, 37));
assert.deepEqual(restDraft.notes(), beforeInvalidRestEdit);
for (const invalidRest of [{ rest: false, duration: 4 }, { rest: true, duration: 3 },
    { rest: true, duration: 4, string: 1 }, { rest: true, duration: 4, fret: 0 }]) {
    assert.throws(() => createDraft(alphaTab, { title: 'x', tempo: 100, bars: [[invalidRest]] }));
}
restDraft.setDuration(1, 0, 2);
assert.throws(() => restDraft.exportGp(), /每小节时值之和/);

// The same experimental core can be loaded as an offline script in WebKit.
const source = readFileSync(new URL('../experiments/gp-draft-editor/draft-core.js', import.meta.url), 'utf8');
const browser = vm.createContext({ alphaTab });
vm.runInContext(source, browser);
const browserGp = browser.RiffLoopDraftEditor.createDraft(alphaTab, {
    title: 'single note', tempo: 90, bars: [[note(1, 7, 1)]],
}).exportGp();
assert.deepEqual(readBack(browserGp), { title: 'single note', tempo: 90, bars: [[note(1, 7, 1)]] });

console.log('GP draft editor experiment: all tests passed');

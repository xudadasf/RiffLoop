// Reproduce notation state after a fret edit using only the repository fixture
// and an entirely new in-memory score. No GP file is written.
const fs = require('node:fs');
const path = require('node:path');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');

const fixture = path.resolve(__dirname, '../../RiffLoopTests/Fixtures/transport.gp');
const settings = new alpha.Settings();
const bytes = fs.readFileSync(fixture);

function roundtrip(score, beatIndex) {
    const data = new alpha.exporter.Gp7Exporter().export(score, settings);
    const decoded = alpha.importer.ScoreLoader.loadScoreFromBytes(data, settings);
    const note = decoded.tracks[0].staves[0].bars[0].voices[0].beats[beatIndex].notes[0];
    return { gp: Buffer.from(data).toString('base64'),
             reread: { fret: note.fret, realValue: note.realValue, accidentalMode: note.accidentalMode } };
}

function fromFixture(beatIndex) {
    const score = alpha.importer.ScoreLoader.loadScoreFromBytes(bytes, settings);
    const note = score.tracks[0].staves[0].bars[0].voices[0].beats[beatIndex].notes[0];
    const before = { fret: note.fret, realValue: note.realValue, accidentalMode: note.accidentalMode };
    note.fret = 4;
    const edited = { fret: note.fret, realValue: note.realValue, accidentalMode: note.accidentalMode };
    return { beatIndex, before, edited, ...roundtrip(score, beatIndex) };
}

function fromNewScore() {
    const m = alpha.model;
    const score = new m.Score();
    const master = new m.MasterBar(); score.addMasterBar(master);
    const track = new m.Track(); score.addTrack(track);
    const staff = new m.Staff(); track.addStaff(staff);
    staff.stringTuning.tunings = [64, 59, 55, 50, 45, 40];
    staff.displayTranspositionPitch = -12;
    const bar = new m.Bar(); staff.addBar(bar);
    const voice = new m.Voice(); bar.addVoice(voice);
    const beat = new m.Beat(); voice.addBeat(beat);
    const note = new m.Note(); note.string = 4; note.fret = 4; beat.addNote(note);
    score.finish(settings);
    const edited = { fret: note.fret, realValue: note.realValue, accidentalMode: note.accidentalMode };
    return { beatIndex: 0, edited, ...roundtrip(score, 0) };
}

process.stdout.write(JSON.stringify({
    fromSharp: fromFixture(0),
    fromNatural: fromFixture(1),
    fresh: fromNewScore(),
}));

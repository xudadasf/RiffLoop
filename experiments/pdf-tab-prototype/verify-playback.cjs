// Evaluation only: compare full-score playback timing using the app's MIDI generator.
const fs = require('fs');
const path = require('path');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {createCompleteTremoloGenerator} = require('./experimental-midi.cjs');

function timeline(score, trackIndex, completeTremolos) {
    const track = score.tracks[trackIndex];
    if (!track || track.staves.length !== 1 || track.staves[0].tuning.length !== 6)
        throw Error('Playback verification requires an explicit single-staff six-string track');
    const file = new alpha.midi.MidiFile();
    const notes = [], tempos = [];
    let end = 0;
    class Handler extends alpha.midi.AlphaSynthMidiFileHandler {
        addNote(t, tick, duration, key, velocity, channel) {
            if (t === trackIndex) notes.push([tick + this.tickShift, tick + this.tickShift + duration]);
            super.addNote(t, tick, duration, key, velocity, channel);
        }
        addTempo(tick, bpm) {
            tempos.push([tick + this.tickShift, bpm]);
            super.addTempo(tick, bpm);
        }
        finishTrack(t, tick) {
            if (t === trackIndex) end = tick + this.tickShift;
            super.finishTrack(t, tick);
        }
    }
    const generator = completeTremolos
        ? createCompleteTremoloGenerator(score, new alpha.Settings(), new Handler(file))
        : new alpha.midi.MidiFileGenerator(score, new alpha.Settings(), new Handler(file));
    generator.generate();
    notes.sort((a,b) => a[0]-b[0] || a[1]-b[1]);
    const tempo = [];
    for (const item of tempos.sort((a,b) => a[0]-b[0])) {
        if (tempo.length && tempo.at(-1)[0] === item[0]) tempo.pop();
        if (!tempo.length || tempo.at(-1)[1] !== item[1]) tempo.push(item);
    }
    let seconds = 0, tick = 0, bpm = score.tempo;
    for (const [at,value] of tempo) {
        if (at > end) break;
        seconds += (at-tick) / file.division * 60 / bpm;
        tick = at; bpm = value;
    }
    seconds += (end-tick) / file.division * 60 / bpm;
    return {
        bar_sequence: generator.tickLookup.masterBars.map(b => [b.masterBar.index+1,b.start,b.end]),
        tempo_timeline: tempo, note_attacks: notes.map(n => n[0]), note_releases: notes,
        end_tick: end, ticks_per_quarter: file.division, duration_seconds: seconds,
        track: track.name, track_index: trackIndex
    };
}

function comparePlayback(actual, reference, trackIndex, completeTremolos = false) {
    if (actual.tracks.length !== 1) throw Error('Expected a single-track full-score export');
    const a = timeline(actual, 0, completeTremolos), b = timeline(reference, trackIndex, completeTremolos);
    const checks = {}, differences = {};
    for (const key of ['bar_sequence','tempo_timeline','note_attacks','note_releases','end_tick','ticks_per_quarter']) {
        checks[key] = JSON.stringify(a[key]) === JSON.stringify(b[key]);
        if (!checks[key]) {
            const left = Array.isArray(a[key]) ? a[key] : [a[key]];
            const right = Array.isArray(b[key]) ? b[key] : [b[key]];
            const examples = []; let count = 0;
            for (let i=0; i<Math.max(left.length,right.length); i++) {
                if (JSON.stringify(left[i]) === JSON.stringify(right[i])) continue;
                count++;
                if (examples.length < 12) examples.push({index:i,actual:left[i] ?? null,reference:right[i] ?? null});
            }
            differences[key] = {count,examples};
        }
    }
    const summary = t => ({track:t.track,track_index:t.track_index,played_bars:t.bar_sequence.length,
        note_attacks:t.note_attacks.length,end_tick:t.end_tick,duration_seconds:t.duration_seconds,
        tempo_timeline:t.tempo_timeline});
    return {passed:Object.values(checks).every(Boolean),checks,differences,
        engine:completeTremolos ? 'experiment-complete-tremolos' : 'app-unmodified',
        actual:summary(a),reference:summary(b),
        method:'Full-score MIDI generation with alphaTab; exact played bar order/ticks, tempo events, attack multiplicity and note start/end pairs',
        not_checked:['pitch','velocity','timbre','pitch-bend curves','audio rendering','device playback'],
        caution:'Timing effects such as staccato, grace notes and repeats can cause differences even when core notation matches; this is not a listening test. Difference counts are sorted event positions, not independent musical errors. '
            +(completeTremolos ? 'Experimental tremolo correction only; the application library is unchanged.'
                : 'The app engine can omit tremolo tails of 10 ticks or less in both files; equality does not establish complete repetitions.')};
}

if (require.main === module) {
    const [exported, reference, index, output, mode] = process.argv.slice(2);
    if (!output || !/^\d+$/.test(index) || mode && mode !== '--complete-tremolos')
        throw Error('Usage: node verify-playback.cjs exported.gp reference.gp track-index report.json [--complete-tremolos]');
    if ([exported,reference].some(p => path.resolve(p).toLowerCase() === path.resolve(output).toLowerCase()))
        throw Error('Report must not overwrite an input score');
    if (fs.existsSync(output)) fs.unlinkSync(output);
    const load = p => alpha.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(p)),new alpha.Settings());
    const result = comparePlayback(load(exported),load(reference),Number(index),mode === '--complete-tremolos');
    result.files = {exported:path.basename(exported),reference:path.basename(reference)};
    fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');
    console.log(JSON.stringify({passed:result.passed,engine:result.engine,checks:result.checks,actual:result.actual,reference:result.reference}));
    process.exitCode = result.passed ? 0 : 1;
}

module.exports = {comparePlayback};

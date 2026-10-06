// Export ONLY the PDF recognizer's result. No reference GP is accepted here.
const fs = require('fs');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const [input, output, selection = 'all'] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(input,'utf8'));
const requested = selection === 'all' ? null : new Set(selection.split(',').flatMap(part => {
    const [a,b = a] = part.split('-').map(Number);
    if (!Number.isInteger(a) || !Number.isInteger(b) || a < 1 || b<a) throw Error('Invalid bar range');
    return Array.from({length:b-a+1},(_,i)=>a+i);
}));
const bars = data.systems.flatMap(s=>s.bars).filter(b=>!requested || requested.has(b.number));
if (!bars.length || new Set(bars.map(b=>b.number)).size !== bars.length ||
    (requested && bars.length !== requested.size)) throw Error('Ambiguous or missing PDF bars');
if (bars.some(b=>b.issues.length)) throw Error('Unresolved rhythm: export blocked. Inspect recognized.json and overlay.pdf.');
if (!data.tuning || !data.tempo) throw Error('Tuning and tempo must be confirmed from the PDF.');
const score = new alpha.model.Score();
score.title = 'PDF recognition EXPERIMENT - effects require review';
const track = new alpha.model.Track(); score.addTrack(track);
track.name = 'PDF tablature'; track.playbackInfo.program = 25;
const staff = new alpha.model.Staff(); track.addStaff(staff);
staff.stringTuning.tunings = data.tuning;
for (const source of bars) {
    const master = new alpha.model.MasterBar();
    [master.timeSignatureNumerator,master.timeSignatureDenominator] = source.meter;
    score.addMasterBar(master);
    if (master.index === 0) master.tempoAutomations.push(alpha.model.Automation.buildTempoAutomation(false,0,data.tempo,2));
    const bar = new alpha.model.Bar(); staff.addBar(bar);
    const voice = new alpha.model.Voice(); bar.addVoice(voice);
    for (const item of source.beats) {
        const beat = new alpha.model.Beat(); voice.addBeat(beat);
        beat.duration = item.duration; beat.dots = item.dots;
        [beat.tupletNumerator,beat.tupletDenominator] = item.tuplet;
        if(item.grace) beat.graceType = alpha.model.GraceType.BeforeBeat;
        for(const raw of item.notes) {
            const note = new alpha.model.Note(); note.string = 7-raw.string;
            note.fret = raw.fret ?? 0; note.isDead = raw.dead;
            beat.addNote(note);
        }
    }
}
const settings = new alpha.Settings(); score.finish(settings);
const bytes = new alpha.exporter.Gp7Exporter().export(score,settings);
// Re-read with the same importer the app uses. Check structure, notes and timing.
const readback = alpha.importer.ScoreLoader.loadScoreFromBytes(bytes,settings);
const actual = readback.tracks[0].staves[0].bars;
if(actual.length !== bars.length) throw Error('Export roundtrip changed bar count');
if(readback.tempo !== data.tempo || JSON.stringify(readback.tracks[0].staves[0].tuning) !== JSON.stringify(data.tuning))
    throw Error('Export roundtrip changed tempo or tuning');
for(let i=0;i<bars.length;i++) {
    const master = readback.masterBars[i];
    if(master.timeSignatureNumerator !== bars[i].meter[0] || master.timeSignatureDenominator !== bars[i].meter[1])
        throw Error('Export roundtrip changed time signature');
    const expected=bars[i].beats, received=actual[i].voices[0].beats;
    if(received.length !== expected.length) throw Error('Export roundtrip changed beat count');
    for(let j=0;j<expected.length;j++) {
        const e=expected[j], a=received[j];
        const notes=a.notes.map(n=>[7-n.string,n.isDead?null:n.fret]).sort((a,b)=>a[0]-b[0]);
        if(a.duration!==e.duration || a.dots!==e.dots || (a.graceType!==alpha.model.GraceType.None)!==e.grace ||
            (e.tuplet[0]!==1 && (a.tupletNumerator!==e.tuplet[0] || a.tupletDenominator!==e.tuplet[1])) ||
            JSON.stringify(notes)!==JSON.stringify(e.notes.map(n=>[n.string,n.fret]))) throw Error(`Roundtrip mismatch at bar ${i+1}, beat ${j+1}`);
    }
}
fs.writeFileSync(output,bytes);
console.log(JSON.stringify({exportedBars:bars.map(b=>b.number),roundtrip:'passed',output,effects:'not fully supported; experimental'}));

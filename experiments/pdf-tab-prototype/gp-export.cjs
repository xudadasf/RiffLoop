// Export ONLY the PDF recognizer's result. No reference GP is accepted here.
const fs = require('fs');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const [input, output, selection = 'all'] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(input,'utf8'));
const ornaments={'turn':alpha.model.NoteOrnament.Turn,'inverted-turn':alpha.model.NoteOrnament.InvertedTurn,
    'upper-mordent':alpha.model.NoteOrnament.UpperMordent,'lower-mordent':alpha.model.NoteOrnament.LowerMordent};
const requested = selection === 'all' ? null : new Set(selection.split(',').flatMap(part => {
    const [a,b = a] = part.split('-').map(Number);
    if (!Number.isInteger(a) || !Number.isInteger(b) || a < 1 || b<a) throw Error('Invalid bar range');
    return Array.from({length:b-a+1},(_,i)=>a+i);
}));
const bars = data.systems.flatMap(s=>s.bars).filter(b=>!requested || requested.has(b.number));
if(!requested && (data.structure_issues?.length || bars.some((b,i)=>b.number!==i+1)))
    throw Error('Missing, duplicated or reordered PDF bars: full-score export blocked');
if (!bars.length || new Set(bars.map(b=>b.number)).size !== bars.length ||
    (requested && bars.length !== requested.size)) throw Error('Ambiguous or missing PDF bars');
if (bars.some(b=>b.issues.length)) throw Error('Unresolved rhythm: export blocked. Inspect recognized.json and overlay.pdf.');
if (data.tempo_issues?.length) throw Error('Unresolved tempo marks: export blocked. Inspect recognized.json.');
if (!data.tuning || !data.tempo) throw Error('Tuning and tempo must be confirmed from the PDF.');
const events = bars.flatMap(b=>b.beats.map(v=>({bar:b.number,beat:v})));
for (let i=0;i<events.length;i++) for (const raw of events[i].beat.notes) {
    if (raw.legato_slide) {
        const next=events[i+1],target=next?.beat.notes.find(n=>n.string===raw.string);
        if(!target || next.bar!==raw.slide_target_bar || target.fret!==raw.slide_target_fret ||
            target.slide_source_bar!==events[i].bar) throw Error('Slide target is missing from this export selection');
    }
    if (raw.slide_source_bar !== undefined) {
        const prior=events[i-1],origin=prior?.beat.notes.find(n=>n.string===raw.string);
        if(!origin?.legato_slide || prior.bar!==raw.slide_source_bar)
            throw Error('Slide origin is missing from this export selection');
    }
}
const score = new alpha.model.Score();
score.title = 'PDF recognition EXPERIMENT - effects require review';
const track = new alpha.model.Track(); score.addTrack(track);
track.name = 'PDF tablature'; track.playbackInfo.program = 25;
const staff = new alpha.model.Staff(); track.addStaff(staff);
staff.stringTuning.tunings = data.tuning;
let previousNotes = new Map();
for (const source of bars) {
    const master = new alpha.model.MasterBar();
    [master.timeSignatureNumerator,master.timeSignatureDenominator] = source.meter;
    score.addMasterBar(master);
    const tempo = source.tempo ?? data.tempo;
    if (master.index === 0 || tempo !== (bars[master.index-1].tempo ?? data.tempo))
        master.tempoAutomations.push(alpha.model.Automation.buildTempoAutomation(false,0,tempo,2));
    const bar = new alpha.model.Bar(); staff.addBar(bar);
    const voice = new alpha.model.Voice(); bar.addVoice(voice);
    for (const item of source.beats) {
        const beat = new alpha.model.Beat(); voice.addBeat(beat);
        beat.duration = item.duration; beat.dots = item.dots;
        [beat.tupletNumerator,beat.tupletDenominator] = item.tuplet;
        if(item.grace) beat.graceType = alpha.model.GraceType.BeforeBeat;
        const currentNotes = new Map();
        for(const raw of item.notes) {
            const note = new alpha.model.Note(); note.string = 7-raw.string;
            note.fret = raw.fret ?? 0; note.isDead = raw.dead;
            note.isStaccato = !!raw.staccato;
            note.isPalmMute = !!raw.palm_mute;
            if(raw.ornament !== undefined) {
                if(!ornaments[raw.ornament])throw Error('Unknown ornament in recognition data');
                note.ornament = ornaments[raw.ornament];
            }
            if(raw.legato_slide) note.slideOutType = alpha.model.SlideOutType.Legato;
            if(raw.tie) {
                const prior = previousNotes.get(raw.string);
                if(!prior || prior.fret !== raw.fret || prior.bar !== raw.tie_source_bar)
                    throw Error('Tie origin is missing from this export selection');
                note.isTieDestination = true;
            }
            currentNotes.set(raw.string,{fret:raw.fret,bar:source.number});
            beat.addNote(note);
        }
        if(!item.grace) previousNotes = currentNotes;
    }
}
const settings = new alpha.Settings(); score.finish(settings);
const bytes = new alpha.exporter.Gp7Exporter().export(score,settings);
// Re-read with the same importer the app uses. Check structure, notes and timing.
const readback = alpha.importer.ScoreLoader.loadScoreFromBytes(bytes,settings);
const actual = readback.tracks[0].staves[0].bars;
if(actual.length !== bars.length) throw Error('Export roundtrip changed bar count');
if(readback.tempo !== (bars[0].tempo ?? data.tempo) || JSON.stringify(readback.tracks[0].staves[0].tuning) !== JSON.stringify(data.tuning))
    throw Error('Export roundtrip changed tempo or tuning');
for(let i=0;i<bars.length;i++) {
    const master = readback.masterBars[i];
    const tempo = bars[i].tempo ?? data.tempo;
    const changes = i === 0 || tempo !== (bars[i-1].tempo ?? data.tempo) ? [tempo] : [];
    if (JSON.stringify(master.tempoAutomations.map(a=>a.value)) !== JSON.stringify(changes) ||
        master.tempoAutomations.some(a=>a.ratioPosition !== 0 || a.isLinear))
        throw Error(`Export roundtrip changed tempo at bar ${i+1}`);
    if(master.timeSignatureNumerator !== bars[i].meter[0] || master.timeSignatureDenominator !== bars[i].meter[1])
        throw Error('Export roundtrip changed time signature');
    const expected=bars[i].beats, received=actual[i].voices[0].beats;
    if(received.length !== expected.length) throw Error('Export roundtrip changed beat count');
    for(let j=0;j<expected.length;j++) {
        const e=expected[j], a=received[j];
        const notes=a.notes.map(n=>[7-n.string,n.isDead?null:n.fret]).sort((a,b)=>a[0]-b[0]);
        const ties=a.notes.map(n=>[7-n.string,n.isTieDestination]).sort((a,b)=>a[0]-b[0]);
        for(const raw of e.notes) {
            const note=a.notes.find(n=>7-n.string===raw.string);
            if(note.isStaccato !== !!raw.staccato)
                throw Error(`Roundtrip changed staccato at bar ${i+1}, beat ${j+1}`);
            if(note.isPalmMute !== !!raw.palm_mute)
                throw Error(`Roundtrip changed palm mute at bar ${i+1}, beat ${j+1}`);
            if(note.ornament !== (raw.ornament === undefined ? alpha.model.NoteOrnament.None : ornaments[raw.ornament]))
                throw Error(`Roundtrip changed ornament at bar ${i+1}, beat ${j+1}`);
            if(note.slideOutType !== (raw.legato_slide ? alpha.model.SlideOutType.Legato : alpha.model.SlideOutType.None) ||
                (raw.legato_slide && note.slideTarget?.fret !== raw.slide_target_fret))
                throw Error(`Roundtrip changed slide at bar ${i+1}, beat ${j+1}`);
        }
        if(a.duration!==e.duration || a.dots!==e.dots || (a.graceType!==alpha.model.GraceType.None)!==e.grace ||
            (e.tuplet[0]!==1 && (a.tupletNumerator!==e.tuplet[0] || a.tupletDenominator!==e.tuplet[1])) ||
            JSON.stringify(notes)!==JSON.stringify(e.notes.map(n=>[n.string,n.fret]).sort((a,b)=>a[0]-b[0])) ||
            JSON.stringify(ties)!==JSON.stringify(e.notes.map(n=>[n.string,!!n.tie]).sort((a,b)=>a[0]-b[0])) ||
            (e.fullBarRest && !a.isFullBarRest)) throw Error(`Roundtrip mismatch at bar ${i+1}, beat ${j+1}`);
    }
}
fs.writeFileSync(output,bytes);
console.log(JSON.stringify({exportedBars:bars.map(b=>b.number),roundtrip:'passed',output,effects:'not fully supported; experimental'}));

const assert = require('node:assert/strict');
const a = require('../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const core = require('../RiffLoop/Resources/ScoreEditor/guitar-draft.js');
const schema = require('../RiffLoop/Resources/ScoreEditor/techniques.json');
const note = (string, fret, effects = {}, bend = []) => ({string,fret,effects,bend,review:[]});
const beat = (duration, notes = [], extra = {}) => ({duration,dots:0,tupletNumerator:1,tupletDenominator:1,notes,effects:{},whammy:[],tremolo:0,review:[],...extra});
const draft = bars => ({version:3,title:'Electric guitar',tempo:100,numerator:4,denominator:4,tuning:[40,45,50,55,59,64],capo:0,program:27,bars:bars.map(beats=>({beats,review:[],repeatStart:false,repeatCount:0,alternateEndings:0,section:''}))});
const reopen = input => a.importer.ScoreLoader.loadScoreFromBytes(core.exportDraft(a,input,schema),new a.Settings());
const input = draft([[beat(4,[note(1,13)],{dots:1}),beat(8,[note(2,11)]),beat(2)]]);
assert.equal(reopen(input).tracks[0].playbackInfo.program,27);
const alternate = {...draft([[beat(4,[note(6,3)]),beat(2)]]),numerator:3,denominator:4,tempo:70};
assert.equal(reopen(alternate).masterBars[0].timeSignatureNumerator,3);
assert.equal(reopen(alternate).tempo,70);
const empty = draft([[beat(1,[note(1,null)])]]);
assert.equal(reopen(empty).tracks[0].staves[0].bars[0].voices[0].beats[0].isRest,true);
assert.equal(empty.bars[0].beats[0].notes[0].fret,null,'Unknowns remain unknown in the editor');
const before = JSON.stringify(input); reopen(input); assert.equal(JSON.stringify(input),before);
for (const id of ['isPalmMute','isDead','isGhost','isStaccato','isLetRing','isLeftHandTapped']) {
  const s=reopen(draft([[beat(1,[note(1,7,{[id]:1})])]]));
  assert.equal(s.tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0][id],true,id);
}
for (const [id,value] of [['pickStroke',2],['tap',1],['slap',1],['pop',1],['fade',1],['dynamics',2]]) {
  const s=reopen(draft([[beat(1,[note(1,7)],{effects:{[id]:value}})]]));
  const expected=schema.find(x=>x.id===id&&x.scope==='beat').kind==='toggle'?true:value;
  assert.equal(s.tracks[0].staves[0].bars[0].voices[0].beats[0][id],expected,id);
}
console.log('Guitar draft: meter, electric instrument, unknowns and techniques round-trip passed');
const edit = require('../RiffLoop/Resources/ScoreEditor/editor-state.js');
const session = new edit.Session(draft([[beat(4),beat(4),beat(4),beat(4)]]),d=>core.validate(d,schema,false));
session.setFret(13); session.string=2; session.setFret(11);
assert.deepEqual(session.currentBeat.notes.map(n=>[n.string,n.fret]),[[1,13],[2,11]]);
session.insertBeat(); assert.equal(session.currentBar.beats.length,5);
session.undo(); assert.equal(session.currentBar.beats.length,4);
session.redo(); assert.equal(session.currentBar.beats.length,5);
session.deleteBeat(); session.copy('bar');session.paste();assert.equal(session.draft.bars.length,2);
session.deleteBar(); assert.equal(session.draft.bars.length,1);
const original=JSON.stringify(session.draft); assert.throws(()=>session.setFret(99));assert.equal(JSON.stringify(session.draft),original);
const localSpacing = new edit.Session(draft([[beat(4,[note(1,13)])],[beat(1,[note(2,11)])]]),d=>core.validate(d,schema,false));
localSpacing.currentBar.numerator=6;localSpacing.currentBar.denominator=8;localSpacing.currentBar.tempo=70;
const beforeSpacing=JSON.stringify(localSpacing.draft);
localSpacing.insertEmptyBars(2,true);
assert.equal(localSpacing.draft.bars.length,4);
assert.equal(localSpacing.draft.bars[2].beats[0].notes[0].fret,13);
for(const b of localSpacing.draft.bars.slice(0,2)){
  assert.equal(b.beats.reduce((n,x)=>n+core.ticks(x),0),2880);
  assert.equal(b.beats.every(x=>x.notes.length===0),true);
  assert.equal(b.tempo,70);
}
localSpacing.undo();assert.equal(JSON.stringify(localSpacing.draft),beforeSpacing);
localSpacing.redo();assert.equal(localSpacing.draft.bars.length,4);
const afterSpacing=JSON.stringify(localSpacing.draft);
for(const invalid of [0,-1,1.5,100,NaN])assert.throws(()=>localSpacing.insertEmptyBars(invalid));
assert.equal(JSON.stringify(localSpacing.draft),afterSpacing);
localSpacing.bar=3;localSpacing.insertEmptyBars(1);assert.equal(localSpacing.draft.bars.length,5);
assert.equal(localSpacing.draft.bars[3].beats[0].notes[0].fret,11);
assert.equal(localSpacing.draft.bars[4].beats.reduce((n,x)=>n+core.ticks(x),0),3840);
console.log('Local blank measures: before/after, local meter, note preservation and undo passed');
for (let s=1;s<=6;s++) {
  const score=reopen(draft([[beat(1,[note(s,7)])]]));
  const n=score.tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0];
  assert.equal(7-n.string,s); assert.equal(n.realValue,[64,59,55,50,45,40][s-1]+7);
}
let techniques=0;
for(const spec of schema){
  const values=spec.choices?spec.choices.map(x=>x[1]):spec.kind==='toggle'?[0,1]:[spec.min,spec.max];
  for(const value of values){
    const bs=Array.from({length:4},()=>beat(4,[note(1,7)]));
    const target=spec.scope==='note'?bs[1].notes[0]:bs[1];target.effects[spec.id]=value;
    if(spec.id==='bendStyle')target.bend=[{offset:0,value:0},{offset:60,value:4}];
    if(spec.id==='whammyStyle')target.whammy=[{offset:0,value:0},{offset:60,value:-4}];
    if(spec.id==='harmonicValue')target.effects.harmonicType=2;
    if(spec.id==='trillValue')target.effects.trillSpeed=16;
    if(spec.id==='trillSpeed')target.effects.trillValue=9;
    if(spec.id==='graceType'&&value>0)bs.push(beat(4));
    try {
      const source=draft([bs]);reopen(source);techniques++;
      const editing=new edit.Session(source,d=>core.validate(d,schema,false));editing.beat=1;
      const before=JSON.stringify(editing.draft);editing.removeEffect(spec.scope,spec.id);
      assert.equal((spec.scope==='note'?editing.currentNote:editing.currentBeat).effects[spec.id],undefined);
      if(spec.id==='graceType'&&value>0)editing.draft.bars[0].beats.pop();
      reopen(editing.draft);
      editing.undo();assert.equal(JSON.stringify(editing.draft),before,'Removing a technique must be undoable');reopen(editing.draft);
    }
    catch(error){console.error('Failed technique',spec.scope,spec.id,value);throw error;}
  }
}
console.log(`Guitar editor: chord input, insert/delete, undo/redo, copy/paste, 6 string pitches and ${techniques} technique settings passed`);
assert.throws(()=>reopen(draft([[beat(1,[note(1,8,{isTieDestination:1})])]])),/延音/);
assert.throws(()=>reopen(draft([[beat(1,[note(1,8,{isHammerPullOrigin:1})])]])),/同弦/);
const tied=draft([[beat(1,[note(1,8)])],[beat(1,[note(1,8,{isTieDestination:1})])]]);
const tiedScore=reopen(tied);assert.equal(tiedScore.tracks[0].staves[0].bars[1].voices[0].beats[0].notes[0].isTieDestination,true);
const sections=draft([[beat(1,[note(1,7)])],[beat(1,[note(1,9)])]]);
sections.bars[0].repeatStart=true;sections.bars[0].section='A';sections.bars[1].repeatCount=2;sections.bars[1].tempo=80;
const sectionScore=reopen(sections);assert.equal(sectionScore.masterBars[1].repeatCount,2);assert.equal(sectionScore.masterBars[1].tempoAutomations[0].value,80);
for(const bend of [[{offset:0,value:0},{offset:30,value:4},{offset:60,value:0}],[{offset:0,value:4},{offset:60,value:0}]])reopen(draft([[beat(1,[note(1,7,{},bend)])]]));
console.log('Guitar connections: cross-bar tie, invalid target rejection, repeat/section/tempo and bend curves passed');

function audio(score){
  const midi=new a.midi.MidiFile();
  const gen=new a.midi.MidiFileGenerator(score,new a.Settings(),new a.midi.AlphaSynthMidiFileHandler(midi));
  gen.generate();
  return {midi,lookup:gen.tickLookup,notes:midi.tracks.flatMap(t=>t.events).filter(e=>e instanceof a.midi.NoteOnEvent)};
}
for(const speed of [16,32,64]){
  const chord=[note(1,7,{trillValue:11,trillSpeed:speed}),note(2,5)];
  const d=draft([[beat(4,chord),beat(4),beat(2)]]);
  const expected=Array.from({length:speed/4},(_,i)=>[i*3840/speed,i%2?75:71]);
  for(const score of [core.makeScore(a,d,schema,false),reopen(d)]){
    const events=audio(score).notes;
    assert.deepEqual(events.filter(e=>e.noteKey>=71).map(e=>[e.tick,e.noteKey]),expected);
    assert.equal(events.filter(e=>e.noteKey===64).length,1,'The other chord string must sustain');
  }
}
for(const duration of [2,4,8,16]){
  const d=draft([[...Array.from({length:duration},()=>beat(duration,[note(1,7)],{tremolo:64}))]]);
  for(const score of [core.makeScore(a,d,schema,false),reopen(d)])assert.deepEqual(audio(score).notes.map(e=>e.tick),Array.from({length:64},(_,i)=>i*60));
}
const natural=draft([[beat(1,[note(1,7,{harmonicType:1})])]]);
assert.equal(audio(reopen(natural)).notes[0].noteKey,83);natural.bars[0].beats[0].notes[0].effects.harmonicValue=12;
assert.equal(audio(reopen(natural)).notes[0].noteKey,76);
const attacksAndReleases=file=>file.tracks.flatMap(t=>t.events)
  .filter(e=>e instanceof a.midi.NoteOnEvent||e instanceof a.midi.NoteOffEvent)
  .map(e=>[e instanceof a.midi.NoteOnEvent?'on':'off',e.tick,e.noteKey]);
for(const extra of [{isPalmMute:1},{isStaccato:1},{harmonicType:1}]){
  const d=draft([[beat(4,[note(1,7,{trillValue:9,trillSpeed:32,...extra}),note(2,5)]),beat(4,[note(1,8)]),beat(2)]]);
  const printed=core.makeScore(a,d,schema,false),preview=audio(printed).midi;
  core.auditionMidi(a,preview,d,schema,null,new a.Settings());
  const heard=attacksAndReleases(preview);
  assert.deepEqual(heard,attacksAndReleases(audio(reopen(d)).midi));
  if(extra.harmonicType)assert.deepEqual(heard.filter(([type,tick,key])=>type==='on'&&tick<960&&key!==64).map(x=>x[2]),[83,73,83,73,83,73,83,73]);
  assert.equal(printed.tracks[0].staves[0].bars[0].voices[0].beats.length,3,'Keep original beats selectable');
}
const dryPreview=audio(core.makeScore(a,natural,schema,false)).midi;
const originalTracks=dryPreview.tracks;
core.auditionMidi(a,dryPreview,natural,schema,null,new a.Settings());
assert.equal(dryPreview.tracks,originalTracks,'Scores without expanded ornaments retain their original MIDI');
const ped=draft([[beat(2,[note(1,7)],{effects:{sustainPedal:1}}),beat(2)],[beat(2),beat(2,[],{effects:{sustainPedal:2}})]]);
const pedScore=reopen(ped),performance=audio(pedScore),win={};
require('node:vm').runInNewContext(require('node:fs').readFileSync(require.resolve('../RiffLoop/Resources/GpWeb/riffloop-audio.js'),'utf8'),{window:win});
win.RiffLoopAudio.applyPedals(performance.midi,pedScore,performance.lookup,a);
assert.deepEqual(performance.midi.tracks.flatMap(t=>t.events).filter(e=>e.controller===64&&e.channel===0).map(e=>[e.tick,e.value]),[[0,127],[5760,0]]);
console.log('Audition and GP re-open agree on harmonic pitch, alternating trills, picking attacks, chord sustain and pedal release.');

function pedalAudio(enabled) {
  const b=beat(4,[note(1,7)]);
  if(enabled)b.effects.sustainPedal=1;
  const release=beat(4);if(enabled)release.effects.sustainPedal=2;
  const source=draft([[b,beat(4),release,beat(4)]]);source.tempo=120;
  const score=reopen(source),{midi,lookup}=audio(score);
  win.RiffLoopAudio.applyPedals(midi,score,lookup,a);
  const options=new a.synth.AudioExportOptions();options.sampleRate=44100;
  options.soundFonts=[require('node:fs').readFileSync(require.resolve('../RiffLoop/Resources/GpWeb/soundfont/sonivox.sf3'))];
  const renderer=a.synth.AlphaSynth.prototype.exportAudio.call(null,options,midi,[],new Map());
  const samples=renderer.render(66000).samples;
  const rms=(from,to)=>{const frame=samples.subarray(Math.round(88200*from),Math.round(88200*to));return Math.sqrt(frame.reduce((n,v)=>n+v*v,0)/frame.length);};
  return {held:rms(.72,.86),released:rms(1.35,1.48)};
}
const dry=pedalAudio(false),held=pedalAudio(true);
assert.ok(held.held>dry.held*8,'Pedal must audibly extend the guitar past note-off');
assert.ok(held.released<held.held*.05,'Releasing the pedal must end the sustained sample');
console.log('Shipped guitar soundfont held/released RMS:',dry,held);

for(const b of [beat(4,[note(1,7)],{dots:1,tremolo:64}),beat(8,[note(1,7)],{tupletNumerator:3,tupletDenominator:2,tremolo:64})]){
  const beats=b.dots?[b,beat(8),beat(2)]:[b,structuredClone(b),structuredClone(b),beat(4),beat(2)];
  const d=draft([beats]);
  assert.deepEqual(audio(core.makeScore(a,d,schema,false)).notes.map(e=>e.tick),audio(reopen(d)).notes.map(e=>e.tick));
}

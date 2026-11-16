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

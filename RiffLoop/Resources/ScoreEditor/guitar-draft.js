(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GuitarDraftCore=api;})(typeof globalThis==='object'?globalThis:this,function(){
'use strict';
const durations=[1,2,4,8,16,32,64];
const integer=(x,a,b)=>Number.isInteger(x)&&x>=a&&x<=b;
const fail=message=>{throw new Error(message);};
function ticks(beat){
  if((beat.effects?.graceType||0)>0)return 0;
  return 3840/beat.duration*(2-Math.pow(0.5,beat.dots))*beat.tupletDenominator/beat.tupletNumerator;
}
function validateEffects(effects,scope,schema){
  if(!effects||typeof effects!=='object'||Array.isArray(effects))fail('Invalid effects');
  for(const [key,value] of Object.entries(effects)){
    const spec=schema.find(s=>s.scope===scope&&s.id===key);
    if(!spec||!Number.isFinite(value))fail('Unsupported effect '+key);
    if(spec.kind==='toggle'&&value!==0&&value!==1)fail('Invalid switch '+key);
    if(spec.kind==='choice'&&!spec.choices.some(c=>c[1]===value))fail('Invalid choice '+key);
    if(spec.kind==='number'&&(value<spec.min||value>spec.max))fail('Invalid number '+key);
  }
}
function curve(points){
  if(!Array.isArray(points)||points.length>32)fail('Invalid pitch curve');
  let last=-1;
  for(const p of points){if(!integer(p.offset,0,60)||!integer(p.value,-24,24)||p.offset<last)fail('Invalid curve point');last=p.offset;}
  if(points.length===1)fail('Pitch curve needs at least two points');
}
function validate(draft,schema,complete=true){
  if(draft.version!==3||typeof draft.title!=='string'||draft.title.length>512||!integer(draft.tempo,1,999))fail('Invalid guitar draft');
  if(!integer(draft.numerator,1,32)||![1,2,4,8,16,32].includes(draft.denominator))fail('Invalid meter');
  if(!Array.isArray(draft.tuning)||draft.tuning.length!==6||!draft.tuning.every(n=>integer(n,0,127))||!integer(draft.capo,0,24)||!integer(draft.program,0,127))fail('Invalid instrument');
  if(!Array.isArray(draft.bars)||!draft.bars.length||draft.bars.length>512)fail('Invalid bar count');
  let count=0;
  for(const [i,bar] of draft.bars.entries()){
    if(!Array.isArray(bar.beats)||!bar.beats.length||bar.beats.length>128)fail('Invalid beat count');
    count+=bar.beats.length;if(count>32768)fail('Draft too large');
    const numerator=bar.numerator??draft.numerator,denominator=bar.denominator??draft.denominator;
    if(!integer(numerator,1,32)||![1,2,4,8,16,32].includes(denominator))fail('Invalid bar meter');
    for(const beat of bar.beats){
      if(!durations.includes(beat.duration)||!integer(beat.dots,0,2)||!integer(beat.tupletNumerator,1,16)||!integer(beat.tupletDenominator,1,16))fail('Invalid rhythm');
      if(!Array.isArray(beat.notes)||beat.notes.length>6||new Set(beat.notes.map(n=>n.string)).size!==beat.notes.length)fail('Invalid chord');
      validateEffects(beat.effects,'beat',schema);curve(beat.whammy);
      if(![0,8,16,32,64].includes(beat.tremolo))fail('Invalid tremolo');
      for(const note of beat.notes){
        if(!integer(note.string,1,6)||(note.fret!=null&&!integer(note.fret,0,36)))fail('Invalid note');
        validateEffects(note.effects,'note',schema);curve(note.bend);
        if(complete&&(note.effects.trillValue??-1)>=0&&(note.effects.trillSpeed??16)!==16)fail('GP 格式的颤音仅保存 1/16 速度；请改为 1/16 或保留当前草稿。');
      }
    }
    const actual=bar.beats.reduce((s,b)=>s+ticks(b),0),expected=numerator*3840/denominator;
    if(complete&&Math.abs(actual-expected)>0.01)fail(`第 ${i+1} 小节有 ${actual/960} 拍，应为 ${expected/960} 拍，请先调整时值或补休止。`);
  }
}
function applyEffects(target,effects,scope,schema){
  for(const spec of schema.filter(s=>s.scope===scope)){
    if(Object.hasOwn(effects,spec.id))target[spec.id]=spec.kind==='toggle'?Boolean(effects[spec.id]):effects[spec.id];
  }
}
function makeScore(a,draft,schema,complete=true){
  validate(draft,schema,complete);
  const m=a.model,score=new m.Score(),track=new m.Track(),staff=new m.Staff();
  score.title=draft.title;score.addTrack(track);track.addStaff(staff);
  track.name='Electric Guitar';track.shortName='E.Gtr.';
  track.playbackInfo.program=draft.program;track.playbackInfo.primaryChannel=0;track.playbackInfo.secondaryChannel=1;
  staff.stringTuning.tunings=[...draft.tuning].reverse();staff.capo=draft.capo;
  for(const [i,source] of draft.bars.entries()){
    const master=new m.MasterBar(),bar=new m.Bar(),voice=new m.Voice();
    master.timeSignatureNumerator=source.numerator??draft.numerator;
    master.timeSignatureDenominator=source.denominator??draft.denominator;
    master.isRepeatStart=!!source.repeatStart;master.repeatCount=source.repeatCount||0;master.alternateEndings=source.alternateEndings||0;
    if(source.section){master.section=new m.Section();master.section.text=source.section;master.section.marker='';}
    if(i===0||source.tempo)master.tempoAutomations.push(m.Automation.buildTempoAutomation(false,0,source.tempo||draft.tempo,2));
    score.addMasterBar(master);staff.addBar(bar);bar.addVoice(voice);
    for(const value of source.beats){
      const beat=new m.Beat();beat.duration=value.duration;beat.dots=value.dots;voice.addBeat(beat);
      if(value.tupletNumerator!==value.tupletDenominator){beat.tupletNumerator=value.tupletNumerator;beat.tupletDenominator=value.tupletDenominator;}
      applyEffects(beat,value.effects,'beat',schema);
      if(value.tremolo)beat.tremoloSpeed=value.tremolo;
      for(const p of value.whammy)beat.addWhammyBarPoint(new m.BendPoint(p.offset,p.value));
      if(value.text)beat.text=value.text;
      for(const input of value.notes){
        // Unknown frets remain in the editable source, never become pitched open strings.
        if(input.fret==null&&!input.effects.isDead)continue;
        const note=new m.Note();note.string=7-input.string;note.fret=input.fret??0;
        applyEffects(note,input.effects,'note',schema);note.dynamics=beat.dynamics;
        if((input.effects.trillValue??-1)>=0){note.trillValue=input.effects.trillValue+draft.tuning[6-input.string]+draft.capo;note.trillSpeed=input.effects.trillSpeed??16;}
        for(const p of input.bend)note.addBendPoint(new m.BendPoint(p.offset,p.value));
        beat.addNote(note);
      }
    }
  }
  score.finish(new a.Settings());
  return score;
}
function snapshot(score,schema){
  const effects=(target,scope)=>Object.fromEntries(schema.filter(s=>s.scope===scope).map(s=>{
    let value=target[s.id]??s.default??0;
    // Inactive auxiliary settings stay in the editable draft; GP omits them.
    if(s.id==='bendStyle'&&!target.bendPoints?.length)value=0;
    if(s.id==='whammyStyle'&&!target.whammyBarPoints?.length)value=0;
    if(s.id==='harmonicValue'&&!target.harmonicType)value=0;
    if(s.id==='trillSpeed'&&target.trillValue<0)value=16;
    return [s.id,value];
  }));
  const points=values=>(values||[]).map(p=>[p.offset,p.value]);
  return {title:score.title,tempo:score.tempo,program:score.tracks[0].playbackInfo.program,tuning:score.tracks[0].staves[0].stringTuning.tunings,
    capo:score.tracks[0].staves[0].capo,bars:score.tracks[0].staves[0].bars.map((bar,i)=>({
      meter:[score.masterBars[i].timeSignatureNumerator,score.masterBars[i].timeSignatureDenominator],
      repeatStart:score.masterBars[i].isRepeatStart,repeatCount:score.masterBars[i].repeatCount,alternateEndings:score.masterBars[i].alternateEndings,
      section:score.masterBars[i].section?.text||'',tempos:score.masterBars[i].tempoAutomations.map(a=>a.value),
      beats:bar.voices[0].beats.map(b=>({duration:b.duration,dots:b.dots,tuplet:[b.tupletNumerator,b.tupletDenominator],
        effects:effects(b,'beat'),whammy:points(b.whammyBarPoints),tremolo:b.tremoloSpeed,text:b.text||'',
        playbackStart:b.playbackStart,playbackDuration:b.playbackDuration,
        notes:b.notes.map(n=>({string:n.string,fret:n.fret,pitch:n.realValue,effects:effects(n,'note'),bend:points(n.bendPoints)})).sort((x,y)=>x.string-y.string)}))
    }))};
}
function exportDraft(a,draft,schema){
  const score=makeScore(a,draft,schema),settings=new a.Settings();
  const data=new a.exporter.Gp7Exporter().export(score,settings);
  const restored=a.importer.ScoreLoader.loadScoreFromBytes(data,settings);
  const before=snapshot(score,schema),after=snapshot(restored,schema);
  if(JSON.stringify(before)!==JSON.stringify(after)){
    const error=new Error('GP 导出后的音符或技巧发生变化，草稿已保留，请检查导出兼容性。');
    error.before=before;error.after=after;throw error;
  }
  return data;
}
return {ticks,validate,makeScore,snapshot,exportDraft};
});

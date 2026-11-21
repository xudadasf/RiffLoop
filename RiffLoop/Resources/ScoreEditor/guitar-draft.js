(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GuitarDraftCore=api;})(typeof globalThis==='object'?globalThis:this,function(){
'use strict';
const durations=[1,2,4,8,16,32,64];
const integer=(x,a,b)=>Number.isInteger(x)&&x>=a&&x<=b;
const fail=message=>{throw new Error(message);};
function ticks(beat){
  if((beat.effects?.graceType||0)>0)return 0;
  return 3840/beat.duration*(2-Math.pow(0.5,beat.dots))*beat.tupletDenominator/beat.tupletNumerator;
}
function barTiming(draft, index, sourceStaff) {
  const bar = draft.bars[index];
  const master = sourceStaff?.bars[index]?.masterBar;
  const meter = (bar.numerator ?? draft.numerator) * 3840 / (bar.denominator ?? draft.denominator);
  const length = master?.isAnacrusis ? master.calculateDuration() : meter;
  const first = bar.beats[0];
  // An imported GP can use a single whole rest for a full measure in any meter.
  // Drafts store explicit rest durations, also used by the native exporter.
  const measureRest = master && bar.beats.length === 1 && first.duration === 1 && first.notes.length === 0 &&
    !first.dots && first.tupletNumerator === first.tupletDenominator && !first.effects?.graceType;
  const actual = measureRest ? length : bar.beats.reduce((sum, beat) => sum + ticks(beat), 0);
  const expected = master?.isFreeTime ? null : length;
  return {actual, expected, mismatch: expected !== null && Math.abs(actual - expected) > 0.01};
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
      }
    }
    if(complete){
      const {actual,expected,mismatch}=barTiming(draft,i);
      if(mismatch)fail(`第 ${i+1} 小节有 ${actual/960} 拍，应为 ${expected/960} 拍，请先调整时值或补休止。`);
    }
  }
  if(complete)validateLinks(draft.bars.flatMap(b=>b.beats));
}
function validateLinks(beats){
  const prev=new Map(),next=new Map();
  for(const b of beats)for(const n of b.notes){
    const p=prev.get(n.string);
    if(n.effects.isTieDestination&&(!p||p.fret==null||p.fret!==n.fret))fail('延音需要前面已有同弦同品音符，请检查连接目标。');
    prev.set(n.string,n);
  }
  for(let i=beats.length-1;i>=0;i--)for(const n of beats[i].notes){
    const dest=next.get(n.string);
    if((n.effects.isHammerPullOrigin||[1,2].includes(n.effects.slideOutType))&&(!dest||dest.fret==null||n.fret==null))
      fail('击勾弦或连接滑音需要后面已有同弦音符，请检查连接目标。');
    next.set(n.string,n);
  }
}
function applyEffects(target,effects,scope,schema){
  for(const spec of schema.filter(s=>s.scope===scope)){
    if(spec.id!=='sustainPedal'&&Object.hasOwn(effects,spec.id))target[spec.id]=spec.kind==='toggle'?Boolean(effects[spec.id]):effects[spec.id];
  }
}
// A missing node in older drafts means the touched fret for a natural harmonic.
function harmonicNode(note){
  return note.effects.harmonicValue??(note.effects.harmonicType===1?note.fret??12:12);
}
function rhythmForTicks(length,source){
  for(const den of [source.duration,1,2,4,8,16,32,64,128,256].filter(Boolean)){
    for(const dots of [0,1,2]){
      const unit=3840/den*(2-Math.pow(.5,dots));
      if(Math.abs(length-unit)<.00001)return {duration:den,dots,tupletNumerator:1,tupletDenominator:1};
    }
  }
  for(const den of [64,32,16,8,4,2,1,128,256]){
    for(let n=2;n<=64;n++){
      const d=length*den*n/3840;
      if(d>=1&&d<=64&&Math.abs(d-Math.round(d))<.000001)return {duration:den,dots:0,tupletNumerator:n,tupletDenominator:Math.round(d)};
    }
  }
  fail('这组连音的时值无法准确写入 GP。');
}
// GP7's Trill element has no speed in this writer. Write measured notes when
// a compact symbol would change the performance in other GP readers.
function needsMeasuredBeats(beat){
  const fast=beat.notes.some(n=>(n.effects.trillValue??-1)>=0&&(n.effects.trillSpeed??16)!==16);
  const marks=Math.log2(beat.tremolo/beat.duration);
  const expandPicking=beat.tremolo>0&&(marks<1||marks>3||beat.dots||beat.tupletNumerator!==beat.tupletDenominator);
  return (fast||expandPicking)&&ticks(beat)>0;
}
function portableBeats(beat){
  if(!needsMeasuredBeats(beat))return [beat];
  const total=ticks(beat);
  const rates=beat.notes.map(n=>(n.effects.trillValue??-1)>=0?n.effects.trillSpeed??16:beat.tremolo);
  const rate=Math.max(beat.tremolo,...rates,1),step=3840/rate,parts=[];
  for(let offset=0;offset<total-.001;offset+=step){
    const first=parts.length===0,last=offset+step>=total-.001;
    const rhythm=rhythmForTicks(Math.min(step,total-offset),beat);
    const part={...beat,...rhythm,tremolo:0,text:first?beat.text:'',effects:{...beat.effects},
      whammy:first?beat.whammy:[],notes:[]};
    if(!first)delete part.effects.sustainPedal;
    if(!last)delete part.effects.isLegatoOrigin;
    for(const [i,n] of beat.notes.entries()){
      const speed=rates[i],phase=speed?offset*speed/3840:0,attack=first||speed&&Math.abs(phase-Math.round(phase))<.000001;
      const effects={...n.effects},trill=(effects.trillValue??-1)>=0;
      const alternate=trill&&Math.floor(phase+.000001)%2===1;
      const fret=alternate?effects.trillValue:n.fret;
      // The trill target is a fretted pitch even when the principal note is a harmonic.
      if(alternate){delete effects.harmonicType;delete effects.harmonicValue;}
      delete effects.trillValue;delete effects.trillSpeed;
      if(!first){delete effects.slideInType;if(attack)delete effects.isTieDestination;else effects.isTieDestination=1;}
      if(!last){delete effects.isHammerPullOrigin;delete effects.slideOutType;}
      part.notes.push({...n,fret,effects,bend:first?n.bend:[]});
    }
    parts.push(part);
  }
  return parts;
}
function makeScore(a,draft,schema,complete=true,portable=false,sourceStaff=null){
  validate(draft,schema,complete);
  const m=a.model,score=new m.Score(),track=new m.Track(),staff=new m.Staff();
  score.title=draft.title;score.addTrack(track);track.addStaff(staff);
  track.name='Electric Guitar';track.shortName='E.Gtr.';
  track.playbackInfo.program=draft.program;track.playbackInfo.primaryChannel=0;track.playbackInfo.secondaryChannel=1;
  if(sourceStaff){staff.transpositionPitch=sourceStaff.transpositionPitch;staff.displayTranspositionPitch=sourceStaff.displayTranspositionPitch;}
  staff.stringTuning.tunings=[...draft.tuning].reverse();staff.capo=draft.capo;
  for(const [i,source] of draft.bars.entries()){
    const master=new m.MasterBar(),bar=new m.Bar(),voice=new m.Voice();
    master.timeSignatureNumerator=source.numerator??draft.numerator;
    master.timeSignatureDenominator=source.denominator??draft.denominator;
    master.isRepeatStart=!!source.repeatStart;master.repeatCount=source.repeatCount||0;master.alternateEndings=source.alternateEndings||0;
    if(source.section){master.section=new m.Section();master.section.text=source.section;master.section.marker='';}
    if(i===0||source.tempo)master.tempoAutomations.push(m.Automation.buildTempoAutomation(false,0,source.tempo||draft.tempo,2));
    score.addMasterBar(master);staff.addBar(bar);bar.addVoice(voice);
    let offset=0;
    const barTicks=master.timeSignatureNumerator*3840/master.timeSignatureDenominator;
    for(const value of portable?source.beats.flatMap(portableBeats):source.beats){
      const beat=new m.Beat();beat.duration=value.duration;beat.dots=value.dots;voice.addBeat(beat);
      if(value.tupletNumerator!==value.tupletDenominator){beat.tupletNumerator=value.tupletNumerator;beat.tupletDenominator=value.tupletDenominator;}
      applyEffects(beat,value.effects,'beat',schema);
      if(value.effects.sustainPedal){
        const p=new m.SustainPedalMarker();p.ratioPosition=offset/barTicks;
        p.pedalType=value.effects.sustainPedal===1?m.SustainPedalMarkerType.Down:m.SustainPedalMarkerType.Up;
        bar.sustainPedals.push(p);
      }
      offset+=ticks(value);
      if(value.tremolo){
        const picking=new m.TremoloPickingEffect();
        picking.marks=Math.max(1,Math.log2(value.tremolo/value.duration));
        beat.tremoloPicking=picking;
        // Absolute training divisions also apply to dotted and tuplet beats.
        if(!portable){
          const factor=(2-Math.pow(.5,value.dots))*value.tupletDenominator/value.tupletNumerator;
          picking.getDurationAsTicks=()=>3840/(value.tremolo*factor);
        }
      }
      for(const p of value.whammy)beat.addWhammyBarPoint(new m.BendPoint(p.offset,p.value));
      if(value.text)beat.text=value.text;
      for(const input of value.notes){
        // Unknown frets remain in the editable source, never become pitched open strings.
        if(input.fret==null&&!input.effects.isDead)continue;
        const note=new m.Note();note.string=7-input.string;note.fret=input.fret??0;
        applyEffects(note,input.effects,'note',schema);note.dynamics=beat.dynamics;
        if(note.harmonicType)note.harmonicValue=harmonicNode(input);
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
      pedal:bar.sustainPedals.map(p=>[p.pedalType,p.ratioPosition]),
      meter:[score.masterBars[i].timeSignatureNumerator,score.masterBars[i].timeSignatureDenominator],
      repeatStart:score.masterBars[i].isRepeatStart,repeatCount:score.masterBars[i].repeatCount,alternateEndings:score.masterBars[i].alternateEndings,
      section:score.masterBars[i].section?.text||'',tempos:score.masterBars[i].tempoAutomations.map(a=>a.value),
      beats:bar.voices[0].beats.map(b=>({duration:b.duration,dots:b.dots,tuplet:[b.tupletNumerator,b.tupletDenominator],
        effects:effects(b,'beat'),whammy:points(b.whammyBarPoints),tremolo:b.tremoloSpeed,text:b.text||'',
        playbackStart:b.playbackStart,playbackDuration:b.playbackDuration,
        notes:b.notes.map(n=>({string:n.string,fret:n.fret,pitch:n.realValue,effects:effects(n,'note'),bend:points(n.bendPoints)})).sort((x,y)=>x.string-y.string)}))
    }))};
}
function auditionMidi(a,file,draft,schema,sourceStaff,settings){
  if(!draft.bars.some(bar=>bar.beats.some(needsMeasuredBeats)))return;
  const score=makeScore(a,draft,schema,false,true,sourceStaff);
  const measured=new a.midi.MidiFile();
  const generator=new a.midi.MidiFileGenerator(score,settings,new a.midi.AlphaSynthMidiFileHandler(measured));
  // The live player applies transposition separately after loading the MIDI.
  generator.applyTranspositionPitches=false;
  generator.generate();
  // Keep the engraved score's beat lookup for touch selection, seeking and the cursor.
  file.tracks=measured.tracks;
  file.tickShift=measured.tickShift;
}
function exportDraft(a,draft,schema){
  const score=makeScore(a,draft,schema,true,true),settings=new a.Settings();
  const data=new a.exporter.Gp7Exporter().export(score,settings);
  const restored=a.importer.ScoreLoader.loadScoreFromBytes(data,settings);
  const before=snapshot(score,schema),after=snapshot(restored,schema);
  if(JSON.stringify(before)!==JSON.stringify(after)){
    const error=new Error('GP 导出后的音符或技巧发生变化，草稿已保留，请检查导出兼容性。');
    error.before=before;error.after=after;throw error;
  }
  return data;
}
return {ticks,barTiming,validate,validateLinks,harmonicNode,portableBeats,makeScore,auditionMidi,snapshot,exportDraft};
});

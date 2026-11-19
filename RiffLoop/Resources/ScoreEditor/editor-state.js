(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GuitarEdit=api;})(globalThis,function(){
'use strict';
const copy=x=>JSON.parse(JSON.stringify(x));
const note=(string,fret)=>({string,fret,effects:{},bend:[],review:[]});
const beat=(duration=4)=>({duration,dots:0,tupletNumerator:1,tupletDenominator:1,notes:[],effects:{},whammy:[],tremolo:0,text:'',review:[]});
const bar=()=>({beats:[beat(1)],review:[],repeatStart:false,repeatCount:0,alternateEndings:0,section:''});
class Session {
  constructor(draft,validate){this.draft=copy(draft);this.validate=validate;this.undoStack=[];this.redoStack=[];this.bar=0;this.beat=0;this.string=1;this.clipboard=null;this.saved=JSON.stringify(draft);this.anchor=null;this.pendingDigit='';this.revision=0;}
  get dirty(){return JSON.stringify(this.draft)!==this.saved;}
  get currentBar(){return this.draft.bars[this.bar];}
  get currentBeat(){return this.currentBar.beats[this.beat];}
  get currentNote(){return this.currentBeat.notes.find(n=>n.string===this.string);}
  clamp(){this.bar=Math.max(0,Math.min(this.bar,this.draft.bars.length-1));this.beat=Math.max(0,Math.min(this.beat,this.currentBar.beats.length-1));}
  snapshot(){return {draft:copy(this.draft),bar:this.bar,beat:this.beat,string:this.string,anchor:this.anchor&&{...this.anchor}};}
  restore(s){this.revision++;this.draft=s.draft;this.bar=s.bar;this.beat=s.beat;this.string=s.string;this.anchor=s.anchor??null;this.endDigits();this.clamp();}
  change(fn){const before=this.snapshot();try{fn(this.draft);this.validate(this.draft);if(JSON.stringify(before.draft)===JSON.stringify(this.draft))return;this.revision++;this.undoStack.push(before);if(this.undoStack.length>40)this.undoStack.shift();this.redoStack=[];this.clamp();}catch(e){this.restore(before);throw e;}}
  undo(){if(!this.undoStack.length)return;this.redoStack.push(this.snapshot());this.restore(this.undoStack.pop());}
  redo(){if(!this.redoStack.length)return;this.undoStack.push(this.snapshot());this.restore(this.redoStack.pop());}
  endDigits(){this.pendingDigit='';}
  inputDigit(n){const pair=Number(this.pendingDigit+String(n));const value=this.pendingDigit&&pair<=36?pair:n;const paired=this.pendingDigit&&pair<=36;this.setFret(value);this.pendingDigit=!paired&&n>=1&&n<=3?String(n):'';}
  startSelection(){if(!this.anchor)this.anchor={bar:this.bar,beat:this.beat};this.endDigits();}
  clearSelection(){this.anchor=null;this.endDigits();}
  selectBars(first,last){
    this.anchor={bar:first,beat:0,wholeBars:true};
    this.bar=last;
    this.beat=0;
    this.endDigits();
  }
  selectNotes(first,last){
    this.anchor={bar:first.bar,beat:first.beat,string:first.string};
    this.bar=last.bar;
    this.beat=last.beat;
    this.string=last.string;
    this.endDigits();
  }
  get noteRange(){return this.anchor?.string!=null;}
  includesString(bar,beat,string){
    const picks=this.anchor?.picks;
    if(picks)return !!(picks[bar+':'+beat] & (1<<string));
    if(!this.noteRange||this.draft.bars[bar].beats[beat].notes.length===1)return true;
    return string>=Math.min(this.anchor.string,this.string)&&string<=Math.max(this.anchor.string,this.string);
  }
  togglePickedNote(bar,beat,string){
    if(!this.draft.bars[bar].beats[beat].notes.some(n=>n.string===string))return;
    // Each beat stores a six-string bitmask. Copy before toggling so undo retains its selection.
    const picks={...this.anchor?.picks};
    if(!this.anchor?.picks){
      for(const {bar:i,beat:j,value} of this.rangeEntries()){
        for(const n of value.notes){
          if(this.includesString(i,j,n.string))picks[i+':'+j]=(picks[i+':'+j]||0)|(1<<n.string);
        }
      }
    }
    const key=bar+':'+beat;
    picks[key]=(picks[key]||0)^(1<<string);
    if(!picks[key])delete picks[key];
    const positions=Object.keys(picks).map(k=>k.split(':').map(Number)).sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
    if(!positions.length){this.clearSelection();return;}
    const point=([bar,beat])=>({bar,beat,string:this.draft.bars[bar].beats[beat].notes.find(n=>picks[bar+':'+beat]&(1<<n.string)).string});
    this.selectNotes(point(positions[0]),point(positions.at(-1)));
    this.anchor.picks=picks;
  }
  get firstBar(){return Math.min(this.bar,this.anchor?.bar??this.bar);}
  get lastBar(){return Math.max(this.bar,this.anchor?.bar??this.bar);}
  get firstBeat(){
    if(this.anchor?.wholeBars)return 0;
    if(!this.anchor)return this.beat;
    if(this.bar===this.anchor.bar)return Math.min(this.beat,this.anchor.beat);
    return this.firstBar===this.bar?this.beat:this.anchor.beat;
  }
  get lastBeat(){
    if(this.anchor?.wholeBars)return this.draft.bars[this.lastBar].beats.length-1;
    if(!this.anchor)return this.beat;
    if(this.bar===this.anchor.bar)return Math.max(this.beat,this.anchor.beat);
    return this.lastBar===this.bar?this.beat:this.anchor.beat;
  }
  isSelected(bar,beat){
    if(!this.anchor||bar<this.firstBar||bar>this.lastBar)return false;
    return (bar!==this.firstBar||beat>=this.firstBeat)&&(bar!==this.lastBar||beat<=this.lastBeat);
  }
  *rangeEntries(){
    for(let bar=this.firstBar;bar<=this.lastBar;bar++){
      const beats=this.draft.bars[bar].beats;
      const first=bar===this.firstBar?this.firstBeat:0,last=bar===this.lastBar?this.lastBeat:beats.length-1;
      for(let beat=first;beat<=last;beat++)yield {bar,beat,value:beats[beat]};
    }
  }
  get selectedBeats(){
    if(!this.anchor)return [this.currentBeat];
    return Array.from(this.rangeEntries()).filter(({bar,beat,value})=>
      !this.noteRange||value.notes.some(n=>this.includesString(bar,beat,n.string))).map(entry=>entry.value);
  }
  targets(scope){
    if(scope==='beat')return this.selectedBeats;
    if(!this.anchor)return this.currentNote?[this.currentNote]:[];
    return Array.from(this.rangeEntries()).flatMap(({bar,beat,value})=>
      value.notes.filter(n=>this.includesString(bar,beat,n.string)));
  }
  removeSelectedNotes(){
    const selected=new Set(this.targets('note'));
    this.change(()=>{
      for(const b of this.selectedBeats)b.notes=b.notes.filter(n=>!selected.has(n));
      this.clearSelection();
    });
  }
  effectTargets(scope,id,value){
    const selected=this.targets(scope);
    if(!this.anchor)return selected;
    if(id==='sustainPedal'&&selected.length)return [value===2?selected.at(-1):selected[0]];
    const ties=id==='isTieDestination',legato=id==='isLegatoOrigin';
    if(!ties&&!legato&&id!=='isHammerPullOrigin'&&!(id==='slideOutType'&&[1,2].includes(value)))return selected;
    const picks=new Set(selected),eligible=[],previous=new Map();
    for(const {value:beat} of this.rangeEntries()){
      if(!beat.notes.length){previous.clear();continue;}
      for(const item of legato?[beat]:beat.notes){
        const key=legato?0:item.string,prior=previous.get(key);
        if(picks.has(item)&&picks.has(prior)&&(legato||item.fret!=null&&prior.fret!=null)&&(!ties||item.fret===prior.fret))
          eligible.push(ties?item:prior);
        previous.set(key,item);
      }
    }
    return eligible;
  }
  setEffect(scope,id,value){
    const targets=this.effectTargets(scope,id,value);
    if(!targets.length)throw Error('请选择连续的同弦音符，延音还需要同品。');
    this.change(()=>targets.forEach(t=>{t.effects[id]=value;}));
  }
  toggleEffect(scope,id,value=1,defaultValue=0){const targets=this.effectTargets(scope,id,value);if(this.anchor&&!targets.length)throw Error('请选择连续的同弦音符，延音还需要同品。');if(!targets.length)throw Error('先在当前弦输入品位，或选中已有音符。');const next=targets.every(t=>(t.effects[id]??defaultValue)===value)?defaultValue:value;this.change(()=>targets.forEach(t=>{t.effects[id]=next;}));}
  removeEffect(scope,id){
    let targets=this.targets(scope);
    if(this.anchor&&['isTieDestination','isHammerPullOrigin','isLegatoOrigin','slideOutType'].includes(id)){
      const internal=new Set(this.effectTargets(scope,id,1));
      targets=targets.filter(t=>internal.has(t)||id==='slideOutType'&&![1,2].includes(t.effects[id]));
    }
    this.change(()=>targets.forEach(t=>{delete t.effects[id];const dependent={harmonicType:'harmonicValue',trillValue:'trillSpeed',brushType:'brushDuration'}[id];if(dependent)delete t.effects[dependent];}));}
  setCurve(scope,points){const targets=this.targets(scope);if(!targets.length)throw Error('先选中已有音符。');this.change(()=>targets.forEach(t=>{t[scope==='note'?'bend':'whammy']=copy(points);if(!points.length)delete t.effects[scope==='note'?'bendStyle':'whammyStyle'];}));}
  clearTechniques(){
    this.change(()=>{
      const selected=new Set(this.targets('note'));
      for(const n of selected){n.effects={};n.bend=[];}
      for(const b of this.selectedBeats){
        if(this.noteRange&&b.notes.some(n=>!selected.has(n)))continue;
        const grace=b.effects.graceType;
        b.effects=grace?{graceType:grace}:{};
        b.whammy=[];b.tremolo=0;
      }
    });
  }
  setDuration(duration){this.change(()=>this.selectedBeats.forEach(b=>{b.duration=duration;b.review=b.review.filter(x=>!x.includes('时值'));}));}
  toggleDots(dots=1){const value=this.selectedBeats.every(b=>b.dots===dots)?0:dots;this.change(()=>this.selectedBeats.forEach(b=>b.dots=value));}
  move(dx,dy,byBar=false,extend=false){
    if(this.anchor?.picks)this.clearSelection();
    if(extend)this.startSelection();else this.clearSelection();this.endDigits();
    if(dy)this.string=(this.string-1+dy+6)%6+1;
    if(!dx)return;
    if(dx<0){if(byBar&&this.beat>0)this.beat=0;else if(!byBar&&this.beat>0)this.beat--;else if(this.bar>0){this.bar--;this.beat=byBar?0:this.currentBar.beats.length-1;}return;}
    if(!byBar&&this.beat<this.currentBar.beats.length-1){this.beat++;return;}
    if(this.bar<this.draft.bars.length-1){this.bar++;this.beat=0;return;}
    // Extending a selection must never create score content.
    if(!extend)this.insertEmptyBars(1);
  }
  transpose(step){
    const notes=this.targets('note').filter(n=>n.fret!=null);
    if(!notes.length)throw Error('选区内没有已知品位。');
    if(notes.some(n=>n.fret+step<0||n.fret+step>36))throw Error('移调后有音符超出 0–36 品。');
    this.change(()=>notes.forEach(n=>n.fret+=step));
  }
  erase(){if(this.anchor){this.deleteBeat();return;}if(this.currentBeat.notes.length)this.deleteNote();else this.deleteBeat();}
  split(){const targets=this.selectedBeats;if(targets.some(b=>b.duration>=64))throw Error('六十四分音符不能再拆分。');this.change(()=>{for(const bar of this.draft.bars){for(let i=bar.beats.length-1;i>=0;i--){const b=bar.beats[i];if(!targets.includes(b))continue;b.duration*=2;bar.beats.splice(i+1,0,copy(b));}}});this.clearSelection();}
  tuplet(n,core){
    const denominator={2:3,3:2,4:3,5:4,6:4,7:4,8:6,9:8}[n];
    if(!denominator)throw Error('请选择 2 到 9 连音。');
    if(this.anchor&&this.anchor.bar!==this.bar)throw Error('连音组需在同一小节内。');
    const start=this.firstBeat;
    let group=this.anchor?this.selectedBeats:this.currentBar.beats.slice(start,start+n);
    const removing=group.length===n&&group.every(b=>b.tupletNumerator===n&&b.tupletDenominator===denominator);
    if(this.noteRange&&group.length!==this.lastBeat-start+1)throw Error('连音组需要连续的拍位。');
    if(this.anchor&&group.length!==n)throw Error(`请选择 ${n} 个拍位。`);
    if(group.some(b=>b.duration!==group[0].duration||b.dots!==group[0].dots))throw Error('连音组内的时值和附点必须相同。');
    this.change(()=>{while(group.length<n){const b=beat(group[0].duration);b.dots=group[0].dots;this.currentBar.beats.push(b);group.push(b);}group.forEach(b=>{b.tupletNumerator=removing?1:n;b.tupletDenominator=removing?1:denominator;});
      const capacity=(this.currentBar.numerator??this.draft.numerator)*3840/(this.currentBar.denominator??this.draft.denominator);
      if(!removing&&this.currentBar.beats.reduce((sum,b)=>sum+core.ticks(b),0)>capacity+.01)throw Error('这组连音放不进本小节，请先调整时值。');
    });
  }
  setFret(fret){
    if(this.noteRange){
      this.change(()=>this.targets('note').forEach(n=>{n.fret=fret;n.review=[];}));
      return;
    }
    if(this.anchor?.wholeBars)throw Error('请轻点要输入品位的弦位。整段移调可在“音符”中升降半音。');this.change(()=>{let n=this.currentNote;if(!n){n=note(this.string,fret);this.currentBeat.notes.push(n);}n.fret=fret;n.review=[];});}
  rest(){this.change(()=>{this.currentBeat.notes=[];});}
  deleteNote(){this.change(()=>{this.currentBeat.notes=this.currentBeat.notes.filter(n=>n.string!==this.string);});}
  insertBeat(after=false,noteEntry=false){this.change(()=>{if(this.anchor){const at=after?this.lastBeat:this.firstBeat;this.bar=after?this.lastBar:this.firstBar;this.beat=at;}this.clearSelection();const old=this.currentBeat,b=beat(old.duration);b.dots=old.dots;b.tupletNumerator=old.tupletNumerator;b.tupletDenominator=old.tupletDenominator;if(noteEntry){const n=note(this.string,null);n.review=['请输入新音符的品位'];b.notes=[n];}this.currentBar.beats.splice(this.beat+(after?1:0),0,b);if(after)this.beat++;});}
  deleteBeat(){
    if(this.noteRange){this.removeSelectedNotes();return;}
    if(this.anchor?.wholeBars){this.deleteBar();return;}
    if(this.anchor){
      this.change(()=>{
        const first=this.firstBar;
        const selected=new Set(this.selectedBeats);
        for(const b of this.draft.bars.slice(first,this.lastBar+1)){
          const duration=b.beats[0].duration;
          b.beats=b.beats.filter(beat=>!selected.has(beat));
          if(!b.beats.length)b.beats.push(beat(duration));
        }
        this.beat=this.firstBeat;
        this.bar=first;
        this.clearSelection();
      });
      return;
    }
    this.change(()=>{if(this.currentBar.beats.length===1)this.currentBar.beats[0]=beat(this.currentBeat.duration);else this.currentBar.beats.splice(this.beat,1);});}
  insertBar(){this.insertEmptyBars(1);}
  insertEmptyBars(count,before=false){
    if(!Number.isInteger(count)||count<1||count>99)throw Error('空白小节数请输入 1 到 99。');
    if(this.draft.bars.length+count>512)throw Error('插入后超过 512 小节，请减少数量。');
    this.change(d=>{this.bar=before?this.firstBar:this.lastBar;this.clearSelection();const current=this.currentBar,numerator=current.numerator??d.numerator,denominator=current.denominator??d.denominator;
      const inserted=Array.from({length:count},()=>{const b=bar();b.numerator=numerator;b.denominator=denominator;
        b.beats=Array.from({length:numerator},()=>beat(denominator));if(current.tempo)b.tempo=current.tempo;return b;});
      const at=this.bar+(before?0:1);d.bars.splice(at,0,...inserted);this.bar=at;this.beat=0;
    });
  }
  deleteBar(){
    this.change(d=>{
      const first=this.anchor?.wholeBars?this.firstBar:this.bar;
      const last=this.anchor?.wholeBars?this.lastBar:this.bar;
      d.bars.splice(first,last-first+1);
      if(!d.bars.length){
        const empty=bar();
        empty.beats=Array.from({length:d.numerator},()=>beat(d.denominator));
        d.bars.push(empty);
      }
      this.bar=Math.min(first,d.bars.length-1);
      this.beat=0;
      this.clearSelection();
    });
  }
  beatsForClipboard(bar){
    const result=[];
    this.draft.bars[bar].beats.forEach((b,beat)=>{
      if(this.anchor?!this.isSelected(bar,beat):beat!==this.beat)return;
      if(!this.noteRange){result.push(b);return;}
      const notes=b.notes.filter(n=>this.includesString(bar,beat,n.string));
      if(notes.length)result.push({...b,notes});
      else result.push({...b,notes:[],effects:b.effects.graceType?{graceType:b.effects.graceType}:{},whammy:[],tremolo:0,text:'',review:[]});
    });
    return result;
  }
  copy(scope){
    if(scope==='bar'||this.anchor?.wholeBars){
      const first=this.anchor?.wholeBars?this.firstBar:this.bar;
      const last=this.anchor?.wholeBars?this.lastBar:this.bar;
      this.clipboard={scope:'bars',value:copy(this.draft.bars.slice(first,last+1))};
    }else if(this.anchor&&this.firstBar!==this.lastBar){
      const parts=this.draft.bars.slice(this.firstBar,this.lastBar+1).map((bar,i)=>({
        ...bar,beats:this.beatsForClipboard(this.firstBar+i)
      }));
      this.clipboard={scope:'fragment',value:copy(parts)};
    }else this.clipboard={scope:'beat',value:copy(this.beatsForClipboard(this.bar))};
  }
  paste(){
    if(!this.clipboard)return;
    this.change(d=>{
      if(this.anchor){
        const end=this.lastBar,beat=this.lastBeat;
        this.bar=end;
        this.beat=beat;
      }
      this.clearSelection();
      const value=copy(this.clipboard.value);
      if(this.clipboard.scope==='bars'){
        const first=this.bar+1;
        d.bars.splice(first,0,...value);
        this.selectBars(first,first+value.length-1);
      }else if(this.clipboard.scope==='fragment'){
        const tail=this.currentBar.beats.splice(this.beat+1);
        this.currentBar.beats.push(...value.shift().beats);
        d.bars.splice(this.bar+1,0,...value);
        this.bar+=value.length;
        this.beat=this.currentBar.beats.length-1;
        this.currentBar.beats.push(...tail);
      }else{
        this.currentBar.beats.splice(this.beat+1,0,...value);
        this.beat+=value.length;
      }
    });
  }
  fill(core){this.change(d=>{let rest=(this.currentBar.numerator??d.numerator)*3840/(this.currentBar.denominator??d.denominator)-this.currentBar.beats.reduce((n,b)=>n+core.ticks(b),0);if(rest<-.01)throw Error('本小节已超时，请缩短时值、移动音符或拆分小节。');for(const duration of [1,2,4,8,16,32,64])while(rest>=3840/duration-.01&&rest>.01){this.currentBar.beats.push(beat(duration));rest-=3840/duration;}if(Math.abs(rest)>.01)throw Error('剩余时值包含连音，请手动设置相应休止时值。');});}
}
return {Session,note,beat,bar,copy};
});

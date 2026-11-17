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
  snapshot(){return {draft:copy(this.draft),bar:this.bar,beat:this.beat,string:this.string};}
  restore(s){this.revision++;this.draft=s.draft;this.bar=s.bar;this.beat=s.beat;this.string=s.string;this.clearSelection();this.clamp();}
  change(fn){const before=this.snapshot();try{fn(this.draft);this.validate(this.draft);if(JSON.stringify(before.draft)===JSON.stringify(this.draft))return;this.revision++;this.undoStack.push(before);if(this.undoStack.length>40)this.undoStack.shift();this.redoStack=[];this.clamp();}catch(e){this.restore(before);throw e;}}
  undo(){if(!this.undoStack.length)return;this.redoStack.push(this.snapshot());this.restore(this.undoStack.pop());}
  redo(){if(!this.redoStack.length)return;this.undoStack.push(this.snapshot());this.restore(this.redoStack.pop());}
  endDigits(){this.pendingDigit='';}
  inputDigit(n){const pair=Number(this.pendingDigit+String(n));const value=this.pendingDigit&&pair<=36?pair:n;const paired=this.pendingDigit&&pair<=36;this.setFret(value);this.pendingDigit=!paired&&n>=1&&n<=3?String(n):'';}
  startSelection(){if(!this.anchor)this.anchor={bar:this.bar,beat:this.beat};this.endDigits();}
  clearSelection(){this.anchor=null;this.endDigits();}
  isSelected(bar,beat){if(!this.anchor)return false;const x=bar*100000+beat,a=this.anchor.bar*100000+this.anchor.beat,b=this.bar*100000+this.beat;return x>=Math.min(a,b)&&x<=Math.max(a,b);}
  get selectedBeats(){if(!this.anchor)return [this.currentBeat];return this.draft.bars.flatMap((bar,bi)=>bar.beats.filter((b,ti)=>this.isSelected(bi,ti)));}
  targets(scope){return scope==='beat'?this.selectedBeats:this.anchor?this.selectedBeats.flatMap(b=>b.notes):this.currentNote?[this.currentNote]:[];}
  toggleEffect(scope,id,value=1,defaultValue=0){const targets=this.targets(scope);if(!targets.length)throw Error('先在当前弦输入品位，或选中已有音符。');const next=targets.every(t=>(t.effects[id]??defaultValue)===value)?defaultValue:value;this.change(()=>targets.forEach(t=>{t.effects[id]=next;}));}
  removeEffect(scope,id){this.change(()=>this.targets(scope).forEach(t=>{delete t.effects[id];const dependent={harmonicType:'harmonicValue',trillValue:'trillSpeed',brushType:'brushDuration'}[id];if(dependent)delete t.effects[dependent];}));}
  setCurve(scope,points){const targets=this.targets(scope);if(!targets.length)throw Error('先选中已有音符。');this.change(()=>targets.forEach(t=>{t[scope==='note'?'bend':'whammy']=copy(points);if(!points.length)delete t.effects[scope==='note'?'bendStyle':'whammyStyle'];}));}
  clearTechniques(){this.change(()=>{this.targets('note').forEach(n=>{n.effects={};n.bend=[];});this.targets('beat').forEach(b=>{const grace=b.effects.graceType;b.effects=grace?{graceType:grace}:{};b.whammy=[];b.tremolo=0;});});}
  setDuration(duration){this.change(()=>this.selectedBeats.forEach(b=>{b.duration=duration;b.review=b.review.filter(x=>!x.includes('时值'));}));}
  toggleDots(dots=1){const value=this.selectedBeats.every(b=>b.dots===dots)?0:dots;this.change(()=>this.selectedBeats.forEach(b=>b.dots=value));}
  move(dx,dy,byBar=false,extend=false){
    if(extend)this.startSelection();else this.clearSelection();this.endDigits();
    if(dy)this.string=(this.string-1+dy+6)%6+1;
    if(!dx)return;
    if(dx<0){if(byBar&&this.beat>0)this.beat=0;else if(!byBar&&this.beat>0)this.beat--;else if(this.bar>0){this.bar--;this.beat=byBar?0:this.currentBar.beats.length-1;}return;}
    if(!byBar&&this.beat<this.currentBar.beats.length-1){this.beat++;return;}
    if(this.bar<this.draft.bars.length-1){this.bar++;this.beat=0;return;}
    // Extending a selection must never create score content.
    if(!extend)this.insertEmptyBars(1);
  }
  erase(){if(this.currentBeat.notes.length)this.deleteNote();else this.deleteBeat();}
  split(){const targets=this.selectedBeats;if(targets.some(b=>b.duration>=64))throw Error('六十四分音符不能再拆分。');this.change(()=>{for(const bar of this.draft.bars){for(let i=bar.beats.length-1;i>=0;i--){const b=bar.beats[i];if(!targets.includes(b))continue;b.duration*=2;bar.beats.splice(i+1,0,copy(b));}}});this.clearSelection();}
  tuplet(n,core){
    const denominator={2:3,3:2,4:3,5:4,6:4,7:4,8:6,9:8}[n];
    if(!denominator)throw Error('请选择 2 到 9 连音。');
    if(this.anchor&&this.anchor.bar!==this.bar)throw Error('连音组需在同一小节内。');
    const start=this.anchor?Math.min(this.anchor.beat,this.beat):this.beat;
    let group=this.anchor?this.selectedBeats:this.currentBar.beats.slice(start,start+n);
    const removing=group.length===n&&group.every(b=>b.tupletNumerator===n&&b.tupletDenominator===denominator);
    if(this.anchor&&group.length!==n)throw Error(`请选择 ${n} 个拍位。`);
    if(group.some(b=>b.duration!==group[0].duration||b.dots!==group[0].dots))throw Error('连音组内的时值和附点必须相同。');
    this.change(()=>{while(group.length<n){const b=beat(group[0].duration);b.dots=group[0].dots;this.currentBar.beats.push(b);group.push(b);}group.forEach(b=>{b.tupletNumerator=removing?1:n;b.tupletDenominator=removing?1:denominator;});
      const capacity=(this.currentBar.numerator??this.draft.numerator)*3840/(this.currentBar.denominator??this.draft.denominator);
      if(!removing&&this.currentBar.beats.reduce((sum,b)=>sum+core.ticks(b),0)>capacity+.01)throw Error('这组连音放不进本小节，请先调整时值。');
    });
  }
  setFret(fret){this.change(()=>{let n=this.currentNote;if(!n){n=note(this.string,fret);this.currentBeat.notes.push(n);}n.fret=fret;n.review=[];});}
  rest(){this.change(()=>{this.currentBeat.notes=[];});}
  deleteNote(){this.change(()=>{this.currentBeat.notes=this.currentBeat.notes.filter(n=>n.string!==this.string);});}
  insertBeat(after=false,noteEntry=false){this.clearSelection();this.change(()=>{const old=this.currentBeat,b=beat(old.duration);b.dots=old.dots;b.tupletNumerator=old.tupletNumerator;b.tupletDenominator=old.tupletDenominator;if(noteEntry){const n=note(this.string,null);n.review=['请输入新音符的品位'];b.notes=[n];}this.currentBar.beats.splice(this.beat+(after?1:0),0,b);if(after)this.beat++;});}
  deleteBeat(){this.change(()=>{if(this.currentBar.beats.length===1)this.currentBar.beats[0]=beat(this.currentBeat.duration);else this.currentBar.beats.splice(this.beat,1);});}
  insertBar(){this.insertEmptyBars(1);}
  insertEmptyBars(count,before=false){
    if(!Number.isInteger(count)||count<1||count>99)throw Error('空白小节数请输入 1 到 99。');
    if(this.draft.bars.length+count>512)throw Error('插入后超过 512 小节，请减少数量。');
    this.change(d=>{const current=this.currentBar,numerator=current.numerator??d.numerator,denominator=current.denominator??d.denominator;
      const inserted=Array.from({length:count},()=>{const b=bar();b.numerator=numerator;b.denominator=denominator;
        b.beats=Array.from({length:numerator},()=>beat(denominator));if(current.tempo)b.tempo=current.tempo;return b;});
      const at=this.bar+(before?0:1);d.bars.splice(at,0,...inserted);this.bar=at;this.beat=0;
    });
  }
  deleteBar(){this.change(d=>{if(d.bars.length===1){d.bars[0]=bar();d.bars[0].beats=Array.from({length:d.numerator},()=>beat(d.denominator));}else d.bars.splice(this.bar,1);this.beat=0;});}
  copy(scope){this.clipboard={scope,value:copy(scope==='bar'?this.currentBar:this.anchor?this.selectedBeats:[this.currentBeat])};}
  paste(){if(!this.clipboard)return;this.clearSelection();this.change(d=>{if(this.clipboard.scope==='bar'){d.bars.splice(this.bar+1,0,copy(this.clipboard.value));this.bar++;this.beat=0;}else{this.currentBar.beats.splice(this.beat+1,0,...copy(this.clipboard.value));this.beat++;}});}
  fill(core){this.change(d=>{let rest=(this.currentBar.numerator??d.numerator)*3840/(this.currentBar.denominator??d.denominator)-this.currentBar.beats.reduce((n,b)=>n+core.ticks(b),0);if(rest<-.01)throw Error('本小节已超时，请缩短时值、移动音符或拆分小节。');for(const duration of [1,2,4,8,16,32,64])while(rest>=3840/duration-.01&&rest>.01){this.currentBar.beats.push(beat(duration));rest-=3840/duration;}if(Math.abs(rest)>.01)throw Error('剩余时值包含连音，请手动设置相应休止时值。');});}
}
return {Session,note,beat,bar,copy};
});

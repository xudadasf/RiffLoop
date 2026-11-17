(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GuitarEdit=api;})(globalThis,function(){
'use strict';
const copy=x=>JSON.parse(JSON.stringify(x));
const note=(string,fret)=>({string,fret,effects:{},bend:[],review:[]});
const beat=(duration=4)=>({duration,dots:0,tupletNumerator:1,tupletDenominator:1,notes:[],effects:{},whammy:[],tremolo:0,text:'',review:[]});
const bar=()=>({beats:[beat(1)],review:[],repeatStart:false,repeatCount:0,alternateEndings:0,section:''});
class Session {
  constructor(draft,validate){this.draft=copy(draft);this.validate=validate;this.undoStack=[];this.redoStack=[];this.bar=0;this.beat=0;this.string=1;this.clipboard=null;this.saved=JSON.stringify(draft);}
  get dirty(){return JSON.stringify(this.draft)!==this.saved;}
  get currentBar(){return this.draft.bars[this.bar];}
  get currentBeat(){return this.currentBar.beats[this.beat];}
  get currentNote(){return this.currentBeat.notes.find(n=>n.string===this.string);}
  clamp(){this.bar=Math.max(0,Math.min(this.bar,this.draft.bars.length-1));this.beat=Math.max(0,Math.min(this.beat,this.currentBar.beats.length-1));}
  change(fn){const before=copy(this.draft);try{fn(this.draft);this.validate(this.draft);if(JSON.stringify(before)===JSON.stringify(this.draft))return;this.undoStack.push(before);if(this.undoStack.length>40)this.undoStack.shift();this.redoStack=[];this.clamp();}catch(e){this.draft=before;this.clamp();throw e;}}
  undo(){if(!this.undoStack.length)return;this.redoStack.push(this.draft);this.draft=this.undoStack.pop();this.clamp();}
  redo(){if(!this.redoStack.length)return;this.undoStack.push(this.draft);this.draft=this.redoStack.pop();this.clamp();}
  setFret(fret){this.change(()=>{let n=this.currentNote;if(!n){n=note(this.string,fret);this.currentBeat.notes.push(n);}n.fret=fret;n.review=[];});}
  rest(){this.change(()=>{this.currentBeat.notes=[];});}
  deleteNote(){this.change(()=>{this.currentBeat.notes=this.currentBeat.notes.filter(n=>n.string!==this.string);});}
  insertBeat(after=false){this.change(()=>{const b=beat(this.currentBeat.duration);this.currentBar.beats.splice(this.beat+(after?1:0),0,b);if(after)this.beat++;});}
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
  copy(scope){this.clipboard={scope,value:copy(scope==='bar'?this.currentBar:this.currentBeat)};}
  paste(){if(!this.clipboard)return;this.change(d=>{if(this.clipboard.scope==='bar'){d.bars.splice(this.bar+1,0,copy(this.clipboard.value));this.bar++;this.beat=0;}else{this.currentBar.beats.splice(this.beat+1,0,copy(this.clipboard.value));this.beat++;}});}
  fill(core){this.change(d=>{let rest=(this.currentBar.numerator??d.numerator)*3840/(this.currentBar.denominator??d.denominator)-this.currentBar.beats.reduce((n,b)=>n+core.ticks(b),0);if(rest<-.01)throw Error('本小节已超时，请缩短时值、移动音符或拆分小节。');for(const duration of [1,2,4,8,16,32,64])while(rest>=3840/duration-.01&&rest>.01){this.currentBar.beats.push(beat(duration));rest-=3840/duration;}if(Math.abs(rest)>.01)throw Error('剩余时值包含连音，请手动设置相应休止时值。');});}
}
return {Session,note,beat,bar,copy};
});

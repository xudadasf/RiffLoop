'use strict';
let session,schema,busy=false,digitTime=0,digitText='',savedHere=false;
const $=id=>document.getElementById(id),core=GuitarDraftCore;
const send=(action,payload={})=>window.webkit?.messageHandlers.guitarEditor.postMessage({action,...payload});
const status=text=>{$('status').textContent=text;};
function perform(fn,keepDigits=false){if(busy)return;surface?.pause();if(!keepDigits)digitTime=0;try{fn();render();}catch(e){status(e.message);}}
function button(text,action,parent){const el=document.createElement('button');el.textContent=text;el.onclick=()=>perform(action,parent.id==='keypad'&&/^\d$/.test(text));parent.append(el);return el;}
function field(label,value,change,options){const row=document.createElement('label');row.append(document.createTextNode(label));const input=document.createElement(options?'select':'input');input.setAttribute('aria-label',label);if(options){for(const [name,val] of options){const o=document.createElement('option');o.value=val;o.textContent=name;input.append(o);}}else input.type=typeof value==='number'?'number':'text';input.value=value;input.onchange=()=>perform(()=>change(options||input.type==='number'?Number(input.value):input.value));row.append(input);$('panelBody').append(row);return input;}
function panel(title){surface?.pause();$('panelTitle').textContent=title;$('panelBody').replaceChildren();$('panel').showModal();}
function heading(text){const h=document.createElement('h3');h.textContent=text;$('panelBody').append(h);}
function text(value){const p=document.createElement('p');p.textContent=value;$('panelBody').append(p);}
function select(b,s){surface?.pause();session.beat=b;session.string=s;digitText='';digitTime=0;render();}
function markers(b){let names=[];if(b.tupletNumerator!==b.tupletDenominator)names.push(`${b.tupletNumerator}:${b.tupletDenominator}`);for(const spec of schema){let val=spec.scope==='beat'?b.effects[spec.id]:null;if(spec.scope==='note'){if(b.notes.some(n=>n.effects[spec.id]!==undefined&&n.effects[spec.id]!==0&&n.effects[spec.id]!==spec.default))names.push(spec.label);}else if(val!==undefined&&val!==0&&val!==spec.default)names.push(spec.label);}if(b.notes.some(n=>n.bend.length))names.push('推弦');if(b.whammy.length)names.push('摇把');if(b.tremolo)names.push('震音');return [...new Set(names)].join(' · ');}
function render(){if(!session)return;session.clamp();const d=session.draft,bar=session.currentBar;
  $('undo').disabled=!session.undoStack.length||busy;$('redo').disabled=!session.redoStack.length||busy;
  $('save').textContent=session.dirty||!savedHere?'保存':'已保存';$('prev').disabled=session.bar===0;$('next').disabled=session.bar===d.bars.length-1;
  const choice=$('barChoice');choice.replaceChildren();d.bars.forEach((b,i)=>{const o=document.createElement('option');o.value=i;o.textContent=`第 ${i+1} 小节${b.review.length?' · 待核对':''}`;choice.append(o);});choice.value=session.bar;
  $('selection').textContent=`第 ${session.beat+1} 拍位 · 第 ${session.string} 弦`;
  const actual=bar.beats.reduce((n,b)=>n+core.ticks(b),0),expected=(bar.numerator??d.numerator)*3840/(bar.denominator??d.denominator);
  $('timing').textContent=`${bar.numerator??d.numerator}/${bar.denominator??d.denominator} · ${Number((actual/960).toFixed(3))} / ${expected/960} 拍${Math.abs(actual-expected)>.01?' · 时值未齐':''}`;
  $('source').disabled=!bar.source;
  const review=[...bar.review,...session.currentBeat.review,...session.currentBeat.notes.flatMap(n=>n.review)];status(review.length?review.join('；'):'点谱面选音，数字键盘改品位；播放试听后保存。');
  $('fretValue').value=session.currentNote?.fret??'';for(const el of $('rhythm').querySelectorAll('[data-duration]'))el.classList.toggle('active',Number(el.dataset.duration)===session.currentBeat.duration);$('dots').textContent=`附点 ${session.currentBeat.dots}`;
  surface.update(d,session,schema);if(!playing)surface.seekSelection();
}
let surface,playing=false;
window.loadGuitarDraft=(draft,techniques)=>{
  schema=techniques;core.validate(draft,schema,false);session=new GuitarEdit.Session(draft,d=>core.validate(d,schema,false));
  surface=new GuitarScoreSurface($('engraving'),$('noteTargets'),(bar,beat,string)=>{session.bar=bar;select(beat,string);surface.seekSelection();},state=>{playing=state.playing;$('play').disabled=!state.ready;$('play').textContent=state.ready?(playing?'暂停':'播放'):'加载音色';},status);
  window.scoreEditor=surface;render();document.body.removeAttribute('data-loading');
};
window.loadEditorSoundFont=base64=>surface.loadSoundFont(Uint8Array.from(atob(base64),c=>c.charCodeAt(0)));
window.pauseGuitarEditor=()=>surface?.pause();
window.disposeGuitarEditor=()=>surface?.destroy();
window.guitarReply=(result)=>{busy=false;document.body.inert=false;if(result.saved){session.saved=JSON.stringify(session.draft);savedHere=true;render();}if(result.source){$('sourceImage').src='data:image/jpeg;base64,'+result.source;$('reference').hidden=false;}status(result.message||'');};
window.guitarRequestClose=()=>{surface?.pause();if(session?.dirty)send('closeDirty');else send('close');};
$('close').onclick=()=>window.guitarRequestClose();

$('undo').onclick=()=>perform(()=>session.undo());$('redo').onclick=()=>perform(()=>session.redo());
$('save').onclick=()=>{if(busy)return;surface.pause();busy=true;document.body.inert=true;send('save',{draft:session.draft});};
$('prev').onclick=()=>perform(()=>{session.bar--;session.beat=0;});$('next').onclick=()=>perform(()=>{session.bar++;session.beat=0;});$('barChoice').onchange=e=>perform(()=>{session.bar=Number(e.target.value);session.beat=0;});
$('source').onclick=()=>{if(!busy&&session.currentBar.source){busy=true;document.body.inert=true;send('source',{source:session.currentBar.source});}};$('hideSource').onclick=()=>{$('reference').hidden=true;};
$('preview').onclick=()=>{document.body.classList.toggle('reading');$('preview').textContent=document.body.classList.contains('reading')?'编辑':'阅读';surface.api.render();};
$('play').onclick=()=>{if(playing)surface.pause();else{send('activateAudio');surface.play();}};$('stop').onclick=()=>surface.stop();
$('loop').onclick=()=>{const enabled=$('loop').getAttribute('aria-pressed')!=='true';$('loop').setAttribute('aria-pressed',String(enabled));surface.loop(enabled);};
$('zoomIn').onclick=()=>surface.zoom(.15);$('zoomOut').onclick=()=>surface.zoom(-.15);
$('keypadToggle').onclick=()=>document.body.classList.toggle('hideKeypad');
$('rhythmMenu').onclick=()=>{$('rhythm').scrollIntoView({block:'nearest'});};
$('stringUp').onclick=()=>select(session.beat,Math.max(1,session.string-1));$('stringDown').onclick=()=>select(session.beat,Math.min(6,session.string+1));
$('beatLeft').onclick=()=>select(Math.max(0,session.beat-1),session.string);$('beatRight').onclick=()=>select(Math.min(session.currentBar.beats.length-1,session.beat+1),session.string);
for(const [id,fn] of Object.entries({rest:()=>session.rest(),insertBefore:()=>session.insertBeat(),insertAfter:()=>session.insertBeat(true),deleteNote:()=>session.deleteNote(),deleteBeat:()=>session.deleteBeat(),fill:()=>session.fill(core),review:()=>session.change(()=>{session.currentBar.review=[];session.currentBar.beats.forEach(b=>{b.review=[];b.notes.forEach(n=>{if(n.fret!=null)n.review=[];});});})}))$(id).onclick=()=>perform(fn);
for(const n of [1,2,4,8,16,32,64]){const b=button(`1/${n}`,()=>session.change(()=>{session.currentBeat.duration=n;session.currentBeat.review=session.currentBeat.review.filter(x=>!x.includes('时值'));}),$('rhythm'));b.dataset.duration=n;}
const dots=button('附点 0',()=>session.change(()=>session.currentBeat.dots=(session.currentBeat.dots+1)%3),$('rhythm'));dots.id='dots';
button('连音',()=>{panel('连音与拍位');field('几个音',session.currentBeat.tupletNumerator,v=>session.change(()=>session.currentBeat.tupletNumerator=v));field('占几个音的时间',session.currentBeat.tupletDenominator,v=>session.change(()=>session.currentBeat.tupletDenominator=v));button('三连音 3:2',()=>session.change(()=>{session.currentBeat.tupletNumerator=3;session.currentBeat.tupletDenominator=2;}),$('panelBody'));button('普通时值',()=>session.change(()=>{session.currentBeat.tupletNumerator=1;session.currentBeat.tupletDenominator=1;}),$('panelBody'));text('连音设置作用于当前拍位，请对组内其他拍位设置相同比例。');},$('rhythm'));
for(const i of [7,8,9,4,5,6,1,2,3,0])button(String(i),()=>{const now=Date.now();digitText=now-digitTime<1200?digitText+String(i):String(i);if(digitText.length>2||Number(digitText)>36)digitText=String(i);digitTime=now;session.setFret(Number(digitText));},$('keypad'));
button('删除',()=>session.deleteNote(),$('keypad'));button('休止',()=>session.rest(),$('keypad'));
const fret=document.createElement('input');fret.id='fretValue';fret.type='number';fret.min=0;fret.max=36;fret.setAttribute('aria-label','当前品位');fret.onchange=()=>perform(()=>session.setFret(fret.value===''?null:Number(fret.value)));$('keypad').append(fret);
button('清空',()=>session.setFret(null),$('keypad'));
$('panelClose').onclick=()=>{$('panel').close();render();};
$('settings').onclick=()=>{panel('曲谱设置');field('曲名',session.draft.title,v=>session.change(d=>d.title=v));field('速度 BPM',session.draft.tempo,v=>session.change(d=>d.tempo=v));field('拍号分子',session.draft.numerator,v=>session.change(d=>d.numerator=v));field('拍号分母',session.draft.denominator,v=>session.change(d=>d.denominator=v),[1,2,4,8,16,32].map(n=>[String(n),n]));field('变调夹',session.draft.capo,v=>session.change(d=>d.capo=v));field('音色',session.draft.program,v=>session.change(d=>d.program=v),[['电吉他清音',27],['电吉他爵士',26],['电吉他闷音',28],['过载',29],['失真',30],['泛音',31]]);text('调弦使用 MIDI 音高：标准 E2 A2 D3 G3 B3 E4 = 40 45 50 55 59 64。修改拍号保留全部音符，请再核对各小节时值。');for(let i=0;i<6;i++)field(`第 ${6-i} 弦`,session.draft.tuning[i],v=>session.change(d=>d.tuning[i]=v));};
$('bars').onclick=()=>{
  panel('小节与空白间隔');
  heading(`第 ${session.bar+1} 小节 · 局部间隔`);
  text('在当前位置插入空白小节；原有音符保留，操作可撤销。删除已有空白时，先选中该小节再点“删除本小节”。');
  const count=field('插入空白小节数',1,()=>{});count.min=1;count.max=99;count.step=1;
  const error=document.createElement('p');error.setAttribute('role','alert');$('panelBody').append(error);
  for(const [label,before] of [['在本小节前插入',true],['在本小节后插入',false]]){
    button(label,()=>{try{session.insertEmptyBars(Number(count.value),before);$('panel').close();}catch(e){error.textContent=e.message;}},$('panelBody'));
  }
  heading('小节与复制');
  for(const [label,fn] of [['后插小节',()=>session.insertBar()],['删除本小节',()=>session.deleteBar()],['复制本拍位',()=>session.copy('beat')],['复制本小节',()=>session.copy('bar')],['粘贴到后面',()=>session.paste()]])button(label,fn,$('panelBody'));
  field('本小节 BPM（留 0 使用全曲）',session.currentBar.tempo||0,v=>session.change(()=>{if(v)session.currentBar.tempo=v;else delete session.currentBar.tempo;}));
  field('段落名称',session.currentBar.section,v=>session.change(()=>session.currentBar.section=v));
  field('反复开始',+session.currentBar.repeatStart,v=>session.change(()=>session.currentBar.repeatStart=!!v),[['否',0],['是',1]]);
  field('反复次数（0 关闭）',session.currentBar.repeatCount,v=>session.change(()=>session.currentBar.repeatCount=v));
  field('本小节拍号分子',session.currentBar.numerator??session.draft.numerator,v=>session.change(()=>session.currentBar.numerator=v));
  field('本小节拍号分母',session.currentBar.denominator??session.draft.denominator,v=>session.change(()=>session.currentBar.denominator=v),[1,2,4,8,16,32].map(n=>[String(n),n]));
};
function curves(scope){const isNote=scope==='note',target=()=>isNote?session.currentNote:session.currentBeat,key=isNote?'bend':'whammy';heading(isNote?'推弦曲线':'摇把曲线');const presets=isNote?[['无',[]],['半音',[{offset:0,value:0},{offset:60,value:2}]],['全音',[{offset:0,value:0},{offset:60,value:4}]],['推弦后释放',[{offset:0,value:0},{offset:30,value:4},{offset:60,value:0}]],['预推弦释放',[{offset:0,value:4},{offset:60,value:0}]]]:[['无',[]],['下压全音',[{offset:0,value:0},{offset:60,value:-4}]],['下压后返回',[{offset:0,value:0},{offset:30,value:-4},{offset:60,value:0}]]];for(const [label,points] of presets)button(label,()=>session.change(()=>target()[key]=GuitarEdit.copy(points)),$('panelBody'));field('自定义位置:半音数',target()[key].map(p=>`${p.offset}:${p.value/2}`).join(', '),v=>session.change(()=>{target()[key]=v.trim()?v.split(',').map(pair=>{const [offset,tone]=pair.trim().split(':').map(Number);return {offset,value:tone*2};}):[];}));text('自定义示例：0:0, 30:2, 60:0 表示起点原音、中间升两个半音、终点回原音。位置从 0 到 60。');}
$('techniques').onclick=()=>{panel('电吉他技巧');text('音符技巧作用于当前弦；拍位技巧作用于同时发声的音符。延音选后一个同弦同品音；击勾弦选起音。');for(const scope of ['note','beat']){heading(scope==='note'?`第 ${session.string} 弦音符`:'当前拍位');if(scope==='note'&&!session.currentNote){text('当前弦没有音符，先输入品位。');continue;}let category='';for(const spec of schema.filter(x=>x.scope===scope)){if(spec.category!==category){heading(spec.category);category=spec.category;}const target=()=>scope==='note'?session.currentNote:session.currentBeat;const current=target().effects[spec.id]??spec.default??0;const input=field(spec.label,current,v=>session.change(()=>target().effects[spec.id]=v),spec.kind==='toggle'?[['关闭',0],['开启',1]]:spec.choices);if(spec.kind==='number'){input.min=spec.min;input.max=spec.max;input.step=spec.step||1;}}curves(scope);}field('震音拨弦',session.currentBeat.tremolo,v=>session.change(()=>session.currentBeat.tremolo=v),[['关闭',0],['八分',8],['十六分',16],['三十二分',32],['六十四分',64]]);field('文字标记',session.currentBeat.text||'',v=>session.change(()=>session.currentBeat.text=v));};
document.addEventListener('keydown',e=>{if(!session||busy||['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName)||$('panel').open)return;if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();perform(()=>e.shiftKey?session.redo():session.undo());return;}if(/^\d$/.test(e.key)){e.preventDefault();[...$('keypad').querySelectorAll('button')].find(b=>b.textContent===e.key)?.click();}if(e.key==='ArrowLeft'||e.key==='ArrowRight'){e.preventDefault();perform(()=>{session.beat=Math.max(0,Math.min(session.currentBar.beats.length-1,session.beat+(e.key==='ArrowRight'?1:-1)));digitTime=0;});}if(e.key==='ArrowUp'||e.key==='ArrowDown'){e.preventDefault();perform(()=>{session.string=Math.max(1,Math.min(6,session.string+(e.key==='ArrowDown'?1:-1)));digitTime=0;});}if(e.key==='Delete'||e.key==='Backspace'){e.preventDefault();perform(()=>session.deleteNote());}});
document.addEventListener('visibilitychange',()=>{if(document.hidden)surface?.pause();});window.addEventListener('pagehide',()=>surface?.stop());
send('ready');

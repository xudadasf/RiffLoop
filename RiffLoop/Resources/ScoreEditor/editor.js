'use strict';
let session,schema,busy=false,savedHere=false;
const $=id=>document.getElementById(id),core=GuitarDraftCore;
const send=(action,payload={})=>window.webkit?.messageHandlers.guitarEditor.postMessage({action,...payload});
const status=text=>{$('status').textContent=text;};
function perform(fn,keepDigits=false){if(busy)return;surface?.pause();if(!keepDigits)session?.endDigits();try{fn();render();}catch(e){status(e.message);}}
function button(text,action,parent){const el=document.createElement('button');el.textContent=text;el.onclick=()=>perform(action,parent.id==='keypad'&&/^\d$/.test(text));parent.append(el);return el;}
function field(label,value,change,options){const row=document.createElement('label');row.append(document.createTextNode(label));const input=document.createElement(options?'select':'input');input.setAttribute('aria-label',label);if(options){for(const [name,val] of options){const o=document.createElement('option');o.value=val;o.textContent=name;input.append(o);}}else input.type=typeof value==='number'?'number':'text';input.value=value;input.onchange=()=>perform(()=>change(options||input.type==='number'?Number(input.value):input.value));row.append(input);$('panelBody').append(row);return input;}
function panel(title){surface?.pause();$('panelTitle').textContent=title;$('panelBody').replaceChildren();$('panel').showModal();}
function heading(text){const h=document.createElement('h3');h.textContent=text;$('panelBody').append(h);}
function text(value){const p=document.createElement('p');p.textContent=value;$('panelBody').append(p);}
function select(b,s,bar=session.bar){surface?.pause();if(selecting)session.startSelection();else session.clearSelection();session.bar=bar;session.beat=b;session.string=s;session.endDigits();render();}
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
  refreshTools();
  surface.update(d,session,schema);if(!playing)surface.seekSelection();
}
let surface,playing=false;
window.loadGuitarDraft=(draft,techniques)=>{
  schema=techniques;core.validate(draft,schema,false);session=new GuitarEdit.Session(draft,d=>core.validate(d,schema,false));
  surface=new GuitarScoreSurface($('engraving'),$('noteTargets'),(bar,beat,string)=>{select(beat,string,bar);surface.seekSelection();},state=>{playing=state.playing;$('play').disabled=!state.ready;$('play').textContent=state.ready?(playing?'暂停':'播放'):'加载音色';},status);
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
$('prev').onclick=()=>perform(()=>{session.clearSelection();session.bar--;session.beat=0;});$('next').onclick=()=>perform(()=>{session.clearSelection();session.bar++;session.beat=0;});$('barChoice').onchange=e=>perform(()=>{session.clearSelection();session.bar=Number(e.target.value);session.beat=0;});
$('source').onclick=()=>{if(!busy&&session.currentBar.source){busy=true;document.body.inert=true;send('source',{source:session.currentBar.source});}};$('hideSource').onclick=()=>{$('reference').hidden=true;};
$('preview').onclick=()=>{document.body.classList.toggle('reading');$('preview').textContent=document.body.classList.contains('reading')?'编辑':'阅读';surface.api.render();};
$('play').onclick=()=>{if(playing)surface.pause();else{send('activateAudio');surface.play();}};$('stop').onclick=()=>surface.stop();
$('loop').onclick=()=>{const enabled=$('loop').getAttribute('aria-pressed')!=='true';$('loop').setAttribute('aria-pressed',String(enabled));surface.loop(enabled);};
$('zoomIn').onclick=()=>surface.zoom(.15);$('zoomOut').onclick=()=>surface.zoom(-.15);
$('keypadToggle').onclick=()=>document.body.classList.toggle('hideKeypad');
function move(dx,dy,event){perform(()=>session.move(dx,dy,altMove||!!event?.altKey,selecting||!!event?.shiftKey));}
$('stringUp').onclick=e=>move(0,-1,e);$('stringDown').onclick=e=>move(0,1,e);
$('beatLeft').onclick=e=>move(-1,0,e);$('beatRight').onclick=e=>move(1,0,e);
function setSelecting(on){selecting=on;if(on)session.startSelection();else session.clearSelection();render();}
$('selectMode').onclick=()=>setSelecting(true);$('editMode').onclick=()=>setSelecting(false);
$('review').onclick=()=>perform(()=>session.change(()=>{session.currentBar.review=[];session.currentBar.beats.forEach(b=>{b.review=[];b.notes.forEach(n=>{if(n.fret!=null)n.review=[];});});}));
$('copyBeat').onclick=()=>perform(()=>session.copy('beat'));$('pasteBeat').onclick=()=>perform(()=>{session.clearSelection();session.paste();});
for(const value of [7,8,9,'erase',4,5,6,'shorter',1,2,3,'longer',0,'dot','alt','shift']){
  if(typeof value==='number'){button(String(value),()=>session.inputDigit(value),$('keypad'));continue;}
  const spec={erase:['删除',()=>session.erase(),'delete'],shorter:['缩短时值',()=>session.setDuration(Math.min(64,session.currentBeat.duration*2)),'minus'],longer:['延长时值',()=>session.setDuration(Math.max(1,session.currentBeat.duration/2)),'plus'],dot:['附点',()=>session.toggleDots(1)],alt:['Alt',()=>{altMove=!altMove;}],shift:['选择范围',()=>setSelecting(!selecting),'arrow-big-up']}[value];
  const b=button(spec[0],spec[1],$('keypad'));b.id={erase:'deleteNote',shorter:'shorter',longer:'longer',dot:'dotKey',alt:'altKey',shift:'shiftKey'}[value];
  if(spec[2]){b.setAttribute('aria-label',spec[0]);b.title=spec[0];b.replaceChildren(icon(spec[2]));}else if(value==='dot')b.textContent='.';
}
for(const [id,name] of [['selectMode','mouse-pointer-2'],['editMode','pencil'],['copyBeat','copy'],['pasteBeat','clipboard-paste']])decorated($(id),$(id).textContent,name);
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
function curves(scope){const isNote=scope==='note',target=()=>session.targets(scope)[0],key=isNote?'bend':'whammy';heading(isNote?'推弦曲线':'摇把曲线');const presets=isNote?[['无',[]],['半音',[{offset:0,value:0},{offset:60,value:2}]],['全音',[{offset:0,value:0},{offset:60,value:4}]],['推弦后释放',[{offset:0,value:0},{offset:30,value:4},{offset:60,value:0}]],['预推弦释放',[{offset:0,value:4},{offset:60,value:0}]]]:[['无',[]],['下压全音',[{offset:0,value:0},{offset:60,value:-4}]],['下压后返回',[{offset:0,value:0},{offset:30,value:-4},{offset:60,value:0}]]];for(const [label,points] of presets)button(label,()=>session.change(()=>session.targets(scope).forEach(t=>t[key]=GuitarEdit.copy(points))),$('panelBody'));field('自定义位置:半音数',target()[key].map(p=>`${p.offset}:${p.value/2}`).join(', '),v=>session.change(()=>{const points=v.trim()?v.split(',').map(pair=>{const [offset,tone]=pair.trim().split(':').map(Number);return {offset,value:tone*2};}):[];session.targets(scope).forEach(t=>t[key]=GuitarEdit.copy(points));}));text('自定义示例：0:0, 30:2, 60:0 表示起点原音、中间升两个半音、终点回原音。位置从 0 到 60。');}
function openAdvanced(ids){panel('更多技巧设置');text('设置作用于当前音符；选中一段时，作用于整段。常用技巧可直接在底部点选。');for(const scope of ['note','beat']){const ts=session.targets(scope);if(!ts.length)continue;heading(scope==='note'?'音符':'拍位');for(const spec of schema.filter(x=>x.scope===scope&&(!ids||ids.includes(x.id)))){const input=field(spec.label,ts[0].effects[spec.id]??spec.default??0,v=>session.change(()=>session.targets(scope).forEach(t=>t.effects[spec.id]=v)),spec.kind==='toggle'?[['关闭',0],['开启',1]]:spec.choices);if(spec.kind==='number'){input.min=spec.min;input.max=spec.max;input.step=spec.step||1;}}}}
document.addEventListener('keydown',e=>{
  if(!session||busy||['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName)||$('panel').open)return;
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();perform(()=>e.shiftKey?session.redo():session.undo());return;}
  if(e.metaKey||e.ctrlKey)return;
  if(/^\d$/.test(e.key)){e.preventDefault();perform(()=>session.inputDigit(Number(e.key)),true);return;}
  const actions={ArrowLeft:()=>move(-1,0,e),ArrowRight:()=>move(1,0,e),ArrowUp:()=>move(0,-1,e),ArrowDown:()=>move(0,1,e),Delete:()=>perform(()=>session.erase()),Backspace:()=>perform(()=>session.erase()),'-':()=>$('shorter').click(),'+':()=>$('longer').click(),',':()=>$('dotKey').click(),'.':()=>$('dotKey').click(),'/':()=>perform(()=>session.split()),Insert:()=>perform(()=>{session.clearSelection();session.insertBeat();}),Escape:()=>setSelecting(false)};
  const effects={l:['note','isHammerPullOrigin'],t:['note','isTieDestination'],p:['note','isPalmMute'],s:['note','isStaccato'],a:['note','accentuated'],v:['note','vibrato']};
  if(actions[e.key]){e.preventDefault();actions[e.key]();}else if(effects[e.key.toLowerCase()]){e.preventDefault();perform(()=>session.toggleEffect(...effects[e.key.toLowerCase()]));}else if(e.key.toLowerCase()==='x'){e.preventDefault();perform(()=>{if(!session.currentNote)session.setFret(0);session.toggleEffect('note','isDead');});}
});
for(const [id,name] of [['stringUp','chevron-up'],['stringDown','chevron-down'],['beatLeft','chevron-left'],['beatRight','chevron-right']])$(id).replaceChildren(icon(name));
let drag=null;
$('thumbPad').onpointerdown=e=>{if(busy||!session)return;e.preventDefault();$('thumbPad').setPointerCapture(e.pointerId);drag={x:e.clientX,y:e.clientY};};
$('thumbPad').onpointermove=e=>{if(!drag)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;if(Math.max(Math.abs(dx),Math.abs(dy))<28)return;const horizontal=Math.abs(dx)>Math.abs(dy);move(horizontal?Math.sign(dx):0,horizontal?0:Math.sign(dy),e);drag={x:e.clientX,y:e.clientY};};
$('thumbPad').onpointerup=$('thumbPad').onpointercancel=()=>{drag=null;};
initTools();
document.addEventListener('visibilitychange',()=>{if(document.hidden)surface?.pause();});window.addEventListener('pagehide',()=>surface?.stop());
send('ready');

'use strict';
let session,schema,busy=false,savedHere=false,existingGP,pendingFont,barMenuRevision;
const $=id=>document.getElementById(id),core=GuitarDraftCore;
const send=(action,payload={})=>window.webkit?.messageHandlers.guitarEditor.postMessage({action,...payload});
const status=text=>{$('status').textContent=text;};
function perform(fn,keepDigits=false){if(busy)return;surface?.pause();if(!keepDigits)session?.endDigits();const before=session&&[session.revision,session.bar,session.beat,session.string].join(':');try{fn();render(!session.noteRange&&!session.anchor?.wholeBars&&before!==[session.revision,session.bar,session.beat,session.string].join(':'));}catch(e){status(e.message);if($('panel').open)$('panelError').textContent=e.message;}}
function button(text,action,parent){const el=document.createElement('button');el.textContent=text;el.onclick=()=>perform(action,parent.id==='keypad'&&/^\d$/.test(text));parent.append(el);return el;}
function field(label,value,change,options){const row=document.createElement('label');row.append(document.createTextNode(label));const input=document.createElement(options?'select':'input');input.setAttribute('aria-label',label);if(options){for(const [name,val] of options){const o=document.createElement('option');o.value=val;o.textContent=name;input.append(o);}}else input.type=typeof value==='number'?'number':'text';input.value=value;input.onchange=()=>perform(()=>change(options||input.type==='number'?Number(input.value):input.value));row.append(input);$('panelBody').append(row);return input;}
function panel(title){surface?.pause();$('panelTitle').textContent=title;$('panelBody').replaceChildren();$('panelError').textContent='';if(!$('panel').open)$('panel').showModal();}
function heading(text){const h=document.createElement('h3');h.textContent=text;$('panelBody').append(h);}
function text(value){const p=document.createElement('p');p.textContent=value;$('panelBody').append(p);}
function select(beat,string,bar=session.bar){
  surface?.pause();
  if(selecting&&session.noteRange){
    session.togglePickedNote(bar,beat,string);
    if(!session.noteRange)selecting=false;
  }else{
    if(selecting)session.startSelection();else session.clearSelection();
    Object.assign(session,{bar,beat,string});
    session.endDigits();
  }
  render();
}
function markers(b){let names=[];if(b.tupletNumerator!==b.tupletDenominator)names.push(`${b.tupletNumerator}:${b.tupletDenominator}`);for(const spec of schema){let val=spec.scope==='beat'?b.effects[spec.id]:null;if(spec.scope==='note'){if(b.notes.some(n=>n.effects[spec.id]!==undefined&&n.effects[spec.id]!==0&&n.effects[spec.id]!==spec.default))names.push(spec.label);}else if(val!==undefined&&val!==0&&val!==spec.default)names.push(spec.label);}if(b.notes.some(n=>n.bend.length))names.push('推弦');if(b.whammy.length)names.push('摇把');if(b.tremolo)names.push('震音');return [...new Set(names)].join(' · ');}
function render(reveal=false){if(!session)return;session.clamp();const d=session.draft,bar=session.currentBar;
  $('undo').disabled=!session.undoStack.length||busy;$('redo').disabled=!session.redoStack.length||busy;
  $('save').textContent=session.dirty||!savedHere?'保存':'已保存';$('prev').disabled=session.bar===0;$('next').disabled=session.bar===d.bars.length-1;
  const choice=$('barChoice');
  if(barMenuRevision!==session.revision){
    while(choice.options.length>d.bars.length)choice.remove(choice.options.length-1);
    d.bars.forEach((b,i)=>{
      const label=`第 ${i+1} 小节${b.review.length?' · 待核对':''}`;
      const option=choice.options[i];
      if(!option)choice.add(new Option(label,String(i)));
      else if(option.text!==label)option.text=label;
    });
    barMenuRevision=session.revision;
  }
  choice.value=session.bar;
  $('selection').textContent=session.noteRange?noteRangeLabel():session.anchor?.wholeBars?barRangeLabel():`第 ${session.beat+1} 拍位 · 第 ${session.string} 弦`;
  const actual=bar.beats.reduce((n,b)=>n+core.ticks(b),0),expected=(bar.numerator??d.numerator)*3840/(bar.denominator??d.denominator);
  $('timing').textContent=`${bar.numerator??d.numerator}/${bar.denominator??d.denominator} · ${Number((actual/960).toFixed(3))} / ${expected/960} 拍${Math.abs(actual-expected)>.01?' · 时值未齐':''}`;
  $('source').disabled=!bar.source;
  const review=[...bar.review,...session.currentBeat.review,...session.currentBeat.notes.flatMap(n=>n.review)];status(review.length?review.join('；'):'长按音符拖选多个音，长按小节空白处拖选整段。');
  refreshTools();
  surface.update(d,session,schema,reveal);if(!playing)surface.seekSelection();
}
let surface,playing=false;
let previousCursor;
function barRangeLabel(){
  const first=session.firstBar+1,last=session.lastBar+1;
  return first===last?`已选第 ${first} 小节`:`已选第 ${first}–${last} 小节`;
}
function noteRangeLabel(){return `已选 ${session.targets('note').length} 个音符`;}
function previewRange(first,last){
  if(typeof first==='number')session.selectBars(first,last);
  else session.selectNotes(first,last);
  surface.paintBarRange();
  surface.paintNoteRange();
  $('selection').textContent=session.noteRange?noteRangeLabel():barRangeLabel();
}
const rangeSelection={
  begin(first){
    previousCursor={bar:session.bar,beat:session.beat,string:session.string,anchor:session.anchor};
    surface.clearCursorHighlight();
    previewRange(first,first);
  },
  extend:previewRange,
  end(cancel){
    if(cancel)Object.assign(session,previousCursor);
    else selecting=false;
    previousCursor=null;
    render();
  }
};
window.loadGuitarDraft=(draft,techniques)=>{
  schema=techniques;core.validate(draft,schema,false);session=new GuitarEdit.Session(draft,d=>{core.validate(d,schema,false);if(existingGP)GuitarGP.check(existingGP,d);});
  barMenuRevision=undefined;
  session.sourceStaff=existingGP?.option.staff;
  surface=new GuitarScoreSurface($('engraving'),$('noteTargets'),(bar,beat,string)=>{select(beat,string,bar);surface.seekSelection();},state=>{playing=state.playing;$('play').disabled=!state.ready;$('play').textContent=state.ready?(playing?'暂停':'播放'):'加载音色';},status,rangeSelection);
  window.scoreEditor=surface;render(true);document.body.removeAttribute('data-loading');
};
window.loadEditorSoundFont=base64=>{
  if(surface)surface.loadSoundFont(Uint8Array.from(atob(base64),c=>c.charCodeAt(0)));else pendingFont=base64;
};
window.loadExistingGuitarGP=(encoded,techniques)=>{
  const bytes=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0));
  const file=GuitarGP.open(bytes,techniques);
  function select(option){
    existingGP=GuitarGP.select(file,option);
    $('panel').close();$('panelClose').textContent='完成';loadGuitarDraft(existingGP.draft,techniques);
    $('settings').disabled=true;$('bars').disabled=true;
    $('selection').title=option.label;
    if(pendingFont){loadEditorSoundFont(pendingFont);pendingFont=null;}
    status('正在编辑 '+option.label+'，保存将更新整份 GP。');
  }
  if(file.options.length===1){select(file.options[0]);return;}
  panel('选择要编辑的吉他声部');text('保存会更新整份 GP，其他轨道和声部保留。');
  for(const option of file.options)button(option.label,()=>select(option),$('panelBody'));
  $('panelClose').textContent='返回';
};
window.pauseGuitarEditor=()=>surface?.pause();
window.disposeGuitarEditor=()=>surface?.destroy();
window.guitarReply=(result)=>{busy=false;document.body.inert=false;if(result.saved&&session){session.saved=session.serializedDraft;savedHere=true;render();}if(result.source){$('sourceImage').src='data:image/jpeg;base64,'+result.source;$('reference').hidden=false;}status(result.message||'');};
window.guitarRequestClose=()=>{surface?.pause();if(session?.dirty)send('closeDirty');else send('close');};
$('close').onclick=()=>window.guitarRequestClose();

$('undo').onclick=()=>perform(()=>session.undo());$('redo').onclick=()=>perform(()=>session.redo());
$('save').onclick=()=>{if(busy)return;surface.pause();
  if(existingGP){
    try{
      const bytes=GuitarGP.save(existingGP,session.draft),chunks=[];
      for(let i=0;i<bytes.length;i+=8192)chunks.push(String.fromCharCode(...bytes.subarray(i,i+8192)));
      busy=true;document.body.inert=true;send('saveGP',{file:btoa(chunks.join(''))});
    }catch(e){busy=false;document.body.inert=false;status(e.message);}
  }else{busy=true;document.body.inert=true;send('save',{draft:session.draft});}};
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
function setSelecting(on){
  selecting=on;
  if(on){
    if(session.anchor?.wholeBars)session.clearSelection();
    session.startSelection();
  }else if(!session.noteRange)session.clearSelection();
  render();
}
$('selectMode').onclick=()=>setSelecting(true);$('editMode').onclick=()=>setSelecting(false);
$('review').onclick=()=>perform(()=>session.change(()=>{if(session.noteRange){session.targets('note').forEach(n=>{if(n.fret!=null)n.review=[];});return;}for(const bar of session.draft.bars.slice(session.firstBar,session.lastBar+1)){if(session.anchor?.wholeBars||!session.anchor)bar.review=[];}(session.anchor?session.selectedBeats:session.currentBar.beats).forEach(b=>{b.review=[];b.notes.forEach(n=>{if(n.fret!=null)n.review=[];});});}));

$('copyBeat').onclick=()=>perform(()=>{session.copy('beat');if(session.noteRange)selecting=false;});$('pasteBeat').onclick=()=>perform(()=>session.paste());
for(const value of [7,8,9,'erase',4,5,6,'shorter',1,2,3,'longer',0,'dot','alt','shift']){
  if(typeof value==='number'){button(String(value),()=>session.inputDigit(value),$('keypad'));continue;}
  const spec={erase:['删除',()=>session.erase(),'delete'],shorter:['缩短时值',()=>session.setDuration(Math.min(64,session.currentBeat.duration*2)),'minus'],longer:['延长时值',()=>session.setDuration(Math.max(1,session.currentBeat.duration/2)),'plus'],dot:['附点',()=>session.toggleDots(1)],alt:['Alt',()=>{altMove=!altMove;}],shift:['选择范围',()=>setSelecting(!selecting),'arrow-big-up']}[value];
  const b=button(spec[0],spec[1],$('keypad'));b.id={erase:'deleteNote',shorter:'shorter',longer:'longer',dot:'dotKey',alt:'altKey',shift:'shiftKey'}[value];
  if(spec[2]){b.setAttribute('aria-label',spec[0]);b.title=spec[0];b.replaceChildren(icon(spec[2]));}else if(value==='dot')b.textContent='.';
}
for(const [id,name] of [['selectMode','mouse-pointer-2'],['editMode','pencil'],['copyBeat','copy'],['pasteBeat','clipboard-paste']])decorated($(id),$(id).textContent,name);
$('panel').addEventListener('cancel',event=>{
  if(!session){event.preventDefault();send('close');}
});
$('panelClose').onclick=()=>{if(!session){send('close');return;}$('panel').close();render();};
$('settings').onclick=()=>{panel('曲谱设置');field('曲名',session.draft.title,v=>session.change(d=>d.title=v));field('速度 BPM',session.draft.tempo,v=>session.change(d=>d.tempo=v));field('拍号分子',session.draft.numerator,v=>session.change(d=>d.numerator=v));field('拍号分母',session.draft.denominator,v=>session.change(d=>d.denominator=v),[1,2,4,8,16,32].map(n=>[String(n),n]));field('变调夹',session.draft.capo,v=>session.change(d=>d.capo=v));field('音色',session.draft.program,v=>session.change(d=>d.program=v),[['电吉他清音',27],['电吉他爵士',26],['电吉他闷音',28],['过载',29],['失真',30],['泛音',31]]);text('调弦使用 MIDI 音高：标准 E2 A2 D3 G3 B3 E4 = 40 45 50 55 59 64。修改拍号保留全部音符，请再核对各小节时值。');for(let i=0;i<6;i++)field(`第 ${6-i} 弦`,session.draft.tuning[i],v=>session.change(d=>d.tuning[i]=v));};
$('bars').onclick=()=>{
  panel('小节与空白间隔');
  const count=field('插入空白小节数',1,()=>{});count.min=1;count.max=99;count.step=1;count.onchange=null;
  const error=$('panelError');
  for(const [label,before] of [['在本小节前插入',true],['在本小节后插入',false]]){
    button(session.anchor?.wholeBars?label.replace('本小节','选区'):label,()=>{try{session.insertEmptyBars(Number(count.value),before);$('panel').close();}catch(e){error.textContent=e.message;}},$('panelBody'));
  }
  heading('小节与复制');
  for(const [label,fn] of [['后插小节',()=>session.insertBar()],[session.anchor?.wholeBars?'删除所选小节':'删除本小节',()=>{session.deleteBar();$('panel').close();}],[session.anchor?'复制选区':'复制本拍位',()=>session.copy('beat')],...(session.anchor?.wholeBars?[]:[['复制本小节',()=>session.copy('bar')]]),['粘贴到后面',()=>{session.paste();$('panel').close();}]])button(label,()=>{fn();if($('panel').open)$('panel').close();},$('panelBody'));
  const bars=session.anchor?.wholeBars?session.draft.bars.slice(session.firstBar,session.lastBar+1):[session.currentBar];
  const scope=bars.length>1?'选区':'本小节';
  // Resolve the bars on change: undo or validation can replace draft objects.
  const changeBars=fn=>session.change(()=>{
    const selected=session.anchor?.wholeBars?session.draft.bars.slice(session.firstBar,session.lastBar+1):[session.currentBar];
    selected.forEach(fn);
  });
  field(scope+' BPM（留 0 使用全曲）',session.currentBar.tempo||0,v=>changeBars(b=>{if(v)b.tempo=v;else delete b.tempo;}));
  heading('第 '+(session.bar+1)+' 小节标记');
  field('段落名称',session.currentBar.section,v=>session.change(()=>session.currentBar.section=v));
  field('反复开始',+session.currentBar.repeatStart,v=>session.change(()=>session.currentBar.repeatStart=!!v),[['否',0],['是',1]]);
  field('反复次数（0 关闭）',session.currentBar.repeatCount,v=>session.change(()=>session.currentBar.repeatCount=v));
  field(scope+'拍号分子',session.currentBar.numerator??session.draft.numerator,v=>changeBars(b=>b.numerator=v));
  field(scope+'拍号分母',session.currentBar.denominator??session.draft.denominator,v=>changeBars(b=>b.denominator=v),[1,2,4,8,16,32].map(n=>[String(n),n]));
};
document.addEventListener('keydown',e=>{
  if(!session||busy||['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName)||$('panel').open)return;
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();perform(()=>e.shiftKey?session.redo():session.undo());return;}
  if(e.metaKey||e.ctrlKey)return;
  if(/^\d$/.test(e.key)){e.preventDefault();perform(()=>session.inputDigit(Number(e.key)),true);return;}
  const actions={ArrowLeft:()=>move(-1,0,e),ArrowRight:()=>move(1,0,e),ArrowUp:()=>move(0,-1,e),ArrowDown:()=>move(0,1,e),Delete:()=>perform(()=>session.erase()),Backspace:()=>perform(()=>session.erase()),'-':()=>$('shorter').click(),'+':()=>$('longer').click(),',':()=>$('dotKey').click(),'.':()=>$('dotKey').click(),'/':()=>perform(()=>session.split()),Insert:()=>perform(()=>{selecting=false;session.insertBeat(false,true);}),Escape:()=>setSelecting(false)};
  const effects={l:['note','isHammerPullOrigin'],t:['note','isTieDestination'],p:['note','isPalmMute'],s:['note','isStaccato'],a:['note','accentuated'],v:['note','vibrato']};
  if(actions[e.key]){e.preventDefault();actions[e.key]();}else if(effects[e.key.toLowerCase()]){e.preventDefault();perform(()=>session.toggleEffect(...effects[e.key.toLowerCase()]));}else if(e.key.toLowerCase()==='x'){e.preventDefault();perform(()=>{if(!session.anchor&&!session.currentNote)session.setFret(0);session.toggleEffect('note','isDead');});}
});
for(const [id,name] of [['stringUp','chevron-up'],['stringDown','chevron-down'],['beatLeft','chevron-left'],['beatRight','chevron-right']])$(id).replaceChildren(icon(name));
new GuitarJoystick(document.querySelector('.navButtons'),(dx,dy)=>{
  if(!session||busy||$('panel').open||document.body.classList.contains('reading'))return;
  if(dy&&!(session.string+dy>=1&&session.string+dy<=6))return;
  if(dx>0&&session.bar===session.draft.bars.length-1&&session.beat===session.currentBar.beats.length-1)return;
  perform(()=>session.move(dx,dy,false,selecting));
},()=>surface?.revealSelection());
$('thumbPad').onclick=()=>surface?.revealSelection();
// Keep long-press menus off controls while retaining standard text-field editing.
document.addEventListener('contextmenu',e=>{
  if(e.target.closest?.('button'))e.preventDefault();
});
initTools();
document.addEventListener('visibilitychange',()=>{if(document.hidden)surface?.pause();});window.addEventListener('pagehide',()=>surface?.stop());
send('ready');

'use strict';
// Tool categories mirror the musical editing task. Buttons keep the score and
// cursor available; only parameter-heavy controls open a small settings sheet.
let activeTool='rhythm',selecting=false,altMove=false,toolRefresh=[];
const categories=[['rhythm','节奏',0xE1D7],['dynamics','力度','mf'],['articulation','奏法','accent'],['effect','效果','audio-lines'],['harmonic','泛音','diamond'],['beat','拍','panel-top'],['attach','附加','paperclip'],['note','音符','corner-right-up']];
const musicFont=document.fonts.load('28px EditorMusic');
function glyph(symbol){
  const canvas=document.createElement('canvas');
  canvas.className='musicSymbol';
  canvas.setAttribute('aria-hidden','true');
  const size=32,scale=window.devicePixelRatio||1;
  canvas.width=canvas.height=Math.round(size*scale);
  musicFont.then(()=>{
    const ctx=canvas.getContext('2d');
    const value=String.fromCodePoint(symbol);
    ctx.font='28px EditorMusic';
    const metrics=ctx.measureText(value);
    const width=metrics.actualBoundingBoxLeft+metrics.actualBoundingBoxRight;
    const height=metrics.actualBoundingBoxAscent+metrics.actualBoundingBoxDescent;
    const fit=Math.min(1,(size-4)/Math.max(1,width,height));
    ctx.scale(scale*fit,scale*fit);
    ctx.fillStyle='white';
    ctx.fillText(value,(size/fit-width)/2+metrics.actualBoundingBoxLeft,
      (size/fit-height)/2+metrics.actualBoundingBoxAscent);
  });
  return canvas;
}
function icon(name){const img=document.createElement('img');img.src=`icons/${name}.svg`;img.alt='';img.className='toolIcon';return img;}
function decorated(el,label,visual){el.setAttribute('aria-label',label);el.title=label;el.replaceChildren();if(typeof visual==='number')el.append(glyph(visual));else if(visual)el.append(icon(visual));const caption=document.createElement('span');caption.textContent=label;el.append(caption);return el;}
function tool(label,action,options={}){const b=button(label,action,$('toolStrip'));if(options.id)b.id=options.id;b.classList.add('toolButton');if(options.symbol)decorated(b,label,options.symbol);if(options.active||options.disabled)toolRefresh.push(()=>{b.disabled=!!options.disabled?.();if(options.active)b.setAttribute('aria-pressed',String(!!options.active()));});return b;}
function effect(label,scope,id,value=1,defaultValue=0,symbol){return tool(label,()=>session.toggleEffect(scope,id,value,defaultValue),{symbol,active:()=>{const ts=session.effectTargets(scope,id,value);return ts.length&&ts.every(t=>(t.effects[id]??defaultValue)===value);},disabled:()=>!session.targets(scope).length});}
function preset(label,scope,key,value){return tool(label,()=>{const ts=session.targets(scope),clear=ts.every(t=>JSON.stringify(t[key])===JSON.stringify(value));session.setCurve(scope,clear?[]:value);},{active:()=>{const ts=session.targets(scope);return ts.length&&ts.every(t=>JSON.stringify(t[key])===JSON.stringify(value));},disabled:()=>!session.targets(scope).length});}
function chooseTool(name){if(busy)return;activeTool=name;session?.endDigits();buildTools();if(session){refreshTools();}}
function buildTools(){
  $('toolStrip').replaceChildren();toolRefresh=[];
  for(const b of $('toolTabs').children){const on=b.dataset.tool===activeTool;b.setAttribute('aria-selected',String(on));b.classList.toggle('active',on);}
  const noteReady=()=>!session.targets('note').length;
  if(['effect','note'].includes(activeTool))tool('已用技巧',appliedTechniques,{id:'appliedTechniques'});
  if(activeTool==='rhythm'){
    for(const [n,symbol] of [[1,0xE1D2],[2,0xE1D3],[4,0xE1D5],[8,0xE1D7],[16,0xE1D9],[32,0xE1DB],[64,0xE1DD]]){const b=tool(`1/${n}`,()=>session.setDuration(n),{symbol,active:()=>session.selectedBeats.every(b=>b.duration===n)});b.dataset.duration=n;}
    tool('附点',()=>session.toggleDots(1),{id:'dots',active:()=>session.selectedBeats.every(b=>b.dots===1)});
    tool('双附点',()=>session.toggleDots(2),{active:()=>session.selectedBeats.every(b=>b.dots===2)});
    effect('延音','note','isTieDestination');
    tool('变休止',()=>session.noteRange?session.removeSelectedNotes():session.change(()=>session.selectedBeats.forEach(b=>b.notes=[])),{id:'rest',symbol:0xE4E5});
  }else if(activeTool==='dynamics'){
    ['ppp','pp','p','mp','mf','f','ff','fff'].forEach((name,i)=>effect(name,'beat','dynamics',i,5));
    effect('渐强','beat','crescendo',1);effect('渐弱','beat','crescendo',2);effect('音量渐入','beat','fade',1);effect('音量渐出','beat','fade',2);effect('音量起伏','beat','fade',3);
  }else if(activeTool==='articulation'){
    effect('重音','note','accentuated',1,0,0xE4A0);effect('强重音','note','accentuated',2,0,0xE4AC);effect('断音','note','isStaccato',1,0,0xE4A2);effect('保持音','note','accentuated',3);
    effect('虚音','note','isGhost');effect('闷音 X','note','isDead');effect('下拨','beat','pickStroke',2);effect('上拨','beat','pickStroke',1);
    effect('琶音上行','beat','brushType',3);effect('琶音下行','beat','brushType',4);effect('向下扫弦','beat','brushType',2);effect('向上扫弦','beat','brushType',1);
  }else if(activeTool==='effect'){
    effect('击勾弦 H/P','note','isHammerPullOrigin');effect('滑音','note','slideOutType',1);effect('连滑音','note','slideOutType',2);
    effect('揉弦','note','vibrato',1);effect('宽揉弦','note','vibrato',2);effect('掌根闷音 P.M.','note','isPalmMute');effect('持续发声','note','isLetRing');
    effect('向上滑出','note','slideOutType',3);effect('向下滑出','note','slideOutType',4);effect('从低音滑入','note','slideInType',1);effect('从高音滑入','note','slideInType',2);
    effect('踏板踩下 Ped.','beat','sustainPedal',1);effect('踏板松开 ✱','beat','sustainPedal',2);
    tool('摇把曲线',()=>{panel('摇把曲线');curves('beat');});effect('摇把轻揉','beat','vibrato',1);effect('摇把宽揉','beat','vibrato',2);effect('左手点弦','note','isLeftHandTapped');effect('向下刮弦','note','slideOutType',5);effect('向上刮弦','note','slideOutType',6);effect('拍击闷音','beat','deadSlapped');effect('拇指敲击','beat','golpe',1);effect('手指敲击','beat','golpe',2);effect('点弦','beat','tap');effect('Slap','beat','slap');effect('Pop','beat','pop');
  }else if(activeTool==='harmonic'){
    ['自然泛音','人工泛音','拨片泛音','点弦泛音','半泛音','反馈泛音'].forEach((label,i)=>effect(label,'note','harmonicType',i+1));
    tool('泛音音高',()=>{panel('泛音音高');field('泛音音高',core.harmonicNode(session.targets('note')[0]),v=>session.change(()=>session.targets('note').forEach(n=>n.effects.harmonicValue=v)));},{disabled:noteReady});
  }else if(activeTool==='beat'){
    for(const [label,after,noteEntry,id] of [['前插音符',false,true,'insertBefore'],['前插休止',false,false,'insertRestBefore'],['后插音符',true,true,'insertAfter'],['后插休止',true,false,'insertRestAfter']])tool(label,()=>{selecting=false;session.insertBeat(after,noteEntry);},{id});
    tool('拆分',()=>session.split(),{id:'splitBeat'});
    tool('原位复制选区',()=>{session.copy('beat');session.paste();},{id:'duplicateBeat'});
    tool('删除拍',()=>session.deleteBeat(),{id:'deleteBeat'});
    for(const n of [3,2,4,5,6,7,8,9])tool(`${n} 连音`,()=>session.tuplet(n,core),{active:()=>session.currentBeat.tupletNumerator===n});
    tool('补齐休止',()=>session.fill(core),{id:'fill'});
    tool('自定连音',()=>{panel('连音比例');field('几个音',session.currentBeat.tupletNumerator,v=>session.change(()=>session.selectedBeats.forEach(b=>b.tupletNumerator=v)));field('占几个音的时间',session.currentBeat.tupletDenominator,v=>session.change(()=>session.selectedBeats.forEach(b=>b.tupletDenominator=v)));});
  }else if(activeTool==='attach'){
    tool('文字',()=>{panel('文字标记');field('文字标记',session.currentBeat.text||'',v=>session.change(()=>session.currentBeat.text=v));});
    tool('段落',()=>{panel('段落名称');field('段落名称',session.currentBar.section||'',v=>session.change(()=>session.currentBar.section=v));});
    tool('左手指法',()=>openAdvanced(['leftHandFinger']));tool('右手指法',()=>openAdvanced(['rightHandFinger']));effect('显示弦号','note','showStringNumber');tool('小节设置',()=>$('bars').click());
  }else if(activeTool==='note'){
    effect('连奏','beat','isLegatoOrigin');tool('颤音 / 回音',()=>openAdvanced(['note:trillValue','note:trillSpeed','note:ornament']));
    tool('加前倚音', ()=>{session.clearSelection();session.change(()=>{if(!session.currentBeat.notes.length)throw Error('先选中音符。');const b=GuitarEdit.copy(session.currentBeat);b.duration=8;b.dots=0;b.tupletNumerator=1;b.tupletDenominator=1;b.effects={graceType:2};b.notes.forEach(n=>{n.effects={};n.bend=[];});b.whammy=[];b.tremolo=0;b.text='';session.currentBar.beats.splice(session.beat,0,b);});},{disabled:()=>session.noteRange||session.anchor?.wholeBars||noteReady()});
    preset('半音推弦','note','bend',[{offset:0,value:0},{offset:60,value:2}]);preset('全音推弦','note','bend',[{offset:0,value:0},{offset:60,value:4}]);
    preset('推弦释放','note','bend',[{offset:0,value:0},{offset:30,value:4},{offset:60,value:0}]);preset('预推释放','note','bend',[{offset:0,value:4},{offset:60,value:0}]);
    tool('升半音',()=>session.transpose(1),{disabled:noteReady});tool('降半音',()=>session.transpose(-1),{disabled:noteReady});
    tool('品位 / 待核对',()=>{panel('当前音符');field('当前品位（留空待核对）',String(session.currentNote?.fret??''),v=>session.setFret(v.trim()===''?null:Number(v)));});
    tool('推弦曲线',()=>{panel('推弦曲线');curves('note');},{disabled:noteReady});
    [8,16,32,64].forEach((v,i)=>tool(`震音 ${i+1}`,()=>{const next=session.selectedBeats.every(b=>b.tremolo===v)?0:v;session.change(()=>session.selectedBeats.forEach(b=>b.tremolo=next));},{symbol:0xE220+i,active:()=>session.selectedBeats.every(b=>b.tremolo===v)}));
  }
  if(!['beat','rhythm','attach'].includes(activeTool))tool('更多设置',()=>openAdvanced());
}
function refreshTools(){for(const update of toolRefresh)update();$('toolHint').textContent=session.noteRange?(selecting?'轻点音符增减 · 编辑退出':'点「选择」逐音增减 · 时值按拍'):session.anchor?.wholeBars?barRangeLabel()+' · 全弦':session.anchor?`已选 ${session.selectedBeats.length} 个拍位 · 全弦`:(activeTool==='effect'?'起音加 H/P、滑音 · 再点取消':activeTool==='beat'?'前插保留原音 · 数字键输入新音品位':activeTool==='rhythm'?'后音加延音 · 左右滑动工具条':'点选应用 · 左右滑动工具条');$('selectMode').setAttribute('aria-pressed',String(selecting));$('editMode').setAttribute('aria-pressed',String(!selecting));$('shiftKey').setAttribute('aria-pressed',String(selecting));$('altKey').setAttribute('aria-pressed',String(altMove));$('pasteBeat').disabled=!session.clipboard;
  const remove=$('deleteBeat');
  if(remove)remove.textContent=session.noteRange?'删除所选音符':session.anchor?.wholeBars?'删除所选小节':session.anchor?'删除所选拍位':'删除拍';
  const duplicate=$('duplicateBeat');
  if(duplicate)duplicate.textContent=session.anchor?'原位复制选区':'原位复制拍';
  $('copyBeat').title=session.anchor?'复制选区':'复制当前拍';
  $('pasteBeat').title=session.clipboard?.scope==='bars'?'在当前小节或选区后粘贴小节':'在当前位置后粘贴';
}
function initTools(){for(const [id,label,image] of categories){const b=document.createElement('button');b.dataset.tool=id;b.id=id==='effect'?'techniques':id==='rhythm'?'rhythmMenu':`tab-${id}`;b.setAttribute('role','tab');decorated(b,label,image==='mf'?0xE52D:image==='accent'?0xE4A0:image);b.onclick=()=>chooseTool(id);$('toolTabs').append(b);}buildTools();}

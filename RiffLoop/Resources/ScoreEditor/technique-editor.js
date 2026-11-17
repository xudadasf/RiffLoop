'use strict';
// One home for each parameter, shared by category tools and the applied list.
const techniqueGroups={
  rhythm:['note:isTieDestination'],dynamics:['beat:dynamics','beat:crescendo','beat:fade'],
  articulation:['note:accentuated','note:isStaccato','note:isGhost','note:isDead','beat:pickStroke','beat:brushType','beat:brushDuration','beat:rasgueado'],
  effect:['note:isHammerPullOrigin','note:slideInType','note:slideOutType','note:vibrato','note:isPalmMute','note:isLetRing','note:isLeftHandTapped','beat:tap','beat:slap','beat:pop','beat:deadSlapped','beat:vibrato','beat:wahPedal','beat:golpe'],
  harmonic:['note:harmonicType','note:harmonicValue'],
  attach:['note:leftHandFinger','note:rightHandFinger','note:showStringNumber'],
  note:['beat:isLegatoOrigin','beat:graceType','note:trillValue','note:trillSpeed','note:ornament']
};
function effectPresent(spec,target){
  const e=target.effects,id=spec.id;
  if(id==='harmonicValue'&&!e.harmonicType||id==='trillSpeed'&&(e.trillValue??-1)<0||id==='brushDuration'&&!e.brushType)return false;
  return e[id]!==undefined&&e[id]!== (spec.default??0);
}
function techniqueField(spec){
  const targets=session.targets(spec.scope);if(!targets.length)return;
  let choices=spec.kind==='toggle'?[['关闭',0],['开启',1]]:spec.choices;
  if(spec.id==='trillSpeed'){choices=choices.filter(c=>c[1]===16||c[1]===targets[0].effects.trillSpeed);text('颤音速度保存到 GP 时使用 1/16。');}
  const input=field(spec.label,targets[0].effects[spec.id]??spec.default??0,v=>{
    if(v===(spec.default??0))session.removeEffect(spec.scope,spec.id);
    else session.change(()=>session.targets(spec.scope).forEach(t=>t.effects[spec.id]=v));
  },choices);
  if(spec.kind==='number'){input.min=spec.min;input.max=spec.max;input.step=spec.step||1;}
  input.dataset.technique=`${spec.scope}:${spec.id}`;
  if(spec.id==='harmonicValue')text('先选择泛音类型，再调整泛音音高。');
}
function openAdvanced(ids){
  panel('技巧参数');text(session.anchor?'设置作用于已选拍位的所有弦。':'音符技巧作用于当前弦；拍位技巧作用于整个拍位。');
  const keys=ids||techniqueGroups[activeTool]||[];
  for(const scope of ['note','beat']){
    const specs=schema.filter(s=>s.scope===scope&&keys.some(k=>k===s.id||k===`${scope}:${s.id}`));
    if(!specs.length||!session.targets(scope).length)continue;
    heading(scope==='note'?'当前音符':'整个拍位');for(const spec of specs)techniqueField(spec);
  }
}
function appliedTechniques(){
  panel('已用技巧');text(session.anchor?'显示所选范围内已用的技巧；修改或取消作用于整段。':'显示当前弦的音符技巧，以及当前拍位的技巧。');
  let count=0;
  function row(key,label,value,edit,remove){
    count++;const wrap=document.createElement('div');wrap.className='appliedTechnique';wrap.dataset.applied=key;
    const caption=document.createElement('span');caption.textContent=`${label} · ${value}`;wrap.append(caption);
    button('修改',edit,wrap);button('取消',()=>{remove();appliedTechniques();},wrap);$('panelBody').append(wrap);
  }
  for(const spec of schema){
    const targets=session.targets(spec.scope),active=targets.filter(t=>effectPresent(spec,t));if(!active.length)continue;
    const values=[...new Set(active.map(t=>t.effects[spec.id]))];
    const label=values.length>1?'多种设置':spec.choices?.find(c=>c[1]===values[0])?.[0]??(spec.kind==='toggle'?'已开启':String(values[0]));
    row(`${spec.scope}:${spec.id}`,spec.label,label,()=>openAdvanced([`${spec.scope}:${spec.id}`]),()=>session.removeEffect(spec.scope,spec.id));
  }
  for(const [scope,key,label] of [['note','bend','推弦曲线'],['beat','whammy','摇把曲线']])if(session.targets(scope).some(t=>t[key].length))row(`${scope}:${key}`,label,'已设置',()=>{panel(label);curves(scope);},()=>session.setCurve(scope,[]));
  if(session.selectedBeats.some(b=>b.tremolo))row('beat:tremolo','震音拨弦','已设置',()=>{panel('震音拨弦');field('速度',session.currentBeat.tremolo,v=>session.change(()=>session.selectedBeats.forEach(b=>b.tremolo=v)),[['关闭',0],['八分',8],['十六分',16],['三十二分',32],['六十四分',64]]);},()=>session.change(()=>session.selectedBeats.forEach(b=>b.tremolo=0)));
  if(!count)text('这里还没有设置技巧。选中音符后，可在底部分类中添加。');
  else {text('清除演奏技巧保留音高、时值和倚音结构；需要把倚音改回普通音符时，请单独修改“装饰音”。');button('清除演奏技巧',()=>{session.clearTechniques();appliedTechniques();},$('panelBody'));}
}
function curves(scope){
  const isNote=scope==='note',key=isNote?'bend':'whammy';
  if(!session.targets(scope).length){text('请先选中一个已有音符。');return;}
  text('先选曲线，再修改各控制点。位置为本音时值的百分比；音高变化以半音为单位，可输入 0.5。GP 曲线最多 4 个点，两个中间点共用音高。');
  const presets=isNote?
    [['半音',[[0,0],[60,2]]],['全音',[[0,0],[60,4]]],['推弦后释放',[[0,0],[30,4],[60,0]]],['预推保持',[[0,4],[60,4]]],['预推后释放',[[0,4],[60,0]]],['预推再推',[[0,2],[60,4]]]]:
    [['下压全音',[[0,0],[60,-4]]],['下压后返回',[[0,0],[30,-4],[60,0]]],['上提全音',[[0,0],[60,4]]],['预压保持',[[0,-4],[60,-4]]]];
  const controls=document.createElement('div');controls.className='curvePresets';$('panelBody').append(controls);
  for(const [label,values] of presets)button(label,()=>commit(values.map(([offset,value])=>({offset,value}))),controls);
  const graph=document.createElement('canvas');graph.width=620;graph.height=160;graph.className='curveGraph';graph.setAttribute('role','img');graph.setAttribute('aria-label',isNote?'推弦音高变化图':'摇把音高变化图');$('panelBody').append(graph);
  const points=document.createElement('div');points.className='curvePoints';$('panelBody').append(points);
  function current(){return GuitarEdit.copy(session.targets(scope)[0][key]);}
  function commit(values){
    values.sort((a,b)=>a.offset-b.offset);
    // Check this curve in isolation, even while the user's real bar is incomplete.
    const b=GuitarEdit.beat(1);b.notes=[GuitarEdit.note(1,7)];(isNote?b.notes[0]:b)[key]=values;
    const probe={version:3,title:'',tempo:100,numerator:4,denominator:4,tuning:[40,45,50,55,59,64],capo:0,program:27,bars:[{...GuitarEdit.bar(),beats:[b]}]};
    try{core.exportDraft(alphaTab,probe,schema);}catch(e){throw Error('这组曲线点无法完整保存到 GP，原曲线已保留。请用预设，或调整控制点（摇把半音变化可增加中间点）。');}
    session.setCurve(scope,values);$('panelError').textContent='';draw();
  }
  function draw(){
    points.replaceChildren();const values=current(),ctx=graph.getContext('2d'),limit=Math.max(2,...values.map(p=>Math.abs(p.value/2)));
    ctx.clearRect(0,0,620,160);ctx.fillStyle='#f0f4f5';ctx.fillRect(0,0,620,160);ctx.strokeStyle='#c2cdd1';ctx.beginPath();ctx.moveTo(36,80);ctx.lineTo(600,80);ctx.stroke();ctx.fillStyle='#46535a';ctx.font='12px sans-serif';ctx.fillText(`+${limit}`,3,18);ctx.fillText('0',12,84);ctx.fillText(`−${limit}`,3,145);ctx.fillText('0%',36,156);ctx.fillText('100%',566,156);
    const x=p=>36+p.offset/60*560,y=p=>80-p.value/2/limit*60;ctx.strokeStyle='#357b89';ctx.lineWidth=3;ctx.beginPath();values.forEach((p,i)=>i?ctx.lineTo(x(p),y(p)):ctx.moveTo(x(p),y(p)));ctx.stroke();ctx.fillStyle='#357b89';for(const p of values){ctx.beginPath();ctx.arc(x(p),y(p),4,0,2*Math.PI);ctx.fill();}
    values.forEach((p,i)=>{
      const row=document.createElement('div');row.className='curvePoint';points.append(row);
      for(const [name,key,value,min,max,step] of [['位置 %','offset',Math.round(p.offset/60*1000)/10,0,100,1],['变化半音','value',p.value/2,-12,12,.5]]){
        const label=document.createElement('label');label.textContent=name;const input=document.createElement('input');input.type='number';input.min=min;input.max=max;input.step=step;input.value=value;input.setAttribute('aria-label',`控制点 ${i+1} ${name}`);
        input.onchange=()=>perform(()=>{const n=Number(input.value);if(input.value===''||!Number.isFinite(n)||n<min||n>max||(key==='value'&&!Number.isInteger(n*2)))throw Error('请输入范围内的数值，音高变化以 0.5 半音为步进。');const edited=current();edited[i][key]=key==='offset'?Math.round(n/100*60):n*2;if(edited.length===4&&key==='value'&&(i===1||i===2))edited[3-i].value=n*2;try{commit(edited);}catch(e){draw();throw e;}});label.append(input);row.append(label);
      }
      const remove=button('删点',()=>{const edited=current();edited.splice(i,1);commit(edited);},row);remove.setAttribute('aria-label',`删除控制点 ${i+1}`);remove.disabled=values.length<=2;
    });
    $('curveAdd').disabled=values.length>=4;
  }
  const add=button('添加控制点',()=>{const values=current();if(!values.length){commit([{offset:0,value:0},{offset:60,value:0}]);return;}const at=values.length===3?2:1,lo=values[at-1],hi=values[at];values.splice(at,0,{offset:Math.round((lo.offset+hi.offset)/2),value:values.length===3?lo.value:Math.round((lo.value+hi.value)/2)});commit(values);},$('panelBody'));add.id='curveAdd';
  button('取消这条曲线',()=>{session.setCurve(scope,[]);draw();},$('panelBody'));draw();
}

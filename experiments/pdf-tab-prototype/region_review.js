(() => {
  'use strict';
  const data=JSON.parse(document.getElementById('region-data').textContent);
  const el=id=>document.getElementById(id);
  const svgNS='http://www.w3.org/2000/svg';
  let pages=data.pages.map(p=>({page:p.page,confirmed:false,regions:p.regions.map(r=>({box:[...r.box],selected:!!r.accepted,reason:r.reason}))}));
  let pageIndex=0,selected=-1,mode='',drag=null,dirty=false;
  const feedback=t=>{el('feedback').textContent=t;};
  const current=()=>pages[pageIndex];
  const change=()=>{current().confirmed=false;dirty=true;};
  const plan=()=>({format:'riffloop-region-plan-v1',document_id:data.document_id,review_folder:data.review_folder,pages});
  function fit() {
    const p=data.pages[pageIndex],stage=el('stage');
    const scale=Math.min((stage.clientWidth-18)/p.width,(innerHeight*.72)/p.height)*Number(el('zoom').value);
    el('sheet').style.width=`${p.width*scale}px`;el('sheet').style.height=`${p.height*scale}px`;
  }
  function rectangle(box,index,temporary=false) {
    const [x,y,right,bottom]=box,rect=document.createElementNS(svgNS,'rect');
    rect.setAttribute('x',x);rect.setAttribute('y',y);rect.setAttribute('width',right-x);rect.setAttribute('height',bottom-y);
    const adopted=!temporary && current().regions[index].selected;
    const color=temporary || index===selected ? '#2563eb' : adopted ? '#15803d' : '#d97706';
    rect.setAttribute('fill',color);rect.setAttribute('fill-opacity','.06');rect.setAttribute('stroke',color);
    rect.setAttribute('stroke-width',index===selected ? 5:3);rect.setAttribute('vector-effect','non-scaling-stroke');
    if(!temporary) rect.dataset.index=index;
    el('overlay').append(rect);
    if(!temporary){const text=document.createElementNS(svgNS,'text');text.setAttribute('x',x+6);text.setAttribute('y',y+25);
      text.setAttribute('font-size','24');text.setAttribute('fill',color);text.style.pointerEvents='none';text.textContent=index+1;el('overlay').append(text);}
  }
  function paint(){el('overlay').replaceChildren();current().regions.forEach((r,i)=>rectangle(r.box,i));}
  function render(){
    const p=current(),original=data.pages[pageIndex];
    el('page').replaceChildren(...pages.map((item,i)=>{const o=document.createElement('option');o.value=i;o.textContent=`PDF 第 ${item.page} 页 · ${item.confirmed?'已确认':'未确认'} · ${item.regions.length} 框`;return o;}));
    el('page').value=pageIndex;
    el('source').src=original.original;el('overlay').setAttribute('viewBox',`0 0 ${original.width} ${original.height}`);
    el('progress').textContent=`已确认 ${pages.filter(p=>p.confirmed).length}/${pages.length} 页`;
    el('page-status').textContent=p.confirmed?'本页已确认':'本页未确认';
    el('prev').disabled=pageIndex===0;el('next').disabled=pageIndex===pages.length-1;
    el('redraw').disabled=selected<0;el('remove').disabled=selected<0;
    el('add').classList.toggle('active',mode==='add');el('redraw').classList.toggle('active',mode==='redraw');
    el('regions').replaceChildren(...p.regions.map((r,i)=>{
      const card=document.createElement('div');card.className='region'+(i===selected?' current':'');
      const label=document.createElement('label'),check=document.createElement('input');check.type='checkbox';check.checked=r.selected;
      check.setAttribute('aria-label',`采用区域 ${i+1}`);check.onchange=()=>{r.selected=check.checked;selected=i;change();render();};
      label.append(check,` 采用区域 ${i+1}`);card.append(label);
      const reason=document.createElement('p');reason.textContent=r.reason||'人工画框';card.append(reason);
      const row=document.createElement('div');row.className='toolbar';
      for(const [text,action] of [['选中',()=>{selected=i;mode='';render();}],['↑',()=>move(i,-1)],['↓',()=>move(i,1)]]){
        const button=document.createElement('button');button.textContent=text;button.onclick=action;row.append(button);}
      card.append(row);return card;
    }));
    if(!p.regions.length)el('regions').textContent='尚无候选框。请查看原页；有谱子时用“补画区域”，无谱时直接确认本页。';
    fit();paint();
  }
  function move(i,delta){const j=i+delta;if(j<0||j>=current().regions.length)return;
    const regions=current().regions;[regions[i],regions[j]]=[regions[j],regions[i]];selected=j;change();render();}
  function navigate(i){pageIndex=Math.max(0,Math.min(pages.length-1,i));selected=-1;mode='';drag=null;render();el('stage').scrollTo(0,0);}
  function point(e){const rect=el('overlay').getBoundingClientRect(),p=data.pages[pageIndex];
    return [Math.max(0,Math.min(p.width,(e.clientX-rect.left)/rect.width*p.width)),Math.max(0,Math.min(p.height,(e.clientY-rect.top)/rect.height*p.height))];}
  function box(a,b){return [Math.round(Math.min(a[0],b[0])),Math.round(Math.min(a[1],b[1])),Math.round(Math.max(a[0],b[0])),Math.round(Math.max(a[1],b[1]))];}
  el('overlay').onpointerdown=e=>{
    if(!mode){const index=e.target.dataset.index;if(index!==undefined){selected=Number(index);render();}return;}
    drag=point(e);el('overlay').setPointerCapture(e.pointerId);e.preventDefault();
  };
  el('overlay').onpointermove=e=>{if(drag){paint();rectangle(box(drag,point(e)),-1,true);}};
  el('overlay').onpointerup=e=>{
    if(!drag)return;const bounds=box(drag,point(e));drag=null;
    if(bounds[2]-bounds[0]<10||bounds[3]-bounds[1]<10){feedback('区域太小，请拖出完整谱区。');paint();return;}
    if(mode==='redraw'&&selected>=0){current().regions[selected].box=bounds;current().regions[selected].reason='人工重画';}
    else{current().regions.push({box:bounds,selected:true,reason:'人工补画'});selected=current().regions.length-1;}
    mode='';change();feedback('边界已修改；请查看是否框住全部乐谱，然后确认本页。');render();
  };
  el('overlay').onpointercancel=()=>{drag=null;paint();};
  el('add').onclick=()=>{mode=mode==='add'?'':'add';feedback(mode?'在原页拖出新区域。':'已退出画框。');render();};
  el('redraw').onclick=()=>{mode='redraw';feedback('在原页重新拖出所选区域的完整边界。');render();};
  el('remove').onclick=()=>{if(selected<0)return;current().regions.splice(selected,1);selected=-1;change();render();};
  el('page').onchange=()=>navigate(Number(el('page').value));el('prev').onclick=()=>navigate(pageIndex-1);el('next').onclick=()=>navigate(pageIndex+1);
  el('unconfirmed').onclick=()=>{for(let step=1;step<=pages.length;step++){const i=(pageIndex+step)%pages.length;if(!pages[i].confirmed){navigate(i);return;}}feedback('全部页面已确认。');};
  el('confirm').onclick=()=>{
    const boxes=current().regions.filter(r=>r.selected).map(r=>r.box);
    for(let i=0;i<boxes.length;i++)for(let j=0;j<i;j++){
      const a=boxes[i],b=boxes[j],area=r=>(r[2]-r[0])*(r[3]-r[1]);
      const overlap=Math.max(0,Math.min(a[2],b[2])-Math.max(a[0],b[0]))*Math.max(0,Math.min(a[3],b[3])-Math.max(a[1],b[1]));
      if(overlap>Math.min(area(a),area(b))*.15){feedback('采用框明显重叠，请取消重复框，或重画成一个完整区域，再确认本页。');return;}
    }
    current().confirmed=true;dirty=true;feedback('本页已确认；采用区域将按当前顺序输出。');navigate(pageIndex+1);
  };
  el('zoom').onchange=fit;window.addEventListener('resize',fit);
  el('save').onclick=()=>{
    const blob=new Blob([JSON.stringify(plan(),null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),link=document.createElement('a');
    link.href=url;link.download='riffloop-regions-plan.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);dirty=false;
    feedback('方案已下载。回桌面程序点击“导入分区确认方案”。只应用已确认页；未确认页仍保存在方案中，之后可继续载入编辑。');
  };
  el('load').onclick=()=>el('plan-file').click();
  el('plan-file').onchange=async()=>{
    try{const file=el('plan-file').files[0];if(!file)return;const p=JSON.parse(await file.text());
      if(p.format!=='riffloop-region-plan-v1'||p.document_id!==data.document_id||!Array.isArray(p.pages)||p.pages.length!==pages.length)throw Error('不是这次分区的方案');
      for(let i=0;i<p.pages.length;i++){const item=p.pages[i],source=data.pages[i];
        if(item.page!==source.page||typeof item.confirmed!=='boolean'||!Array.isArray(item.regions)||item.regions.length>1000)throw Error('方案页面无效');
        for(const r of item.regions){const b=r.box;if(typeof r.selected!=='boolean'||!Array.isArray(b)||b.length!==4||b.some(x=>!Number.isFinite(x))||b[0]<0||b[1]<0||b[2]>source.width||b[3]>source.height||b[2]-b[0]<10||b[3]-b[1]<10)throw Error('分区坐标无效');}}
      pages=p.pages;dirty=false;navigate(0);feedback('已载入保存的分区与确认状态。');
    }catch(error){feedback('载入失败：'+error.message);}finally{el('plan-file').value='';}
  };
  window.addEventListener('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue='';}});
  render();
})();

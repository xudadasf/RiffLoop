(() => {
  'use strict';
  const data=JSON.parse(document.getElementById('region-data').textContent);
  const el=id=>document.getElementById(id);
  const svgNS='http://www.w3.org/2000/svg';
  let pages=data.pages.map(p=>({page:p.page,confirmed:false,regions:p.regions.map((r,i)=>({id:i+1,box:[...r.box],selected:!!r.accepted,reason:r.reason,gap_after:1}))}));
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
      text.setAttribute('font-size','24');text.setAttribute('fill',color);text.style.pointerEvents='none';text.textContent=current().regions[index].id;el('overlay').append(text);}
  }
  function paint(){el('overlay').replaceChildren();const view=el('box-view').value;
    current().regions.forEach((r,i)=>{if(view==='all'||(view==='adopted'&&r.selected))rectangle(r.box,i);});}
  function render(){
    const p=current(),original=data.pages[pageIndex];
    el('page').replaceChildren(...pages.map((item,i)=>{const o=document.createElement('option');o.value=i;o.textContent=`PDF 第 ${item.page} 页 · ${item.confirmed?'已确认':'未确认'} · ${item.regions.length} 框`;return o;}));
    el('page').value=pageIndex;
    el('source').src=original.original;el('overlay').setAttribute('viewBox',`0 0 ${original.width} ${original.height}`);
    el('progress').textContent=`已确认 ${pages.filter(p=>p.confirmed).length}/${pages.length} 页`;
    const adopted=p.regions.filter(r=>r.selected).length;
    el('page-status').textContent=`${p.confirmed?'本页已确认':'本页未确认'} · 采用 ${adopted} / 未采用 ${p.regions.length-adopted}`;
    el('prev').disabled=pageIndex===0;el('next').disabled=pageIndex===pages.length-1;
    el('redraw').disabled=selected<0;el('remove').disabled=selected<0;
    el('zoom-out').disabled=el('zoom').selectedIndex===0;el('zoom-in').disabled=el('zoom').selectedIndex===el('zoom').options.length-1;
    el('add').classList.toggle('active',mode==='add');el('redraw').classList.toggle('active',mode==='redraw');
    let writePosition=0;
    el('regions').replaceChildren(...p.regions.map((r,i)=>{
      const card=document.createElement('div');card.className='region'+(i===selected?' current':'');
      const label=document.createElement('label'),check=document.createElement('input');check.type='checkbox';check.checked=r.selected;
      check.setAttribute('aria-label',`采用区域 ${r.id}`);check.onchange=()=>{r.selected=check.checked;selected=i;change();render();};
      label.append(check,` 采用区域 ${r.id}`);card.append(label);
      const reason=document.createElement('p');reason.textContent=r.reason||'人工画框';card.append(reason);
      const row=document.createElement('div');row.className='toolbar';
      const button=document.createElement('button');button.textContent='选中';
      button.onclick=()=>{selected=i;mode='';el('box-view').value='all';render();};row.append(button);
      if(r.selected){
        const positionLabel=document.createElement('label'),position=document.createElement('input');
        position.type='number';position.min=1;position.max=adopted;position.step=1;position.value=++writePosition;
        position.setAttribute('aria-label',`区域 ${r.id} 的本页写入位置`);
        position.onchange=()=>reorder(r,position.value);
        position.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();position.blur();}};
        positionLabel.append('写入位置 ',position);row.append(positionLabel);
        const gapLabel=document.createElement('label'),gap=document.createElement('input');
        gap.type='number';gap.min=0;gap.max=99;gap.step=1;gap.value=r.gap_after;
        gap.setAttribute('aria-label',`区域 ${r.id} 后的空白小节`);
        gap.onchange=()=>{const value=Number(gap.value);
          if(gap.value.trim()===''||!Number.isInteger(value)||value<0||value>99){feedback('空白小节请输入 0–99 的整数；0 表示连续写入。');gap.value=r.gap_after;return;}
          if(value!==r.gap_after){r.gap_after=value;change();render();}};
        gapLabel.append('后接空白 ',gap,' 小节');row.append(gapLabel);
      }
      card.append(row);return card;
    }));
    if(!p.regions.length)el('regions').textContent='尚无候选框。请查看原页；有谱子时用“补画区域”，无谱时直接确认本页。';
    fit();paint();
  }
  function reorder(region,value){
    const regions=current().regions,slots=regions.map((r,i)=>r.selected?i:-1).filter(i=>i>=0);
    const adopted=slots.map(i=>regions[i]),target=Number(value)-1;
    if(value.trim()===''||!Number.isInteger(target)||target<0||target>=adopted.length){feedback(`写入位置请输入 1–${adopted.length} 的整数。`);render();return;}
    const from=adopted.indexOf(region);if(from===target)return;
    adopted.splice(from,1);adopted.splice(target,0,region);slots.forEach((slot,i)=>{regions[slot]=adopted[i];});
    selected=regions.indexOf(region);change();feedback(`区域 ${region.id} 已移到本页第 ${target+1} 个写入位置，其他采用区域已顺移。`);render();
  }
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
    else{current().regions.push({id:Math.max(0,...current().regions.map(r=>r.id))+1,box:bounds,selected:true,reason:'人工补画',gap_after:1});selected=current().regions.length-1;}
    mode='';change();feedback('边界已修改；请查看是否框住全部乐谱，然后确认本页。');render();
  };
  el('overlay').onpointercancel=()=>{drag=null;paint();};
  el('box-view').onchange=()=>{mode='';drag=null;render();};
  el('add').onclick=()=>{mode=mode==='add'?'':'add';el('box-view').value='all';feedback(mode?'在原页拖出新区域。':'已退出画框。');render();};
  el('redraw').onclick=()=>{mode='redraw';el('box-view').value='all';feedback('在原页重新拖出所选区域的完整边界。');render();};
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
  function zoom(){
    const stage=el('stage'),sheet=el('sheet');
    const frame=stage.getBoundingClientRect(),bounds=sheet.getBoundingClientRect();
    const x=Math.max(0,Math.min(1,(frame.left+stage.clientWidth/2-bounds.left)/bounds.width));
    const y=Math.max(0,Math.min(1,(frame.top+stage.clientHeight/2-bounds.top)/bounds.height));
    drag=null;fit();stage.scrollLeft=x*sheet.clientWidth-stage.clientWidth/2;stage.scrollTop=y*sheet.clientHeight-stage.clientHeight/2;
    el('zoom-out').disabled=el('zoom').selectedIndex===0;el('zoom-in').disabled=el('zoom').selectedIndex===el('zoom').options.length-1;paint();
  }
  el('zoom').onchange=zoom;
  el('zoom-in').onclick=()=>{el('zoom').selectedIndex=Math.min(el('zoom').options.length-1,el('zoom').selectedIndex+1);zoom();};
  el('zoom-out').onclick=()=>{el('zoom').selectedIndex=Math.max(0,el('zoom').selectedIndex-1);zoom();};
  window.addEventListener('resize',fit);
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
        const ids=new Set();
        for(const [j,r] of item.regions.entries()){const b=r.box;if(typeof r.selected!=='boolean'||!Array.isArray(b)||b.length!==4||b.some(x=>!Number.isFinite(x))||b[0]<0||b[1]<0||b[2]>source.width||b[3]>source.height||b[2]-b[0]<10||b[3]-b[1]<10)throw Error('分区坐标无效');
          if(r.id===undefined)r.id=j+1;if(!Number.isSafeInteger(r.id)||r.id<1||ids.has(r.id))throw Error('区域编号无效或重复');ids.add(r.id);
          if(r.gap_after===undefined)r.gap_after=1;if(!Number.isInteger(r.gap_after)||r.gap_after<0||r.gap_after>99)throw Error('空白小节须为 0–99 的整数');}}
      pages=p.pages;dirty=false;navigate(0);feedback('已载入保存的分区与确认状态。');
    }catch(error){feedback('载入失败：'+error.message);}finally{el('plan-file').value='';}
  };
  window.addEventListener('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue='';}});
  render();
})();

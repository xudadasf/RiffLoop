'use strict';
// Edit a single six-string voice in an existing GP7/8 archive. Other voices keep
// their original XML references. GP often shares a Beat or Note across measures.
const GuitarGP=(()=>{
  const child=(el,tag)=>Array.from(el?.children||[]).find(n=>n.tagName===tag);
  const ids=el=>el?.textContent.trim().split(/\s+/).filter(Boolean)||[];
  function setText(el,tag,value){
    let n=child(el,tag);
    if(!value){n?.remove();return;}
    if(!n){n=el.ownerDocument.createElement(tag);el.append(n);}
    n.textContent=value;
  }
  function xmlTables(text){
    const doc=new DOMParser().parseFromString(text,'application/xml'),root=doc.documentElement;
    if(root.tagName!=='GPIF'||doc.doctype)throw Error('GP 谱面结构无法读取。');
    const master=[...child(root,'MasterBars').children];
    const tables={};
    for(const type of ['Bar','Voice','Beat','Note','Rhythm','Track']){
      const parent=child(root,type==='Bar'?'Bars':type+'s'),items=new Map();let next=0;
      for(const n of parent.children){const id=n.getAttribute('id');if(items.has(id))throw Error('GP 对象编号重复。');items.set(id,n);next=Math.max(next,Number(id)+1);}
      tables[type]={get:id=>items.get(String(id)),add:node=>{
        const copy=doc.importNode(node,true),id=String(next++);copy.setAttribute('id',id);parent.append(copy);items.set(id,copy);return copy;
      }};
    }
    function barAt(i,slot){return tables.Bar.get(ids(child(master[i],'Bars'))[slot]);}
    function voiceAt(i,slot,v){return tables.Voice.get(ids(child(barAt(i,slot),'Voices'))[v]);}
    return {doc,root,master,...tables,barAt,voiceAt};
  }
  function noteByString(t,beat){
    return new Map(ids(child(beat,'Notes')).map(id=>{
      const n=t.Note.get(id),p=n.querySelector('Property[name="String"] > String');return [Number(p?.textContent),n];
    }));
  }
  const key=n=>n.tagName+'|'+(n.getAttribute('name')??(n.tagName==='XProperty'?n.getAttribute('id'):'')??'');
  function merge(dest,old,next,skip=[]){
    // Apply only differences between canonical representations. Retain foreign
    // properties, original spellings, XML extensions and untouched children.
    if(old.isEqualNode(next))return;
    for(const a of new Set([...old.getAttributeNames(),...next.getAttributeNames()])){
      if(a==='id'||old.getAttribute(a)===next.getAttribute(a))continue;
      if(next.hasAttribute(a))dest.setAttribute(a,next.getAttribute(a));else dest.removeAttribute(a);
    }
    if(!old.children.length&&!next.children.length){if(old.textContent!==next.textContent)dest.textContent=next.textContent;return;}
    const children=n=>new Map([...n.children].filter(x=>!skip.includes(x.tagName)).map(x=>[key(x),x]));
    const a=children(old),b=children(next),original=children(dest);
    for(const k of new Set([...a.keys(),...b.keys()])){
      const x=a.get(k),y=b.get(k),z=original.get(k);
      if(x&&y&&x.isEqualNode(y))continue;
      if(!y)z?.remove();
      else if(!z)dest.append(dest.ownerDocument.importNode(y,true));
      else if(!x)z.replaceWith(dest.ownerDocument.importNode(y,true));
      else merge(z,x,y);
    }
  }
  function draftFrom(score,track,staff,voice,schema){
    function effects(item,scope){
      const result={};
      for(const spec of schema.filter(s=>s.scope===scope&&s.id!=='sustainPedal')){
        let v=item[spec.id];
        if(v==null)continue;
        if(spec.kind==='toggle')v=Number(v);
        if(spec.id==='trillValue'&&v>=0)v=item.trillFret;
        if(v===(spec.default??0)||spec.id==='trillSpeed'&&!item.isTrill)continue;
        result[spec.id]=v;
      }return result;
    }
    const points=ps=>(ps||[]).map(({offset,value})=>({offset,value}));
    const bars=staff.bars.map((bar,i)=>{
      const mb=bar.masterBar,v=bar.voices[voice];
      const beats=(v?.beats||[]).map((b,j)=>{
        const d={...GuitarEdit.beat(b.duration),origin:[i,j],dots:b.dots,tupletNumerator:b.hasTuplet?b.tupletNumerator:1,
          tupletDenominator:b.hasTuplet?b.tupletDenominator:1,effects:effects(b,'beat'),whammy:points(b.whammyBarPoints),
          tremolo:b.tremoloSpeed??0,text:b.text||'',notes:b.notes.map(n=>({...GuitarEdit.note(7-n.string,n.fret),effects:effects(n,'note'),bend:points(n.bendPoints)}))};
        const p=bar.sustainPedals.find(p=>p.pedalType!==1&&Math.abs(p.ratioPosition*mb.calculateDuration()-b.displayStart)<1);
        if(p)d.effects.sustainPedal=p.pedalType===0?1:2;
        return d;
      });
      return {...GuitarEdit.bar(),origin:i,numerator:mb.timeSignatureNumerator,denominator:mb.timeSignatureDenominator,
        section:mb.section?.text||'',repeatStart:mb.isRepeatStart,repeatCount:mb.repeatCount,alternateEndings:mb.alternateEndings,
        tempo:mb.tempoAutomations[0]?.value,beats:beats.length?beats:[GuitarEdit.beat(1)]};
    });
    return {version:3,title:score.title||'电吉他',tempo:score.tempo,numerator:bars[0].numerator,denominator:bars[0].denominator,
      tuning:[...staff.stringTuning.tunings].reverse(),capo:staff.capo,program:track.playbackInfo.program,bars};
  }
  function open(bytes,schema){
    const xml=GuitarArchive.xml(bytes),src=xmlTables(xml),score=alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes,new alphaTab.Settings());
    const options=[];let slot=0;
    for(const track of score.tracks)for(const staff of track.staves){
      if(!staff.isPercussion&&staff.stringTuning.tunings.length===6){
        const count=Math.max(...staff.bars.map(b=>b.voices.length));
        for(let v=0;v<count;v++)if(staff.bars.some(b=>b.voices[v]?.beats.some(x=>x.notes.length)))
          options.push({track,staff,voice:v,slot,label:(track.name||'吉他')+' · 声部 '+(v+1)+(track.staves.length>1?' · 谱表 '+(staff.index+1):'')});
      }slot++;
    }
    if(!options.length)throw Error('这份谱没有可编辑的六弦吉他声部。');
    return {bytes,xml,schema,score,options};
  }
  function select(file,option){
    const {track,staff,voice,slot}=option,draft=draftFrom(file.score,track,staff,voice,file.schema),src=xmlTables(file.xml);
    GuitarDraftCore.validate(draft,file.schema,false);
    for(const [i,bar] of draft.bars.entries()){
      const refs=ids(child(src.voiceAt(i,slot,voice),'Beats'));
      if(refs.length&&refs.length!==bar.beats.length)throw Error('此声部含暂不能安全定位的节拍。');
    }
    return {file,option,draft};
  }
  const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
  function structural(d){return {...d,bars:d.bars.map(b=>({...b,beats:[]}))};}
  function check(session,d){
    if(!same(structural(session.draft),structural(d)))throw Error('整谱编辑保留原有小节结构和全局设置，可在小节内编辑拍位与音符。');
  }
  function canonical(d,schema){
    const score=GuitarDraftCore.makeScore(alphaTab,d,schema,false,true);
    const bytes=new alphaTab.exporter.Gp7Exporter().export(score,new alphaTab.Settings());
    const tables=xmlTables(GuitarArchive.xml(bytes));
    tables.positions=d.bars.map((bar,i)=>{
      const refs=ids(child(tables.voiceAt(i,0,0),'Beats'));let pos=0;
      return bar.beats.map(b=>GuitarDraftCore.portableBeats(b).map(()=>tables.Beat.get(refs[pos++])));
    });return tables;
  }
  function save(session,d){
    check(session,d);
    const {file,option,draft:base}=session,{slot,voice}=option;
    if(same(base,d))return file.bytes;
    GuitarDraftCore.validateLinks(d.bars.flatMap(b=>b.beats));
    const src=xmlTables(file.xml),old=canonical(base,file.schema),fresh=canonical(d,file.schema);
    const rhythmCache=new Map(),changed=[];
    function fingerprint(t,b){
      const clean=n=>{const x=n.cloneNode(true);x.removeAttribute('id');return x;};
      const node=clean(b);
      child(node,'Rhythm').replaceWith(clean(t.Rhythm.get(child(b,'Rhythm').getAttribute('ref'))));
      const notes=child(node,'Notes');
      if(notes)notes.replaceChildren(...ids(notes).map(id=>clean(t.Note.get(id))));
      return new XMLSerializer().serializeToString(node);
    }
    function equalAt(b,i,j){
      if(!b.origin)return false;
      const [bi,bj]=b.origin;
      if(!same(b,base.bars[bi]?.beats[bj]))return false;
      const left=old.positions[bi][bj],right=fresh.positions[i][j];
      return left.length===right.length&&left.every((beat,k)=>fingerprint(old,beat)===fingerprint(fresh,right[k]));
    }
    const rhythm=(t,b)=>t.Rhythm.get(child(b,'Rhythm')?.getAttribute('ref'));
    const rhythmId=b=>{
      const ref=child(b,'Rhythm').getAttribute('ref');
      if(!rhythmCache.has(ref))rhythmCache.set(ref,src.Rhythm.add(fresh.Rhythm.get(ref)).getAttribute('id'));
      return rhythmCache.get(ref);
    };
    for(const [i,bar] of d.bars.entries()){
      const unchanged=bar.beats.map((b,j)=>equalAt(b,i,j));
      if(same(bar,base.bars[i])&&unchanged.every(Boolean))continue;
      const total=b=>b.beats.reduce((s,x)=>s+GuitarDraftCore.ticks(x),0);
      const length=total(bar),expected=bar.numerator*3840/bar.denominator;
      if(Math.abs(length-expected)>.01&&Math.abs(length-total(base.bars[i]))>.01)throw Error('第 '+(i+1)+' 小节时值未齐，补齐后再保存。');
      const origBar=src.barAt(i,slot),originalVoice=src.voiceAt(i,slot,voice);
      const vb=src.Bar.add(origBar),vv=src.Voice.add(originalVoice||src.doc.createElement('Voice')),beatRefs=[];
      for(const [j,b] of bar.beats.entries()){
        const origin=b.origin,prior=origin&&base.bars[origin[0]]?.beats[origin[1]];
        const original=origin&&src.Beat.get(ids(child(src.voiceAt(origin[0],slot,voice),'Beats'))[origin[1]]);
        if(prior&&original&&unchanged[j]){beatRefs.push(original.getAttribute('id'));continue;}
        for(const [k,desired] of fresh.positions[i][j].entries()){
          const older=origin&&old.positions[origin[0]][origin[1]][0];
          const sourceBeat=src.Beat.add(original||desired);
          if(original&&older)merge(sourceBeat,older,desired,['Notes','Rhythm']);
          if(!original||!older||!rhythm(old,older).isEqualNode(rhythm(fresh,desired)))
            child(sourceBeat,'Rhythm').setAttribute('ref',rhythmId(desired));
          const priorNotes=original?noteByString(src,original):new Map(),baseline=older?noteByString(old,older):new Map();
          const notes=[];
          for(const [str,wanted] of noteByString(fresh,desired)){
            const was=baseline.get(str),source=priorNotes.get(str);
            if(was&&source){
              const n=src.Note.add(source);merge(n,was,wanted);notes.push(n.getAttribute('id'));
            }else notes.push(src.Note.add(wanted).getAttribute('id'));
          }
          setText(sourceBeat,'Notes',notes.join(' '));beatRefs.push(sourceBeat.getAttribute('id'));
        }
      }
      setText(vv,'Beats',beatRefs.join(' '));
      const vrefs=ids(child(vb,'Voices'));while(vrefs.length<=voice)vrefs.push('-1');vrefs[voice]=vv.getAttribute('id');setText(vb,'Voices',vrefs.join(' '));
      changed.push([i,vb.getAttribute('id')]);
    }
    // Repoint master bars only after resolving all source positions (also used by paste).
    for(const [i,id] of changed){const refs=ids(child(src.master[i],'Bars'));refs[slot]=id;setText(src.master[i],'Bars',refs.join(' '));}
    for(const [i] of changed){
      const pedalTimes=b=>{let offset=0;return b.beats.flatMap(x=>{const pos=offset/(b.numerator*3840/b.denominator);offset+=GuitarDraftCore.ticks(x);return x.effects.sustainPedal?[[pos,x.effects.sustainPedal]]:[];});};
      const previous=pedalTimes(base.bars[i]),next=pedalTimes(d.bars[i]);if(same(previous,next))continue;
      const trackId=ids(child(child(src.root,'MasterTrack'),'Tracks'))[option.track.index];
      const track=src.Track.get(trackId);let autos=child(track,'Automations');
      if(!autos){autos=src.doc.createElement('Automations');track.append(autos);}
      for(const n of [...autos.children]){
        if(child(n,'Type')?.textContent!=='SustainPedal'||Number(child(n,'Bar')?.textContent)!==i)continue;
        if(previous.some(([p])=>Math.abs(p-Number(child(n,'Position')?.textContent))<.00001))n.remove();
      }
      for(const [p,action] of next){const n=src.doc.createElement('Automation');autos.append(n);
        for(const [tag,val] of Object.entries({Type:'SustainPedal',Linear:'false',Bar:String(i),Position:String(p),Visible:'true',Value:action===1?'0 1':'0 3'}))setText(n,tag,val);}
    }
    const bytes=GuitarArchive.replace(file.bytes,new XMLSerializer().serializeToString(src.doc));
    const reopened=alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes,new alphaTab.Settings());
    const staff=reopened.tracks[option.track.index].staves[option.staff.index];
    for(const [i] of changed){
      const actual=staff.bars[i].voices[voice].beats,expected=d.bars[i].beats.flatMap(GuitarDraftCore.portableBeats);
      if(actual.length!==expected.length)throw Error('重读后拍数不一致，原谱已保留。');
      expected.forEach((b,j)=>{
        for(const n of b.notes.filter(n=>n.fret!=null)){
          const saved=actual[j].notes.find(x=>7-x.string===n.string);
          if(!saved||saved.fret!==n.fret)throw Error('重读后弦位或品位变化，原谱已保留。');
        }
      });
    }
    return bytes;
  }
  return {open,select,check,save};
})();

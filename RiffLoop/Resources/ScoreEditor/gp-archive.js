'use strict';
// Keep other ZIP records compressed and byte-for-byte intact, including embedded audio.
const GuitarArchive=(()=>{
  const path='Content/score.gpif',limit=32*1024*1024;
  function parse(bytes){
    const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
    const u16=i=>view.getUint16(i,true),u32=i=>view.getUint32(i,true);
    let end=bytes.length-22;
    for(const min=Math.max(0,end-65535);end>=min;end--){
      if(u32(end)===0x06054b50&&end+22+u16(end+20)===bytes.length)break;
    }
    if(end<0||u32(end)!==0x06054b50||u32(end+4)!==0)throw Error('仅支持标准 GP7/GP8 单卷 .gp 文件。');
    const start=u32(end+16),entries=[];
    let pos=start;
    for(let i=0;i<u16(end+10);i++){
      if(u32(pos)!==0x02014b50)throw Error('GP 目录损坏。');
      const len=u16(pos+28),next=pos+46+len+u16(pos+30)+u16(pos+32);
      const name=new TextDecoder().decode(bytes.subarray(pos+46,pos+46+len));
      const offset=u32(pos+42);
      if(offset>=start||u32(offset)!==0x04034b50||next>end)throw Error('GP 文件记录无效。');
      entries.push({name,offset,header:bytes.slice(pos,next),length:u32(pos+24)});pos=next;
    }
    if(pos!==end||entries.filter(e=>e.name===path).length!==1)throw Error('GP 缺少唯一的谱面。');
    const records=[...entries].sort((a,b)=>a.offset-b.offset);
    records.forEach((e,i)=>e.stop=records[i+1]?.offset??start);
    return {bytes,entries,records,end:bytes.subarray(end)};
  }
  function xml(bytes){
    const a=parse(bytes),item=a.entries.find(e=>e.name===path);
    if(item.length>limit)throw Error('谱面过大。');
    return new TextDecoder('utf-8',{fatal:true}).decode(fflate.unzipSync(bytes,{filter:e=>e.name===path})[path]);
  }
  function replace(bytes,xmlText){
    const raw=new TextEncoder().encode(xmlText);if(raw.length>limit)throw Error('谱面过大。');
    const original=parse(bytes),fresh=parse(fflate.zipSync({[path]:raw},{level:6,mtime:new Date(1980,0,1)})),parts=[];
    let size=0;
    function add(data){parts.push(data);size+=data.length;}
    add(bytes.subarray(0,original.records[0].offset));
    for(const entry of original.records){
      const replace=entry.name===path,source=replace?fresh:original,record=replace?fresh.records[0]:entry;
      if(replace)entry.header=record.header;
      new DataView(entry.header.buffer,entry.header.byteOffset).setUint32(42,size,true);
      add(source.bytes.subarray(record.offset,record.stop));
    }
    const start=size;
    for(const e of original.entries)add(e.header);
    const end=original.end.slice(),v=new DataView(end.buffer);
    v.setUint32(12,size-start,true);v.setUint32(16,start,true);add(end);
    const result=new Uint8Array(size);let off=0;for(const p of parts){result.set(p,off);off+=p.length;}return result;
  }
  return {xml,replace};
})();

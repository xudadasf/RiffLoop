'use strict';
// Keep other ZIP records compressed and byte-for-byte intact, including embedded audio.
const GuitarArchive=(()=>{
  const path='Content/score.gpif',limit=32*1024*1024;
  const layouts=new Set(['BinaryStylesheet','PartConfiguration','LayoutConfiguration']);
  const checksumTable=Uint32Array.from({length:256},(_,value)=>{
    for(let bit=0;bit<8;bit++)value=(value>>>1)^((value&1)?0xedb88320:0);
    return value>>>0;
  });
  function checksum(bytes){
    let value=0xffffffff;
    for(const byte of bytes)value=(value>>>8)^checksumTable[(value^byte)&255];
    return (value^0xffffffff)>>>0;
  }
  function parse(bytes){
    const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
    const u16=i=>view.getUint16(i,true),u32=i=>view.getUint32(i,true);
    const last=bytes.length-22,min=Math.max(0,last-65535);
    let end=last;
    for(;end>=min;end--){
      if(u32(end)===0x06054b50&&end+22+u16(end+20)===bytes.length)break;
    }
    if(end<min||u32(end+4)!==0||u16(end+8)!==u16(end+10))throw Error('仅支持标准 GP7/GP8 单卷 .gp 文件。');
    const start=u32(end+16),entries=[];
    if(start+u32(end+12)!==end)throw Error('GP 目录损坏。');
    let pos=start;
    for(let i=0;i<u16(end+10);i++){
      if(pos+46>end||u32(pos)!==0x02014b50)throw Error('GP 目录损坏。');
      const len=u16(pos+28),next=pos+46+len+u16(pos+30)+u16(pos+32);
      const offset=u32(pos+42);
      if(next>end||offset+30>start||u32(offset)!==0x04034b50||u16(pos+34)!==0)throw Error('GP 文件记录无效。');
      const name=new TextDecoder().decode(bytes.subarray(pos+46,pos+46+len));
      const dataStart=offset+30+u16(offset+26)+u16(offset+28);
      entries.push({name,offset,header:bytes.slice(pos,next),length:u32(pos+24),
        dataEnd:dataStart+u32(pos+20),crc:u32(pos+16)});pos=next;
    }
    if(pos!==end||entries.filter(e=>e.name===path).length!==1)throw Error('GP 缺少唯一的谱面。');
    const records=[...entries].sort((a,b)=>a.offset-b.offset);
    for(const [i,e] of records.entries()){
      e.stop=records[i+1]?.offset??start;
      if(e.dataEnd>e.stop)throw Error('GP 文件记录损坏。');
    }
    return {bytes,entries,records,end:bytes.subarray(end)};
  }
  function xml(bytes){
    const a=parse(bytes),item=a.entries.find(e=>e.name===path);
    if(item.length>limit)throw Error('谱面过大。');
    const raw=fflate.unzipSync(bytes,{filter:e=>e.name===path})[path];
    if(raw.length!==item.length||checksum(raw)!==item.crc)throw Error('GP 谱面校验失败，文件可能已损坏。');
    return new TextDecoder('utf-8',{fatal:true}).decode(raw);
  }
  function assemble(original,entries,replacement){
    const parts=[],headers=new Map();let size=0;
    function add(data){parts.push(data);size+=data.length;}
    if(replacement)add(original.bytes.subarray(0,original.records[0].offset));
    for(const entry of original.records){
      if(!entries.has(entry))continue;
      const source=entry.name===path&&replacement?replacement:original;
      const record=source===original?entry:source.records[0];
      const header=record.header;
      new DataView(header.buffer,header.byteOffset).setUint32(42,size,true);
      headers.set(entry,header);
      add(source.bytes.subarray(record.offset,record.stop));
    }
    const start=size;
    for(const entry of original.entries)if(headers.has(entry))add(headers.get(entry));
    const end=original.end.slice(),v=new DataView(end.buffer);
    v.setUint16(8,headers.size,true);v.setUint16(10,headers.size,true);
    v.setUint32(12,size-start,true);v.setUint32(16,start,true);add(end);
    const result=new Uint8Array(size);let off=0;for(const p of parts){result.set(p,off);off+=p.length;}return result;
  }
  function forEditor(bytes){
    // The score reader inflates every entry it receives. Auditioning one guitar
    // voice only needs the score and its layout; save always uses the full archive.
    const a=parse(bytes),entries=a.entries.filter(e=>e.name===path||layouts.has(e.name.split('/').pop()));
    if(entries.reduce((sum,e)=>sum+e.length,0)>2*limit)throw Error('谱面和排版数据过大。');
    return entries.length===a.entries.length?bytes:assemble(a,new Set(entries));
  }
  function replace(bytes,xmlText){
    const raw=new TextEncoder().encode(xmlText);if(raw.length>limit)throw Error('谱面过大。');
    const a=parse(bytes),fresh=parse(fflate.zipSync({[path]:raw},{level:6,mtime:new Date(1980,0,1)}));
    return assemble(a,new Set(a.entries),fresh);
  }
  return {xml,replace,forEditor};
})();

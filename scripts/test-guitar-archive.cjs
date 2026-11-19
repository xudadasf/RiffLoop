const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const {runInNewContext}=require('node:vm');
const fflate=require('../RiffLoop/Resources/ScoreEditor/fflate.min.js');
const source=readFileSync(require.resolve('../RiffLoop/Resources/ScoreEditor/gp-archive.js'),'utf8');
const archive=runInNewContext(source+'\nGuitarArchive',{fflate,TextEncoder,TextDecoder,Uint8Array});
const path='Content/score.gpif',xml='<GPIF><Title>Guitar</Title></GPIF>';
const configurations=['Content/BinaryStylesheet','Content/LayoutConfiguration','Content/PartConfiguration'];
const attachment='Content/Assets/backing-track.bin';
const entries={[path]:fflate.strToU8(xml),[attachment]:new Uint8Array(256*1024).fill(88)};
for(const [i,name] of configurations.entries())entries[name]=Uint8Array.of(i,1);
for(const level of [0,6]){
  const original=fflate.zipSync(entries,{level});
  assert.equal(archive.xml(original),xml);
  const subset=fflate.unzipSync(archive.forEditor(original));
  assert.deepEqual(Object.keys(subset).sort(),[path,...configurations].sort());
  for(const name of Object.keys(subset))assert.deepEqual(subset[name],entries[name]);
  const edited=archive.replace(original,xml.replace('Guitar','Lead'));
  assert.equal(archive.xml(edited),xml.replace('Guitar','Lead'));
  assert.deepEqual(fflate.unzipSync(edited)[attachment],entries[attachment]);
}
const single=fflate.zipSync({[path]:entries[path]});
assert.strictEqual(archive.forEditor(single),single);
const damaged=fflate.zipSync({[path]:entries[path]},{level:0});
const position=Buffer.from(damaged).indexOf('Guitar');
assert.ok(position>=0);
damaged[position]=76;
assert.throws(()=>archive.xml(damaged),/校验|损坏/);
console.log('GP archive: score checksum, stored and compressed data, editor layout and intact backing attachments passed');

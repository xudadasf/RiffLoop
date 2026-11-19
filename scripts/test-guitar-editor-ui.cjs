const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs/promises'),path=require('node:path');
const pw=require(process.env.RIFFLOOP_PLAYWRIGHT||'playwright');
const root=path.resolve(__dirname,'../RiffLoop/Resources'),schema=require('../RiffLoop/Resources/ScoreEditor/techniques.json'),edit=require('../RiffLoop/Resources/ScoreEditor/editor-state.js');
const fixture={version:3,title:'触屏编辑测试',tempo:70,numerator:4,denominator:4,tuning:[40,45,50,55,59,64],capo:0,program:27,bars:[{...edit.bar(),beats:[edit.beat(),edit.beat(),edit.beat(),edit.beat()]}]};
async function capture(page,name){
  if(!process.env.RIFFLOOP_SCREENSHOT_DIR)return;
  await fs.mkdir(process.env.RIFFLOOP_SCREENSHOT_DIR,{recursive:true});
  await page.screenshot({path:path.join(process.env.RIFFLOOP_SCREENSHOT_DIR,name)});
}
async function checkControls(page){
  const issues=await page.evaluate(()=>{
    const issues=[];
    for(const tab of document.querySelectorAll('#toolTabs button')){
      tab.click();
      for(const b of document.querySelectorAll('button')){
        if(!b.getClientRects().length||b.matches('.scoreTarget'))continue;
        if(b.closest('#toolStrip,.sidebar'))b.scrollIntoView({block:'nearest',inline:'nearest'});
        const r=b.getBoundingClientRect();
        const label=b.getAttribute('aria-label')||b.textContent;
        if(r.width<=0||r.left<-.5||r.right>innerWidth+.5||r.top<-.5||r.bottom>innerHeight+.5)issues.push(label+' 超出屏幕');
        if(b.scrollWidth>b.clientWidth+1||b.scrollHeight>b.clientHeight+1)issues.push(label+' 文字溢出');
        if(!b.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)))issues.push(label+' 被遮挡');
        if([b,...b.children].some(el=>getComputedStyle(el).userSelect!=='none'))issues.push(label+' 可选字');
      }
    }
    return [...new Set(issues)];
  });
  assert.deepEqual(issues,[]);
}
(async()=>{const server=http.createServer(async(req,res)=>{try{const name=path.resolve(root,'.'+decodeURIComponent(new URL(req.url,'http://localhost').pathname));if(!name.startsWith(root+path.sep))throw Error();const data=await fs.readFile(name);res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':name.endsWith('.html')?'text/html':'application/octet-stream');res.end(data);}catch{res.statusCode=404;res.end();}});await new Promise(r=>server.listen(0,'127.0.0.1',r));let browser;try{
browser=await pw.chromium.launch({headless:true,executablePath:process.env.RIFFLOOP_BROWSER});const page=await browser.newPage({viewport:{width:1133,height:744},deviceScaleFactor:2,hasTouch:true});const errors=[];page.on('pageerror',e=>{errors.push(e.message);console.error(e.stack)});await page.addInitScript(()=>{window.messages=[];window.webkit={messageHandlers:{guitarEditor:{postMessage:m=>window.messages.push(m)}}};});
await page.goto(`http://127.0.0.1:${server.address().port}/ScoreEditor/editor.html`);await page.waitForFunction(()=>window.messages.some(m=>m.action==='ready'));
// The native bridge loads the draft asynchronously. Static HTML controls must
// not accept a tap before the draft and its final layout are available.
assert.equal(await page.locator('#bars').isVisible(),false,'Editing controls wait for the draft');
assert.equal(await page.locator('#close').isVisible(),true,'Return remains available during loading');
await page.evaluate(({fixture,schema})=>loadGuitarDraft(fixture,schema),{fixture,schema});
await page.waitForSelector('.scoreTarget');
const target=(bar,beat,string)=>page.locator(`.scoreTarget[data-bar="${bar}"][data-beat="${beat}"][data-string="${string}"]`);
await target(0,0,2).click();await page.locator('#keypad button').filter({hasText:/^1$/}).click();await page.waitForTimeout(1350);await page.locator('#keypad button').filter({hasText:/^3$/}).click();
assert.equal(await page.evaluate(()=>session.currentNote.fret),13);assert.equal(await page.evaluate(()=>session.currentNote.string),2);
await page.locator('#beatRight').click();
await page.waitForFunction(()=>scoreEditor.api.renderer.boundsLookup.findBeats(scoreEditor.score.tracks[0].staves[0].bars[0].voices[0].beats[0])?.some(b=>b.notes?.length));
const staffHead=await page.evaluate(()=>{const b=scoreEditor.score.tracks[0].staves[0].bars[0].voices[0].beats[0],bounds=scoreEditor.api.renderer.boundsLookup.findBeats(b).filter(b=>b.notes?.length).sort((a,b)=>a.barBounds.visualBounds.y-b.barBounds.visualBounds.y)[0].notes[0].noteHeadBounds,r=document.querySelector('#engraving').getBoundingClientRect();return {x:r.left+bounds.x+bounds.w/2,y:r.top+bounds.y+bounds.h/2};});
await page.mouse.click(staffHead.x,staffHead.y);assert.deepEqual(await page.evaluate(()=>[session.beat,session.string,session.currentNote?.fret]),[0,2,13],'Single tapping the staff still selects its TAB note');
assert.equal(await page.locator('.sidebar #insertMenu, .sidebar #appliedTechniques').count(),0);
await page.locator('#tab-beat').click();await page.locator('#insertBefore').click();assert.equal(await page.evaluate(()=>session.currentBar.beats.length),5);assert.equal(await page.evaluate(()=>session.currentNote.fret),null);await page.getByRole('button',{name:'8',exact:true}).click();assert.deepEqual(await page.evaluate(()=>session.currentBar.beats.slice(0,2).map(b=>b.notes[0].fret)),[8,13]);await page.locator('#undo').click();await page.locator('#undo').click();assert.equal(await page.evaluate(()=>session.currentBar.beats.length),4);await page.locator('#redo').click();assert.equal(await page.evaluate(()=>session.currentBar.beats.length),5);await page.locator('#undo').click();
await page.locator('#insertRestBefore').click();assert.equal(await page.evaluate(()=>session.currentBeat.notes.length),0);assert.equal(await page.evaluate(()=>session.currentBar.beats[1].notes[0].fret),13);await page.locator('#undo').click();
await page.locator('#techniques').click();await page.getByRole('button',{name:'掌根闷音 P.M.',exact:true}).click();assert.equal(await page.locator('#panel').evaluate(e=>e.open),false,'Common techniques leave the score available');
assert.equal(await page.evaluate(()=>session.currentNote.effects.isPalmMute),1);await page.getByRole('button',{name:'掌根闷音 P.M.',exact:true}).click();assert.equal(await page.evaluate(()=>session.currentNote.effects.isPalmMute),0);await page.getByRole('button',{name:'掌根闷音 P.M.',exact:true}).click();
await page.locator('#tab-note').click();await page.getByRole('button',{name:'全音推弦',exact:true}).click();
assert.equal(await page.evaluate(()=>session.currentNote.bend.length),2);
await page.locator('#appliedTechniques').click();assert.equal(await page.locator('[data-applied="note:isPalmMute"]').count(),1);
await page.locator('[data-applied="note:bend"]').getByRole('button',{name:'修改',exact:true}).click();
await page.getByLabel('控制点 2 变化半音',{exact:true}).fill('1.5');await page.getByLabel('控制点 2 变化半音',{exact:true}).press('Tab');assert.equal(await page.evaluate(()=>session.currentNote.bend[1].value),3);
await page.getByRole('button',{name:'添加控制点',exact:true}).click();assert.equal(await page.evaluate(()=>session.currentNote.bend.length),3);
await capture(page,'curve-editor.png');
await page.getByRole('button',{name:'全音',exact:true}).click();assert.equal(await page.getByLabel('控制点 2 变化半音',{exact:true}).inputValue(),'2','Preset refreshes editable points');await page.locator('#panelClose').click();
await page.locator('#appliedTechniques').click();await page.locator('[data-applied="note:isPalmMute"]').getByRole('button',{name:'取消',exact:true}).click();assert.equal(await page.evaluate(()=>session.currentNote.effects.isPalmMute),undefined);assert.equal(await page.evaluate(()=>session.currentNote.bend.length),2,'Removing PM keeps the bend');
await page.locator('#panelClose').click();await page.locator('#undo').click();assert.equal(await page.evaluate(()=>session.currentNote.effects.isPalmMute),1);
await page.locator('#appliedTechniques').click();await capture(page,'applied-techniques.png');await page.locator('#panelClose').click();
await page.locator('#bars').click();await page.getByLabel('插入空白小节数',{exact:true}).fill('2');await page.getByRole('button',{name:'在本小节后插入',exact:true}).click();assert.equal(await page.evaluate(()=>session.draft.bars.length),3);await page.locator('#undo').click();assert.equal(await page.evaluate(()=>session.draft.bars.length),1);
// Reflow's delete is deliberately two-stage: note -> rest -> removed beat.
await page.locator('#tab-beat').click();await page.locator('#insertAfter').click();await page.getByRole('button',{name:'7',exact:true}).click();
await page.locator('#deleteNote').click();assert.equal(await page.evaluate(()=>session.currentBar.beats.length),5);assert.equal(await page.evaluate(()=>session.currentBeat.notes.length),0);
await page.locator('#deleteNote').click();assert.equal(await page.evaluate(()=>session.currentBar.beats.length),4);
await page.locator('#beatLeft').click();await page.locator('#shiftKey').click();await page.locator('#beatRight').click();await page.locator('#techniques').click();
await page.getByRole('button',{name:'掌根闷音 P.M.',exact:true}).click();assert.equal(await page.locator('.scoreTarget.inRange').count(),12);await page.locator('#shiftKey').click();
await target(0,0,2).click();
const soundFont=await fs.readFile(path.join(root,'GpWeb/soundfont/sonivox.sf3'));await page.evaluate(b=>loadEditorSoundFont(b),soundFont.toString('base64'));await page.waitForFunction(()=>!document.getElementById('play').disabled,{timeout:30000});
await page.evaluate(()=>{const o=scoreEditor.api.player.output;window.audioProbe=o.context.createAnalyser();audioProbe.fftSize=2048;o.riffloopDestination.connect(audioProbe);const silent=o.context.createGain();silent.gain.value=0;audioProbe.connect(silent);silent.connect(o.context.destination);});
await page.locator('#play').click();await page.waitForFunction(()=>{const samples=new Float32Array(audioProbe.fftSize);audioProbe.getFloatTimeDomainData(samples);return samples.some(x=>Math.abs(x)>0.000001)});await page.waitForFunction(()=>scoreEditor.api.playerState===1&&scoreEditor.api.tickPosition>100);
await page.locator('#play').click();const paused=await page.evaluate(()=>scoreEditor.api.tickPosition);await page.waitForTimeout(350);assert.equal(await page.evaluate(()=>scoreEditor.api.playerState),0);assert.ok(Math.abs(await page.evaluate(()=>scoreEditor.api.tickPosition)-paused)<=2,'Paused MIDI position must remain fixed (integer tick rounding)');assert.equal(await page.evaluate(()=>scoreEditor.api.player.output.riffloopDestination.gain.value),0,'Pause immediately silences the audio gate');
await page.locator('#play').click();await page.locator('#stop').click();await page.waitForTimeout(350);assert.equal(await page.evaluate(()=>scoreEditor.api.playerState),0);assert.ok(await page.evaluate(()=>scoreEditor.api.tickPosition)<=1,'Stop returns to the first MIDI tick');assert.equal(await page.evaluate(()=>scoreEditor.api.player.output.riffloopDestination.gain.value),0);
await page.locator('#keypad button').filter({hasText:/^5$/}).click();await page.waitForFunction(()=>!document.getElementById('play').disabled);await page.locator('#play').click();await page.waitForFunction(()=>scoreEditor.api.playerState===1&&scoreEditor.api.tickPosition>100);await page.locator('#stop').click();
await page.locator('#save').click();assert.equal(await page.evaluate(()=>messages.at(-1).action),'save');await page.evaluate(()=>guitarReply({saved:true,message:'已保存同一份曲谱'}));assert.equal(await page.locator('#save').textContent(),'已保存');assert.equal(await page.locator('#export').count(),0);
// A synthetic multi-system score checks hit positions and the real mini layout.
await page.evaluate(()=>{session.change(d=>{d.title='电吉他编辑与试听';d.bars=Array.from({length:8},(_,i)=>({...GuitarEdit.bar(),section:i===0?'前奏':i===4?'主歌':'',beats:Array.from({length:8},(_,j)=>({...GuitarEdit.beat(8),notes:[GuitarEdit.note(j<4?2:3,[8,10,8,10,6,8,6,8][j])]}))}));d.bars[0].beats[2].notes.push(GuitarEdit.note(4,19));d.bars[2].beats[0].notes=[{string:4,effects:{},bend:[],review:['待核对']}];d.bars[0].beats[0].notes[0].effects.isHammerPullOrigin=1;d.bars[1].beats[3].notes[0].effects.vibrato=1;});session.bar=0;session.beat=1;session.string=2;render();});
await page.waitForSelector('.scoreTarget[data-bar="7"]');assert.equal(await target(2,0,4).textContent(),'?', 'Swift omitted nil frets remain visible as unknown notes');await target(0,1,2).click();assert.equal(await page.evaluate(()=>session.currentNote.fret),10);
await page.waitForFunction(()=>!document.getElementById('play').disabled);await page.locator('#techniques').click();
// Replay a real touch scroll over an engraved note. Pointer-down must not pick.
const touch=await page.context().newCDPSession(page);const hit=await target(0,2,2).boundingBox();
const barPoint=async(bar,beat=2,string=6)=>{
  const bounds=await target(bar,beat,string).boundingBox();
  return {x:bounds.x+bounds.width/2,y:bounds.y+bounds.height/2};
};
const firstPoint=await barPoint(0),secondPoint=await barPoint(1);
const startHold=async(point,mode='bars')=>{
  await touch.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[point]});
  await page.waitForFunction(mode=>mode==='notes'?session.noteRange:session.anchor?.wholeBars,mode);
};
// Drag backwards over three printed frets; the simultaneous fourth-string note stays out.
await startHold(await barPoint(0,3,2),'notes');
await touch.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[await barPoint(0,1,2)]});
await touch.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
assert.equal(await page.locator('#selection').textContent(),'已选 3 个音符');
assert.equal(await page.locator('.scoreTarget.noteInRange').count(),3);
assert.equal(await page.locator('.selectedHead:visible').count(),3);
await page.locator('#selectMode').tap();
await target(0,2,2).tap();
assert.equal(await page.locator('#selection').textContent(),'已选 2 个音符');
await target(0,2,4).tap();
assert.equal(await page.locator('#selection').textContent(),'已选 3 个音符');
await page.locator('#editMode').tap();
assert.equal(await page.locator('#selection').textContent(),'已选 3 个音符');
await page.getByRole('button',{name:'掌根闷音 P.M.',exact:true}).tap();
assert.deepEqual(await page.evaluate(()=>session.currentBar.beats.slice(0,4).map(b=>b.notes.map(n=>n.effects.isPalmMute||0))),[[0],[1],[0,1],[1]]);
await page.locator('#undo').tap();
await target(0,1,2).tap();
// A staff notehead starts the same note selection.
const headPoint=await page.evaluate(()=>{
  const note=scoreEditor.notesByBar[0].find(n=>n.beat===1&&n.string===2).boxes[1];
  const rect=document.querySelector('#engraving').getBoundingClientRect();
  return {x:rect.left+note.x,y:rect.top+note.y};
});
await startHold(headPoint,'notes');
await touch.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
assert.equal(await page.locator('#selection').textContent(),'已选 1 个音符');
await target(0,1,2).tap();
await startHold(secondPoint);
await touch.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[firstPoint]});
await touch.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
assert.deepEqual(await page.evaluate(()=>[session.firstBar,session.lastBar,session.selectedBeats.length]),[0,1,16]);
assert.equal(await page.locator('.barRanges>div:visible').count(),2);
await page.getByRole('button',{name:'掌根闷音 P.M.',exact:true}).click();
assert.ok(await page.evaluate(()=>session.targets('note').every(n=>n.effects.isPalmMute===1)));
await page.locator('#copyBeat').click();
await page.locator('#pasteBeat').click();
assert.deepEqual(await page.evaluate(()=>session.draft.bars.slice(0,2)),await page.evaluate(()=>session.draft.bars.slice(2,4)));
await page.locator('#undo').click();
await page.locator('#undo').click();
await target(0,1,2).tap();
await startHold(firstPoint);
await touch.send('Input.dispatchTouchEvent',{type:'touchCancel',touchPoints:[]});
assert.deepEqual(await page.evaluate(()=>[session.bar,session.beat,session.anchor]),[0,1,null]);
const beforeTouch=await page.evaluate(()=>[session.bar,session.beat,session.string]);
await touch.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:hit.x+15,y:hit.y+hit.height/2}]});
assert.deepEqual(await page.evaluate(()=>[session.bar,session.beat,session.string]),beforeTouch,'Finger-down is not selection');
for(let step=1;step<=6;step++)await touch.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:hit.x+15,y:hit.y+hit.height/2-step*18}]});
await touch.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
await page.waitForTimeout(350);assert.deepEqual(await page.evaluate(()=>[session.bar,session.beat,session.string]),beforeTouch,'Scroll must not pick or extend notes');
assert.ok(await page.locator('#scoreViewport').evaluate(e=>e.scrollTop)>40,'Touch scroll moved the page');
await page.locator('#scoreViewport').evaluate(e=>e.scrollTop=600);
const scrolled=await page.locator('#scoreViewport').evaluate(e=>e.scrollTop);
assert.ok(scrolled>40,'Touch scrolling remains available');await page.locator('#tab-note').click();
assert.equal(await page.locator('#scoreViewport').evaluate(e=>e.scrollTop),scrolled,'Switching tools must not pull the page back to the edit cursor');
await page.locator('#shiftKey').click();assert.equal(await page.locator('#scoreViewport').evaluate(e=>e.scrollTop),scrolled,'Range mode does not move the page');await page.evaluate(()=>guitarReply({saved:true}));assert.equal(await page.locator('#scoreViewport').evaluate(e=>e.scrollTop),scrolled,'Saved reply does not move the page');await page.locator('#shiftKey').click();
// Push from the centre with a real touch. Neutral, release and cancel stop repetition.
await target(0,1,2).tap();
const stick=await page.locator('.navButtons').boundingBox();
const center={x:stick.x+stick.width/2,y:stick.y+stick.height/2};
const right={x:center.x+stick.width*.46,y:center.y};
const down={x:center.x,y:center.y+stick.height*.45};
const gesture=(type,point)=>touch.send('Input.dispatchTouchEvent',{type,touchPoints:point?[point]:[]});
await gesture('touchStart',center);
await gesture('touchMove',right);
assert.equal(await page.evaluate(()=>session.beat),2);
await page.waitForTimeout(260);
assert.equal(await page.evaluate(()=>session.beat),2,'First step has a deliberate pause');
await page.waitForFunction(()=>session.beat>=4);
await gesture('touchMove',center);
const rested=await page.evaluate(()=>session.beat);await page.waitForTimeout(450);
assert.equal(await page.evaluate(()=>session.beat),rested);
await gesture('touchMove',down);
await gesture('touchEnd');
assert.deepEqual(await page.evaluate(()=>[session.string,session.anchor]),[3,null]);
await page.waitForTimeout(500);
assert.equal(await page.evaluate(()=>session.string),3);
await gesture('touchStart',right);await gesture('touchCancel');
const cancelled=await page.evaluate(()=>session.beat);await page.waitForTimeout(500);
assert.equal(await page.evaluate(()=>session.beat),cancelled);
await target(7,7,3).tap();await gesture('touchStart',right);
await page.waitForTimeout(650);await gesture('touchEnd');
assert.deepEqual(await page.evaluate(()=>[session.draft.bars.length,session.beat]),[8,7],'Holding at the end cannot create measures');
assert.equal(await page.locator('#toolTabs [role=tab]').count(),8);
await page.locator('#selectMode').click();
const oldRange=await page.evaluate(()=>JSON.stringify([session.bar,session.beat,session.string,session.anchor]));
await target(7,0,2).evaluate(el=>{el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,pointerId:90,clientX:100,clientY:100}));window.dispatchEvent(new PointerEvent('pointercancel',{bubbles:true,pointerId:90}));el.click();});
assert.equal(await page.evaluate(()=>JSON.stringify([session.bar,session.beat,session.string,session.anchor])),oldRange,'Cancelled drag and compatibility click never extend selection');
await page.locator('#editMode').click();await target(7,0,2).tap();assert.equal(await page.evaluate(()=>session.bar),7,'A fresh single tap still selects after a cancelled gesture');

await capture(page,'editor-mini.png');

await checkControls(page);
await page.locator('#barChoice').selectOption('7');await page.waitForTimeout(100);
const reached=await target(7,0,2).boundingBox();assert.ok(reached.y>100&&reached.y<480,'Bar navigation brings selection above floating controls');
await page.evaluate(()=>{window.rotated=false;scoreEditor.api.renderFinished.on(()=>setTimeout(()=>window.rotated=true,100));});await page.setViewportSize({width:744,height:1133});await page.waitForFunction(()=>window.rotated);await page.waitForFunction(()=>{const r=document.querySelector('.scoreTarget[data-bar="7"][data-beat="0"][data-string="2"]')?.getBoundingClientRect();return r&&r.y>160&&r.y<680});assert.ok(await page.evaluate(()=>document.querySelector('#keypad').getBoundingClientRect().right<=innerWidth),'Portrait keypad stays on screen');await capture(page,'editor-portrait.png');
await checkControls(page);
await page.locator('#settings').click();
const title=page.getByLabel('曲名',{exact:true});
await title.focus();await title.press('Control+a');
assert.equal(await title.evaluate(el=>el.value.slice(el.selectionStart,el.selectionEnd)),await title.inputValue());
await page.locator('#panelClose').click();
await page.locator('#tab-beat').dblclick();
assert.equal(await page.evaluate(()=>window.getSelection().toString()),'','Double tapping a tool cannot copy its caption');
assert.equal(await page.locator('#tab-beat span').evaluate(el=>el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}))),false);
assert.equal(await page.locator('img.toolIcon').evaluateAll(images=>images.every(i=>i.complete&&i.naturalWidth>0)),true,'All bundled icons load');assert.deepEqual(errors,[]);const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert.equal(overflow,false,'No page-level horizontal overflow');
console.log('iPad mini: direct score/string selection, frets, techniques, local bars, real playback/pause/stop and one Save passed');

const gpPage=await browser.newPage({viewport:{width:1133,height:744},hasTouch:true});
await gpPage.addInitScript(()=>{window.messages=[];window.webkit={messageHandlers:{guitarEditor:{postMessage:m=>messages.push(m)}}};});
await gpPage.goto(page.url());await gpPage.waitForFunction(()=>window.messages.some(m=>m.action==='ready'));
await gpPage.evaluate(({fixture,schema})=>{
  const a=alphaTab,m=a.model;
  const d={...fixture,bars:[{...GuitarEdit.bar(),beats:[8,8,11,8].map(f=>({...GuitarEdit.beat(),notes:[GuitarEdit.note(1,f)]}))}]};
  const score=GuitarDraftCore.makeScore(a,d,schema),other=GuitarDraftCore.makeScore(a,d,schema).tracks[0];
  other.name='Bass reference';score.addTrack(other);
  const v=new m.Voice();score.tracks[0].staves[0].bars[0].addVoice(v);
  const b=new m.Beat();v.addBeat(b);b.duration=1;const n=new m.Note();n.string=4;n.fret=9;b.addNote(n);
  score.finish(new a.Settings());
  const bytes=new a.exporter.Gp7Exporter().export(score,new a.Settings()),zip=fflate.unzipSync(bytes);
  zip['Content/keep.bin']=new Uint8Array([255,0,13,87,71]);
  const encoded=fflate.zipSync(zip);window.fixtureGP=encoded;
  loadExistingGuitarGP(btoa(String.fromCharCode(...encoded)),schema);
},{fixture,schema});
await gpPage.getByRole('button',{name:'Electric Guitar · 声部 1',exact:true}).tap();
await gpPage.locator('.scoreTarget[data-beat="1"][data-string="1"]').first().tap();
await gpPage.locator('#keypad button').filter({hasText:/^7$/}).tap();
await gpPage.locator('#tab-harmonic').tap();await gpPage.getByRole('button',{name:'自然泛音',exact:true}).tap();
await gpPage.getByRole('button',{name:'泛音音高',exact:true}).tap();assert.equal(await gpPage.getByLabel('泛音音高',{exact:true}).inputValue(),'7');await gpPage.locator('#panelClose').tap();
await gpPage.locator('#techniques').tap();await gpPage.getByRole('button',{name:'踏板踩下 Ped.',exact:true}).tap();
await gpPage.locator('.scoreTarget[data-beat="3"][data-string="1"]').first().tap();await gpPage.getByRole('button',{name:'踏板松开 ✱',exact:true}).tap();
await gpPage.locator('#save').tap();
const inspected=await gpPage.evaluate(()=>{
  const msg=messages.findLast(x=>x.action==='saveGP');if(!msg)throw Error(document.getElementById('status').textContent);
  const bytes=Uint8Array.from(atob(msg.file),c=>c.charCodeAt(0)),score=alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes,new alphaTab.Settings());
  const zip=fflate.unzipSync(bytes),original=fflate.unzipSync(fixtureGP);
  for(const key of Object.keys(original))if(key!=='Content/score.gpif'&&String(zip[key])!==String(original[key]))throw Error('Changed '+key);
  const bars=score.tracks.map(t=>t.staves[0].bars[0]);
  return [bars[0].voices[0].beats.map(b=>b.notes[0].fret),bars[1].voices[0].beats.map(b=>b.notes[0].fret),bars[0].voices[1].beats[0].notes[0].fret,bars[0].voices[0].beats[1].notes[0].realValue,bars[0].sustainPedals.map(p=>[p.ratioPosition,p.pedalType])];
});
assert.deepEqual(inspected,[[8,7,11,8],[8,8,11,8],9,83,[[.25,0],[.75,2]]]);
await gpPage.evaluate(()=>guitarReply({saved:true}));await gpPage.locator('#save').tap();
assert.equal(await gpPage.evaluate(()=>{const saved=messages.filter(x=>x.action==='saveGP');return saved.length===2&&saved[0].file===saved[1].file;}),true);
await gpPage.close();console.log('Existing GP: touch edit, save twice, harmonic pitch, pedals, second voice, other track and ZIP attachments passed');
}finally{if(browser){const active=browser.contexts()[0]?.pages()[0];if(active){await capture(active,'editor-latest.png').catch(()=>{});}await browser.close();}await new Promise(r=>server.close(r));}})().catch(e=>{console.error(e.stack);process.exitCode=1;});

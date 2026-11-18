'use strict';
// The same score model drives engraving, hit targets and audition; selection
// never changes the stored note/string and edits always stop the old MIDI first.
class GuitarScoreSurface {
  constructor(element, overlay, onSelect, onState, onError, onBarSelection) {
    this.element=element;this.overlay=overlay;this.onSelect=onSelect;this.onState=onState;this.onError=onError;
    this.serialized='';this.selection={bar:0,beat:0,string:1};this.ready=false;this.wantsPlay=false;this.scale=1.1;
    this.api=new alphaTab.AlphaTabApi(element,{
      core:{scriptFile:new URL('../GpWeb/alphaTab.min.js',location.href).href,fontDirectory:'../GpWeb/font/',useWorkers:false,includeNoteBounds:true,enableLazyLoading:false},
      display:{layoutMode:alphaTab.LayoutMode.Page,staveProfile:alphaTab.StaveProfile.ScoreTab,scale:this.scale},
      player:{playerMode:alphaTab.PlayerMode.EnabledSynthesizer,soundFont:null,enableCursor:true,enableUserInteraction:false,enableElementHighlighting:true,scrollElement:'#scoreViewport',scrollMode:alphaTab.ScrollMode.Off}
    });
    this.revealPending=false;
    this.tapGuard=new GuitarTapGuard(document.getElementById('scoreViewport'));
    this.barRects=[];
    this.barDrag=new GuitarBarDrag(document.getElementById('paper'),document.getElementById('scoreViewport'),{
      hit:(x,y,nearest)=>this.barAt(x,y,nearest),
      tap:(x,y)=>{
        if(!this.tapGuard.gesture?.moved)this.tapAt(x,y,document.elementFromPoint(x,y));
      },
      begin:first=>{
        this.pause();
        this.revealPending=false;
        if(this.tapGuard.gesture)this.tapGuard.gesture.moved=true;
        onBarSelection.begin(first);
      },
      extend:(first,last)=>onBarSelection.extend(first,last),
      end:cancel=>onBarSelection.end(cancel)
    });
    this.onPaperClick=e=>{
      if(!e.target.closest('.scoreTarget'))this.tapAt(e.clientX,e.clientY,e.target);
    };
    document.getElementById('paper').addEventListener('click',this.onPaperClick);
    this.onResize=()=>{const selected=this.overlay.querySelector('.selected');if(selected){const r=selected.getBoundingClientRect();if(r.bottom>0&&r.top<innerHeight)this.revealPending=true;}};
    window.addEventListener('resize',this.onResize);
    this.api.renderFinished.on(()=>requestAnimationFrame(()=>this.drawTargets()));
    this.api.playerReady.on(()=>{this.ready=true;this.configureOutput();this.onState({ready:true,playing:false});});
    this.api.playerStateChanged.on(e=>{
      if(e.state===1&&!this.wantsPlay){this.pause();return;}
      if(e.state===0&&!this.wantsPlay&&this.pauseTick!=null)this.api.tickPosition=this.pauseTick;
      this.onState({ready:this.ready,playing:e.state===1});
    });
    this.api.playerFinished.on(()=>{this.wantsPlay=false;this.onState({ready:this.ready,playing:false});});
    this.api.playedBeatChanged.on(b=>{
      if(!this.wantsPlay||!b)return;
      const target=this.overlay.querySelector(`[data-bar="${b.voice.bar.index}"][data-beat="${b.index}"][data-string="1"]`);
      if(target){const r=target.getBoundingClientRect(),v=document.getElementById('scoreViewport').getBoundingClientRect();if(r.top<v.top+90||r.bottom>v.bottom-240)target.scrollIntoView({block:'center',inline:'nearest'});}
    });
    this.api.error.on(e=>{this.pause();this.onError(e.message||String(e));});
    // The renderer must never select on finger-down: that may be a scroll.
    // TAB targets and staff note heads only select after a completed click.
  }
  tapAt(clientX,clientY,element){
    if(document.body.classList.contains('reading')||!element?.closest('#paper'))return;
    const tab=element.closest('.scoreTarget');
    if(tab){this.pick(+tab.dataset.bar,+tab.dataset.beat,+tab.dataset.string);return;}
    const rect=this.element.getBoundingClientRect(),x=clientX-rect.left,y=clientY-rect.top;
    const lookup=this.api.renderer.boundsLookup;
    const beat=lookup?.getBeatAtPos(x,y);
    if(!beat)return;
    const note=lookup.getNoteAtPos(beat,x,y);
    if(note)this.pick(beat.voice.bar.index,beat.index,7-note.string);
    else if(beat.isRest&&lookup.findBeats(beat)?.some(b=>y>=b.barBounds.visualBounds.y&&y<=b.barBounds.visualBounds.y+b.barBounds.visualBounds.h))this.pick(beat.voice.bar.index,beat.index,this.selection.string);
  }
  barAt(clientX,clientY,nearest=false){
    if(document.body.inert||document.body.classList.contains('reading')||!this.barRects.length)return null;
    const rect=this.element.getBoundingClientRect();
    const x=clientX-rect.left,y=clientY-rect.top;
    let best=null,distance=Infinity;
    for(const {bar,bounds} of this.barRects){
      const dx=Math.max(bounds.x-x,0,x-bounds.x-bounds.w);
      const dy=Math.max(bounds.y-y,0,y-bounds.y-bounds.h);
      if(!dx&&!dy)return bar;
      if(nearest&&dx*dx+dy*dy<distance){best=bar;distance=dx*dx+dy*dy;}
    }
    return best;
  }
  paintBarRange(){
    const session=this.editSession;
    for(const {bar,shade} of this.barRects){
      shade.hidden=!session?.anchor?.wholeBars||bar<session.firstBar||bar>session.lastBar;
    }
  }
  configureOutput(){window.RiffLoopAudio.install(this.api.player?.output);}
  loadSoundFont(bytes){this.api.loadSoundFont(bytes,false);}
  update(draft,selection,schema,reveal=false){
    if(reveal)this.revealPending=true;
    this.selection={bar:selection.bar,beat:selection.beat,string:selection.string};this.editSession=selection;this.draft=draft;
    const encoded=JSON.stringify(draft);
    if(encoded!==this.serialized){
      this.barRects=[];this.pause();this.serialized=encoded;this.ready=false;this.onState({ready:false,playing:false});
      this.score=GuitarDraftCore.makeScore(alphaTab,draft,schema,false);
      this.api.renderScore(this.score,[0]);
    }else {this.highlight();this.finishReveal();}
  }
  drawTargets(){
    this.overlay.replaceChildren();if(!this.score)return;
    const lookup=this.api.renderer.boundsLookup;
    const ranges=document.createElement('div');
    ranges.className='barRanges';
    this.overlay.append(ranges);
    this.barRects=[];
    for(let bar=0;bar<this.score.masterBars.length;bar++){
      const bounds=lookup.findMasterBarByIndex(bar)?.realBounds;
      if(!bounds)continue;
      const shade=document.createElement('div');
      Object.assign(shade.style,{left:bounds.x+'px',top:bounds.y+'px',width:bounds.w+'px',height:bounds.h+'px'});
      ranges.append(shade);
      this.barRects.push({bar,bounds,shade});
    }
    for(const [bi,bar] of this.score.tracks[0].staves[0].bars.entries())for(const [ti,beat] of bar.voices[0].beats.entries()){
      const bounds=lookup.findBeats(beat);if(!bounds?.length)continue;
      const tab=bounds.reduce((a,b)=>a.barBounds.visualBounds.y>b.barBounds.visualBounds.y?a:b),rect=tab.barBounds.visualBounds,spacing=rect.h/5;
      for(let string=1;string<=6;string++){
        const n=this.draft.bars[bi].beats[ti].notes.find(n=>n.string===string),target=document.createElement('button');
        target.className='scoreTarget';target.dataset.bar=bi;target.dataset.beat=ti;target.dataset.string=string;
        target.setAttribute('aria-label',`第 ${bi+1} 小节 第 ${ti+1} 拍位 第 ${string} 弦 ${n?(n.fret??'待核对'):'空'}`);
        Object.assign(target.style,{left:`${tab.onNotesX-15}px`,top:`${rect.y+(string-1)*spacing-spacing/2}px`,width:'30px',height:`${Math.max(10,spacing)}px`});
        if(n&&n.fret==null){target.textContent='?';target.classList.add('unknown');}
        target.onclick=()=>this.pick(bi,ti,string);this.overlay.append(target);
      }
    }
    this.highlight();this.finishReveal();
  }
  finishReveal(){if(this.revealPending&&!this.wantsPlay){this.revealPending=false;this.revealSelection();}}
  highlight(){this.paintBarRange();for(const target of this.overlay.querySelectorAll('.scoreTarget')){const active=+target.dataset.bar===this.selection.bar&&+target.dataset.beat===this.selection.beat&&+target.dataset.string===this.selection.string;target.classList.toggle('selected',active);target.classList.toggle('inRange',!this.editSession?.anchor?.wholeBars&&!!this.editSession?.isSelected(+target.dataset.bar,+target.dataset.beat));target.setAttribute('aria-pressed',String(active));}}
  pick(bar,beat,string){this.pause();this.onSelect(bar,beat,string);}
  seekSelection(){const b=this.score?.tracks[0].staves[0].bars[this.selection.bar]?.voices[0].beats[this.selection.beat];if(b){this.pauseTick=b.absolutePlaybackStart;this.api.tickPosition=this.pauseTick;}}
  revealSelection(){
    const target=this.overlay.querySelector(`[data-bar="${this.selection.bar}"][data-beat="${this.selection.beat}"][data-string="${this.selection.string}"]`);
    if(!target)return;
    const viewport=document.getElementById('scoreViewport'),r=target.getBoundingClientRect(),v=viewport.getBoundingClientRect();
    let top=v.top+16,bottom=v.bottom-16;
    for(const selector of ['header','.documentTools','#status','.navigator','.editDock','.rightDock']){
      const el=document.querySelector(selector);if(!el?.getClientRects().length)continue;
      const box=el.getBoundingClientRect();if(r.right<box.left||r.left>box.right)continue;
      if(box.top<v.top+v.height/2)top=Math.max(top,box.bottom+12);else bottom=Math.min(bottom,box.top-12);
    }
    if(r.top<top||r.bottom>bottom)viewport.scrollBy({top:(r.top+r.bottom-top-bottom)/2});
    if(r.left<v.left+12||r.right>v.right-12)viewport.scrollBy({left:(r.left+r.right-v.left-v.right)/2});
  }
  play(){
    if(!this.ready)return false;this.configureOutput();this.pauseTick=null;this.wantsPlay=true;
    this.api.player?.output?.riffloopSetPlaybackAllowed?.(true);
    this.api.player?.output?.activate();this.api.play();return true;
  }
  pause(){this.pauseTick=this.api.tickPosition;this.wantsPlay=false;this.configureOutput();this.api.player?.output?.riffloopSetPlaybackAllowed?.(false);this.api.pause();this.api.tickPosition=this.pauseTick;this.onState({ready:this.ready,playing:false});}
  stop(){this.pause();this.pauseTick=0;this.api.stop();this.api.tickPosition=0;}
  loop(enabled){this.api.isLooping=enabled;}
  zoom(delta){this.pause();this.scale=Math.max(.7,Math.min(2,this.scale+delta));this.api.settings.display.scale=this.scale;this.api.updateSettings();this.api.render();}
  destroy(){window.removeEventListener('resize',this.onResize);document.getElementById('paper').removeEventListener('click',this.onPaperClick);this.barDrag.destroy();this.tapGuard.destroy();this.stop();this.api.destroy();}
}
window.GuitarScoreSurface=GuitarScoreSurface;

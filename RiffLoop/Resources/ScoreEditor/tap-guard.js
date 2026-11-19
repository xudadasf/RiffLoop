'use strict';
// Keep scrolling/pinching separate from taps, including WebKit's compatibility
// click after a cancelled pointer. Do not prevent native pan or zoom gestures.
class GuitarTapGuard {
  constructor(element){
    this.active=new Set();this.gesture=null;
    element.addEventListener('pointerdown',e=>{
      this.active.add(e.pointerId);
      if(this.active.size>1){if(this.gesture)this.gesture.moved=true;return;}
      this.gesture={id:e.pointerId,x:e.clientX,y:e.clientY,moved:false};
    },{capture:true,passive:true});
    element.addEventListener('pointermove',e=>{const g=this.gesture;if(g&&g.id===e.pointerId&&Math.hypot(e.clientX-g.x,e.clientY-g.y)>8)g.moved=true;},{capture:true,passive:true});
    this.end=e=>{this.active.delete(e.pointerId);if(this.gesture?.id===e.pointerId&&(e.type==='pointercancel'||Math.hypot(e.clientX-this.gesture.x,e.clientY-this.gesture.y)>8))this.gesture.moved=true;};
    // Releases may be outside the score (for example on a floating control).
    window.addEventListener('pointerup',this.end,{capture:true,passive:true});
    window.addEventListener('pointercancel',this.end,{capture:true,passive:true});
    element.addEventListener('scroll',()=>{if(this.active.size&&this.gesture)this.gesture.moved=true;},{capture:true,passive:true});
    element.addEventListener('click',e=>{if(this.gesture?.moved){e.preventDefault();e.stopImmediatePropagation();}},{capture:true});
    element.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' ')this.gesture=null;},{capture:true});
  }
  destroy(){window.removeEventListener('pointerup',this.end,true);window.removeEventListener('pointercancel',this.end,true);}
}
window.GuitarTapGuard=GuitarTapGuard;

/* A passive start leaves ordinary scrolling to WebKit. Only consume move
   events once a stationary finger has held a score position long enough to select it. */
class GuitarRangeDrag {
  constructor(paper,viewport,callbacks){
    this.paper=paper;
    this.viewport=viewport;
    this.callbacks=callbacks;
    this.listeners=new AbortController();
    const listen=(element,type,fn,passive=true)=>element.addEventListener(type,fn,{
      capture:true,passive,signal:this.listeners.signal
    });
    listen(document,'touchstart',e=>{
      if(e.touches.length!==1){this.finish(true);return;}
      if(!paper.contains(e.target))return;
      const point=e.touches[0];
      const first=callbacks.hit(point.clientX,point.clientY);
      if(first==null)return;
      this.finish(true);
      const g=this.gesture={id:point.identifier,x:point.clientX,y:point.clientY,first,last:first,active:false};
      g.timer=setTimeout(()=>{
        if(this.gesture!==g)return;
        const current=callbacks.hit(g.x,g.y);
        const sameNote=first&&current&&typeof first==='object'&&typeof current==='object'&&
          current.bar===first.bar&&current.beat===first.beat&&current.string===first.string;
        if(current!==first&&!sameNote)return;
        g.active=true;
        callbacks.begin(first);
      },450);
    });
    listen(paper,'touchmove',e=>{
      const g=this.gesture;
      if(!g)return;
      const point=e.touches[0];
      if(e.touches.length!==1||point.identifier!==g.id){this.finish(true);return;}
      if(!g.active){
        if(Math.hypot(point.clientX-g.x,point.clientY-g.y)>8)this.finish(true);
        return;
      }
      if(!e.cancelable){this.finish(true);return;}
      e.preventDefault();
      g.x=point.clientX;g.y=point.clientY;
      this.updateEnd();
      if(!this.frame)this.frame=requestAnimationFrame(()=>this.scrollEdge());
    },false);
    listen(window,'touchend',e=>{
      if(!this.gesture)return;
      const g=this.gesture;
      const point=Array.from(e.changedTouches).find(t=>t.identifier===g.id);
      if(!point)return;
      if(g.active){
        if(e.cancelable)e.preventDefault();
        if(point.clientX!==g.x||point.clientY!==g.y){g.x=point.clientX;g.y=point.clientY;this.updateEnd();}
      }
      if(!g.active&&e.cancelable&&Math.hypot(point.clientX-g.x,point.clientY-g.y)<=8){
        // A compatibility click may be omitted after a cancelled gesture.
        // Deliver this completed tap once, after excluding pans and pinches.
        e.preventDefault();
        callbacks.tap(point.clientX,point.clientY);
      }
      this.finish(false);
    },false);
    listen(window,'touchcancel',()=>this.finish(true));
    listen(viewport,'scroll',()=>{if(!this.gesture?.active)this.finish(true);});
    listen(paper,'contextmenu',e=>{if(this.gesture)e.preventDefault();},false);
    listen(window,'blur',()=>this.finish(true));
    listen(document,'visibilitychange',()=>{if(document.hidden)this.finish(true);});
  }
  updateEnd(){
    const g=this.gesture;
    const last=this.callbacks.hit(g.x,g.y,true,g.first);
    if(last!=null&&last!==g.last){g.last=last;this.callbacks.extend(g.first,last);}
  }
  scrollEdge(){
    this.frame=0;
    const g=this.gesture;
    if(!g?.active)return;
    const rect=this.viewport.getBoundingClientRect();
    const delta=g.y<rect.top+44?-8:g.y>rect.bottom-44?8:0;
    const before=this.viewport.scrollTop;
    this.viewport.scrollTop+=delta;
    if(this.viewport.scrollTop!==before){
      this.updateEnd();
      this.frame=requestAnimationFrame(()=>this.scrollEdge());
    }
  }
  finish(cancel){
    const g=this.gesture;
    if(!g)return;
    this.gesture=null;
    clearTimeout(g.timer);
    cancelAnimationFrame(this.frame);
    this.frame=0;
    if(g.active)this.callbacks.end(cancel);
    this.callbacks.settled?.();
  }
  destroy(){this.finish(true);this.listeners.abort();}
}

class GuitarJoystick {
  constructor(pad,step,locate){
    const knob=pad.querySelector('#thumbPad');
    let pointer=null, timer=0, direction='', reach=0, moved=false;
    const vectors={left:[-1,0],right:[1,0],up:[0,-1],down:[0,1]};
    const reset=()=>{
      clearTimeout(timer);
      pointer=null;direction='';reach=0;
      knob.style.transform='';
      delete pad.dataset.direction;
    };
    const repeat=()=>{
      if(!direction||pointer===null)return;
      step(...vectors[direction]);
      timer=setTimeout(repeat,Math.round(340-175*reach));
    };
    const update=e=>{
      const box=pad.getBoundingClientRect();
      const x=(e.clientX-box.left-box.width/2)/(box.width/2);
      const y=(e.clientY-box.top-box.height/2)/(box.height/2);
      const distance=Math.hypot(x,y);
      const scale=Math.max(1,distance);
      knob.style.transform='translate('+x/scale*box.width*.25+'px,'+y/scale*box.height*.25+'px)';
      reach=Math.max(0,Math.min(1,(distance-.25)/.75));
      let next='';
      if(distance>(direction ? .19 : .25)){
        const horizontal=Math.abs(x)>Math.abs(y);
        const diagonal=Math.abs(Math.abs(x)-Math.abs(y))<distance*.15;
        const keepAxis=diagonal&&direction;
        const useX=keepAxis?(direction==='left'||direction==='right'):horizontal;
        next=useX?(x<0?'left':'right'):(y<0?'up':'down');
      }
      if(next===direction)return;
      clearTimeout(timer);
      direction=next;pad.dataset.direction=next;
      if(direction){moved=true;step(...vectors[direction]);timer=setTimeout(repeat,450);}
    };
    pad.addEventListener('pointerdown',e=>{
      if(pointer!==null||!e.isPrimary||e.button!==0)return;
      e.preventDefault();pointer=e.pointerId;moved=false;
      pad.setPointerCapture(pointer);update(e);
    });
    pad.addEventListener('pointermove',e=>{if(e.pointerId===pointer)update(e);});
    pad.addEventListener('pointerup',e=>{
      if(e.pointerId!==pointer)return;
      const centerTap=!moved;reset();
      if(centerTap)locate();
    });
    for(const event of ['pointercancel','lostpointercapture'])pad.addEventListener(event,e=>{if(e.pointerId===pointer)reset();});
    pad.addEventListener('click',e=>{if(e.detail>0){e.preventDefault();e.stopImmediatePropagation();}},true);
    window.addEventListener('blur',reset);
    document.addEventListener('visibilitychange',()=>{if(document.hidden)reset();});
  }
}

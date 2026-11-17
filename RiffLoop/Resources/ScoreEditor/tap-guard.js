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

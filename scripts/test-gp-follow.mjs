import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { createScoreFollow } = createRequire(import.meta.url)('../RiffLoop/Resources/GpWeb/riffloop-follow.js');

let now = 0, playing = true, frame, timer;
const viewport = { scrollTop: 0, clientHeight: 600, scrollHeight: 3000 };
const follow = createScoreFollow({
    viewport, now: () => now, isPlaying: () => playing,
    requestFrame: fn => { frame = fn; return 1; }, cancelFrame: () => { frame = null; },
    schedule: fn => { timer = fn; return 1; }, cancelSchedule: () => { timer = null; }
});
const advance = ms => { now += ms; const fn = frame; frame = null; fn?.(); };
follow.follow({ y: 500, h: 160 });
assert.equal(viewport.scrollTop, 0, 'following must animate, never jump');
advance(250);
assert.ok(viewport.scrollTop > 0 && viewport.scrollTop < 280);
advance(500);
assert.equal(viewport.scrollTop, 280);

follow.interact();
follow.browse();
viewport.scrollTop = 1200;
follow.follow({ y: 700, h: 160 });
assert.equal(viewport.scrollTop, 1200, 'playback must not fight a finger browsing the score');
assert.equal(timer, undefined, 'do not time out while a finger is down');
follow.release();
assert.ok(timer);
follow.follow({ y: 900, h: 160 });
{ const fn = timer; timer = null; fn(); }
advance(700);
assert.equal(viewport.scrollTop, 680, 'return to the latest playback position, not the old one');

follow.select({ y: 1000, h: 160 });
advance(700);
assert.equal(viewport.scrollTop, 680, 'a visible tap must keep the viewport stable');
follow.follow({ y: 1000, h: 160 });
advance(700);
assert.equal(viewport.scrollTop, 680, 'subsequent position callbacks must not immediately recenter a visible tap');
follow.interact();
follow.browse();
viewport.scrollTop = 1800;
follow.release();
follow.select({ y: 1900, h: 160 });
advance(700);
assert.equal(viewport.scrollTop, 1680, 'a tap after browsing should smoothly center the selected row');
assert.equal(timer, null, 'a stale browsing timeout must not return to the old location');

follow.interact();
follow.browse();
follow.release();
playing = false;
{ const fn = timer; timer = null; fn(); }
assert.equal(frame, null, 'a paused player must not pull the score back');
follow.reset();
assert.equal(timer, null);

playing = true;
follow.follow({ y: 500, h: 160 }, 420);
advance(700);
follow.interact();
follow.browse();
viewport.scrollTop = 1800;
follow.follow({ y: 700, h: 160 }, 420);
follow.release();
{ const fn = timer; timer = null; fn(); }
advance(700);
assert.equal(viewport.scrollTop, 420, 'return from browsing must keep a fitting loop centered as a group');

follow.reset();
follow.follow({ y: 1600, h: 160 });
advance(100);
follow.interact();
follow.release();
follow.follow({ y: 1600, h: 160 });
advance(700);
assert.equal(viewport.scrollTop, 1380, 'a touch must not permanently cancel following on the same row');
console.log('GP smooth follow / browsing / selection tests passed');

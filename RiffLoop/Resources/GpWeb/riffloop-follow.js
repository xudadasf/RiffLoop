(function (root) {
    "use strict";
    const createScoreFollow = ({ viewport, isPlaying, now = () => performance.now(),
        requestFrame = requestAnimationFrame, cancelFrame = cancelAnimationFrame,
        schedule = setTimeout, cancelSchedule = clearTimeout }) => {
        let animation = null, timeout = null, touching = false, browsing = false;
        let latest = null, latestTarget = null, lastRow = null, destination = null;
        const cancelAnimation = () => {
            if (animation !== null) cancelFrame(animation);
            animation = null;
            destination = null;
        };
        const cancelReturn = () => {
            if (timeout !== null) cancelSchedule(timeout);
            timeout = null;
        };
        const center = bounds => Math.max(0, bounds.y + bounds.h / 2 - viewport.clientHeight / 2);
        const move = top => {
            const target = Math.max(0, Math.min(top, viewport.scrollHeight - viewport.clientHeight));
            if (touching || browsing || target === destination) return;
            cancelAnimation();
            const start = viewport.scrollTop, started = now();
            if (Math.abs(target - start) < 2) return;
            destination = target;
            const duration = Math.min(650, 350 + Math.abs(target - start) * 0.15);
            const step = () => {
                const progress = Math.min(1, (now() - started) / duration);
                const eased = progress * progress * (3 - 2 * progress);
                viewport.scrollTop = start + (target - start) * eased;
                if (progress < 1) animation = requestFrame(step);
                else { animation = null; destination = null; }
            };
            animation = requestFrame(step);
        };
        const release = () => {
            touching = false;
            cancelReturn();
            if (!browsing) return;
            timeout = schedule(() => {
                timeout = null;
                browsing = false;
                if (isPlaying() && latest) {
                    lastRow = latest.y;
                    move(latestTarget ?? center(latest));
                }
            }, 3000);
        };
        return {
            follow(bounds, targetTop = null) {
                if (!bounds) return;
                latest = bounds;
                latestTarget = targetTop;
                if (!isPlaying() || touching || browsing || lastRow === bounds.y) return;
                lastRow = bounds.y;
                move(targetTop ?? center(bounds));
            },
            select(bounds) {
                if (!bounds) return;
                const wasBrowsing = browsing;
                touching = false;
                browsing = false;
                cancelReturn();
                cancelAnimation();
                latest = bounds;
                latestTarget = null;
                lastRow = bounds.y;
                const visible = bounds.y >= viewport.scrollTop &&
                    bounds.y + bounds.h <= viewport.scrollTop + viewport.clientHeight;
                if (wasBrowsing || !visible) move(center(bounds));
            },
            interact() { touching = true; lastRow = null; cancelReturn(); cancelAnimation(); },
            browse() { browsing = true; cancelReturn(); cancelAnimation(); },
            release,
            move,
            reset() {
                cancelReturn(); cancelAnimation();
                touching = false; browsing = false; latest = null; latestTarget = null; lastRow = null;
            }
        };
    };
    if (typeof module !== "undefined") module.exports = { createScoreFollow };
    else root.RiffLoopFollow = { createScoreFollow };
})(globalThis);

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
    new URL("../RiffLoop/Resources/GpWeb/riffloop-gp.js", import.meta.url),
    "utf8"
);

{
    const startMarker = "    const playPauseBoth = () => {";
    const endMarker = "\n\n    const trackPayload";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "playPauseBoth implementation is missing");
    assert.notEqual(end, -1, "playPauseBoth implementation boundary is missing");
    const implementation = source.slice(start, end);

    function runPlayback({ hasBacking, synthEnabled, mainPlaying = false, synthPlaying = false }) {
        const api = player(mainPlaying);
        const synthApi = player(synthPlaying);
        const execute = new Function(
            "api",
            "synthApi",
            "canUseBacking",
            "synthEnabled",
            `let startingBoth = false;\n${implementation}\nplayPauseBoth();`
        );
        execute(api, synthApi, () => hasBacking, synthEnabled);
        return { api, synthApi };
    }

    function player(isPlaying) {
        return {
            isPlaying,
            playCalls: 0,
            pauseCalls: 0,
            play() { this.playCalls += 1; },
            pause() { this.pauseCalls += 1; },
        };
    }

    {
        const { api, synthApi } = runPlayback({ hasBacking: true, synthEnabled: false });
        assert.equal(api.playCalls, 1, "muting both sources must not disable the main transport");
        assert.equal(synthApi.playCalls, 0, "muted synthesis must stay silent");
    }

    {
        const { api } = runPlayback({ hasBacking: false, synthEnabled: false });
        assert.equal(api.playCalls, 1, "a score without backing must still allow silent transport");
    }

    {
        const { api, synthApi } = runPlayback({ hasBacking: true, synthEnabled: true });
        assert.equal(api.playCalls, 1);
        assert.equal(synthApi.playCalls, 1);
    }

    {
        const { api, synthApi } = runPlayback({
            hasBacking: true,
            synthEnabled: true,
            mainPlaying: true,
        });
        assert.equal(api.pauseCalls, 1);
        assert.equal(synthApi.pauseCalls, 1);
    }
}

{
    const startMarker = "    const createPointerSelection = (deps) => {";
    const endMarker = "\n    const pointerSelection = createPointerSelection({";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "createPointerSelection implementation is missing");
    assert.notEqual(end, -1, "createPointerSelection boundary is missing");
    const implementation = source.slice(start, end);

    const bar = (index) => ({ index, startTick: index * 960, endTick: (index + 1) * 960 });

    function makeHarness(barAt) {
        const posted = [];
        const timerFns = [];
        const viewport = {
            scrolls: [],
            getBoundingClientRect: () => ({ top: 0, bottom: 600, left: 0, right: 800 }),
            scrollBy(dx, dy) { this.scrolls.push(dy); },
        };
        const element = { setPointerCapture() {} };
        const scheduleLongPress = (fn) => {
            timerFns.push(fn);
            return timerFns.length;
        };
        const cancelLongPress = () => {
            timerFns.length = 0;
        };
        const execute = new Function(
            "hitBar",
            "post",
            "viewport",
            "element",
            "scheduleLongPress",
            "cancelLongPress",
            `${implementation}\nreturn createPointerSelection({ element, viewport, hitBar, post, scheduleLongPress, cancelLongPress });`
        );
        const selection = execute(
            barAt,
            (event, payload) => posted.push(payload === undefined ? [event] : [event, payload]),
            viewport,
            element,
            scheduleLongPress,
            cancelLongPress
        );
        const event = (type, x, y) => ({
            type,
            isPrimary: true,
            pointerId: 1,
            clientX: x,
            clientY: y,
            preventDefault() {},
            stopImmediatePropagation() {},
        });
        return {
            posted,
            viewport,
            fireLongPress() {
                const fns = timerFns.splice(0);
                fns.forEach((fn) => fn());
            },
            pendingTimers() { return timerFns.length; },
            pointerDown(x, y) { selection.pointerDown(event("pointerdown", x, y)); },
            pointerMove(x, y) { selection.pointerMove(event("pointermove", x, y)); },
            pointerUp(x, y) { selection.pointerUp(event("pointerup", x, y)); },
            pointerCancel(x, y) { selection.pointerCancel(event("pointercancel", x, y)); },
        };
    }

    {
        const h = makeHarness((x, y) => bar(x < 400 ? 2 : 8));
        h.pointerDown(100, 100);
        h.pointerUp(100, 100);
        assert.deepEqual(h.posted, [["barHit", bar(2)]], "a plain tap must seek via barHit");
    }

    {
        const h = makeHarness((x, y) => bar(x < 400 ? 2 : 8));
        h.pointerDown(100, 100);
        h.pointerMove(104, 103);
        h.pointerUp(104, 103);
        assert.deepEqual(
            h.posted,
            [["barHit", bar(2)]],
            "jitter under the slop threshold must still count as a tap"
        );
    }

    {
        const h = makeHarness((x, y) => bar(y < 200 ? 2 : 5));
        h.pointerDown(100, 100);
        h.fireLongPress();
        h.pointerMove(100, 300);
        h.pointerUp(100, 300);
        assert.deepEqual(
            h.posted,
            [
                ["pointerDown", bar(2)],
                ["pointerMove", bar(5)],
                ["pointerMove", bar(5)],
                ["pointerUp"],
            ],
            "long press, drag, and release must report selection start, move, final bar, and commit"
        );
    }

    {
        const h = makeHarness((x, y) => bar(y < 200 ? 2 : 5));
        h.pointerDown(100, 100);
        h.fireLongPress();
        h.pointerMove(100, 300);
        h.pointerCancel(100, 300);
        assert.deepEqual(
            h.posted,
            [["pointerDown", bar(2)], ["pointerMove", bar(5)], ["pointerCancel"]],
            "a cancelled gesture must report pointerCancel after the start"
        );
    }

    {
        const h = makeHarness((x, y) => bar(2));
        h.pointerDown(100, 100);
        h.pointerMove(220, 220);
        assert.equal(h.pendingTimers(), 0, "moving beyond the slop must cancel the long-press timer");
        h.pointerUp(220, 220);
        assert.deepEqual(h.posted, [], "a scroll drag must not post any selection or seek events");
    }

    {
        const h = makeHarness((x, y) => bar(2));
        h.pointerDown(100, 580);
        h.fireLongPress();
        h.pointerMove(100, 590);
        assert.ok(
            h.viewport.scrolls.some((dy) => dy > 0),
            "holding near the bottom edge must auto-scroll toward it"
        );
    }

    {
        const h = makeHarness((x, y) => bar(2));
        h.pointerDown(100, 100);
        h.fireLongPress();
        h.pointerUp(100, 100);
        assert.deepEqual(
            h.posted,
            [["pointerDown", bar(2)], ["pointerMove", bar(2)], ["pointerUp"]],
            "a long press released without moving must commit a single-bar range"
        );
    }
}

console.log("GP playback transport policy passed");
console.log("GP long-press drag selection pointer flow passed");

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
    new URL("../RiffLoop/Resources/GpWeb/riffloop-gp.js", import.meta.url),
    "utf8"
);

{
    assert.match(
        source,
        /const api = new alphaTab\.AlphaTabApi[\s\S]*?playerMode: alphaTab\.PlayerMode\.EnabledSynthesizer/,
        "the rendered score must use the synthesizer clock so a short backing clip cannot freeze its cursor"
    );
    assert.match(
        source,
        /const synthApi = new alphaTab\.AlphaTabApi[\s\S]*?playerMode: alphaTab\.PlayerMode\.EnabledAutomatic/,
        "the hidden player must own embedded backing-track playback"
    );
    assert.match(
        source,
        /POSITION_POST_INTERVAL_MILLISECONDS = 50[\s\S]*?now - lastPositionPostTime < POSITION_POST_INTERVAL_MILLISECONDS/,
        "native position updates must be throttled so the WKWebView bridge cannot overwhelm the iPad UI"
    );
    assert.match(
        source,
        /LONG_PRESS_MILLISECONDS = 600/,
        "range selection must require a deliberate hold long enough to avoid accidental activation while scrolling"
    );
    assert.match(
        source,
        /commitRange\(firstBar, lastBar, startTick, endTick\)[\s\S]*?applyLoopMode\(\);[\s\S]*?seekBoth\(rangeStartTick, \{ reveal: false \}\);[\s\S]*?applyRangeScrollPolicy/,
        "committing a loop must align both players to the selected A point"
    );
    assert.match(
        source,
        /api\.playerFinished\.on\(\(\) => \{[\s\S]*?api\.isLooping[\s\S]*?return;[\s\S]*?post\("playerFinished"\)/,
        "a range wrap must not be reported to native code as terminal playback completion"
    );
    assert.match(
        source,
        /api\.playerPositionChanged\.on\(\(position\) => \{[\s\S]*?if \(enforceCommittedRange\(position\)\) return;/,
        "every player position update must enforce the committed range before bridge throttling"
    );
    assert.match(
        source,
        /const seekBoth = \(tick, options = \{\}\) => \{[\s\S]*?if \(options\.reveal === false\) return;[\s\S]*?api\.scrollToCursor\(\)/,
        "ordinary seeks may reveal the cursor, but loop wraps must be able to preserve the viewport"
    );
    assert.match(
        source,
        /const stopTick = \(\) => rangeLoopingEnabled && committedRange \? committedRange\.startTick : 0;[\s\S]*?stop\(\) \{ transport\.stop\(\); seekBoth\(stopTick\(\)\); \}/,
        "stop must return to A while range looping is active and to the song start otherwise"
    );

    const loopStartMarker = "    const enforceCommittedRange = (position) => {";
    const loopEndMarker = "\n    const playPauseBoth";
    const loopStart = source.indexOf(loopStartMarker);
    const loopEnd = source.indexOf(loopEndMarker, loopStart);
    assert.notEqual(loopStart, -1, "range enforcement implementation is missing");
    assert.notEqual(loopEnd, -1, "range enforcement implementation boundary is missing");
    const loopImplementation = source.slice(loopStart, loopEnd);
    const makeRangeEnforcer = new Function(
        "seekBoth",
        "rangeLoopingEnabled",
        "committedRange",
        `${loopImplementation}\nreturn enforceCommittedRange;`
    );
    const seeks = [];
    const enforceCommittedRange = makeRangeEnforcer(
        (tick, options) => seeks.push({ tick, options }),
        true,
        { startTick: 30720, endTick: 34560 }
    );
    assert.equal(enforceCommittedRange({ currentTick: 34559, isSeek: false }), false);
    assert.equal(enforceCommittedRange({ currentTick: 34560, isSeek: false }), true);
    assert.deepEqual(
        seeks,
        [{ tick: 30720, options: { reveal: false } }],
        "crossing B must return both transports to A without jumping the viewport"
    );
    assert.equal(
        enforceCommittedRange({ currentTick: 40000, isSeek: true }),
        false,
        "the corrective seek notification must not recursively seek"
    );

    const startMarker = "    const isPlaybackReady = (state) =>";
    const endMarker = "\n    const notifyPlayerReady";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "isPlaybackReady implementation is missing");
    assert.notEqual(end, -1, "isPlaybackReady implementation boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function(`${implementation}\nreturn isPlaybackReady;`);
    const isPlaybackReady = execute();

    assert.equal(isPlaybackReady({ hasLoaded: false, hasBacking: false, mainReady: true, synthReady: true }), false);
    assert.equal(isPlaybackReady({ hasLoaded: true, hasBacking: false, mainReady: true, synthReady: false }), true);
    assert.equal(isPlaybackReady({ hasLoaded: true, hasBacking: true, mainReady: true, synthReady: false }), false);
    assert.equal(isPlaybackReady({ hasLoaded: true, hasBacking: true, mainReady: false, synthReady: true }), false);
    assert.equal(isPlaybackReady({ hasLoaded: true, hasBacking: true, mainReady: true, synthReady: true }), true);
}

{
    const startMarker = "    const loopScrollPlan = (rangeTop, rangeBottom, viewportHeight) => {";
    const endMarker = "\n    const applyRangeScrollPolicy";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "adaptive loop scrolling policy is missing");
    assert.notEqual(end, -1, "adaptive loop scrolling policy boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function(`${implementation}\nreturn loopScrollPlan;`);
    const loopScrollPlan = execute();

    assert.deepEqual(
        loopScrollPlan(400, 760, 900),
        { mode: "locked", targetTop: 130 },
        "a loop that fits on screen must be centered once and then kept stable"
    );
    assert.deepEqual(
        loopScrollPlan(100, 1300, 900),
        { mode: "offscreen", targetTop: null },
        "a loop taller than the viewport must scroll only when the cursor leaves the display"
    );
}

{
    const startMarker = "    const BACKING_DRIFT_TOLERANCE_MILLISECONDS";
    const endMarker = "\n    const createTransportController";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "backing synchronizer is missing");
    assert.notEqual(end, -1, "backing synchronizer boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function(`${implementation}\nreturn createBackingSynchronizer;`);
    const createBackingSynchronizer = execute();
    let now = 0;
    const backing = {
        timePosition: 0,
        isPlaying: true,
        pauseCalls: 0,
        playCalls: 0,
        pause() { this.pauseCalls += 1; this.isPlaying = false; },
        play() { this.playCalls += 1; this.isPlaying = true; },
    };
    const synchronizer = createBackingSynchronizer({
        synthApi: backing,
        canUseBacking: () => true,
        now: () => now,
    });

    assert.equal(synchronizer.align(9_200), true);
    assert.equal(backing.timePosition, 9_200, "enabling backing must seek it to the score time");
    now = 500;
    backing.timePosition = 10_150;
    assert.equal(synchronizer.correct(10_000, true), true);
    assert.equal(backing.timePosition, 10_000, "a noticeable backing drift must be corrected in milliseconds");
    assert.equal(backing.pauseCalls, 1);
    assert.equal(backing.playCalls, 1, "a correction during playback must resume the backing transport");
    now = 700;
    backing.timePosition = 10_300;
    assert.equal(synchronizer.correct(10_000, true), false, "drift correction must be rate limited");
}

{
    assert.match(
        source,
        /prepareMetronomeSubdivision\(factor\)[\s\S]*?metronomeSubdivisionFactor = value;[\s\S]*?setMetronomeSubdivision\(factor\)/,
        "loading a new file needs a non-reloading metronome subdivision command"
    );
    const subdivision = source.slice(
        source.indexOf("        setMetronomeSubdivision(factor)"),
        source.indexOf("        setBeatAccents(accents)")
    );
    assert.match(subdivision, /resetPlaybackReadiness\(\)/, "reloading after a subdivision change must reset player readiness");
}

{
    const startMarker = "    const createTransportController = (deps) => {";
    const endMarker = "\n    const backingSynchronizer = createBackingSynchronizer";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "coordinated transport implementation is missing");
    assert.notEqual(end, -1, "coordinated transport implementation boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function(`${implementation}\nreturn createTransportController;`);
    const createTransportController = execute();

    function player(isPlaying, tickPosition, timePosition = tickPosition) {
        return {
            isPlaying,
            tickPosition,
            timePosition,
            playCalls: 0,
            pauseCalls: 0,
            play() { this.playCalls += 1; this.isPlaying = true; },
            pause() { this.pauseCalls += 1; this.isPlaying = false; },
            stop() { this.isPlaying = false; },
        };
    }

    {
        const api = player(false, 2400);
        const synthApi = player(false, 0);
        const scheduled = [];
        const reportedStates = [];
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => true,
            schedule: (action, delay) => scheduled.push({ action, delay }),
            reportState: (playing, stopped) => reportedStates.push({ playing, stopped }),
        });
        transport.play();
        assert.deepEqual(reportedStates.at(-1), { playing: true, stopped: false });
        assert.equal(transport.isPlayingIntent(), true);
        assert.equal(api.playCalls, 1, "muting both sources must not disable the main transport");
        assert.equal(
            synthApi.playCalls,
            1,
            "a muted backing player must keep its transport aligned for seamless re-enabling"
        );
        assert.equal(
            synthApi.timePosition,
            api.timePosition,
            "backing and synthesis must start from the same score time"
        );
        transport.pause();
        assert.deepEqual(reportedStates.at(-1), { playing: false, stopped: false });
        assert.equal(transport.isPlayingIntent(), false);
        assert.equal(api.pauseCalls, 1);
        assert.equal(synthApi.pauseCalls, 1);
        assert.deepEqual(scheduled.map(({ delay }) => delay), [80, 240]);

        api.isPlaying = true;
        synthApi.isPlaying = true;
        scheduled[0].action();
        assert.equal(api.isPlaying, false, "a late main-player start must be paused again");
        assert.equal(synthApi.isPlaying, false, "a late backing-player start must be paused again");
        assert.equal(api.pauseCalls, 2);
        assert.equal(synthApi.pauseCalls, 2);
    }

    {
        const api = player(false, 2400);
        const synthApi = player(false, 0);
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => false,
            schedule: () => {},
        });
        transport.toggle();
        assert.equal(api.playCalls, 1, "a score without backing must still allow silent transport");
        assert.equal(synthApi.playCalls, 0);
    }
}

{
    const startMarker = "    const hitScorePosition = (clientX, clientY) => {";
    const endMarker = "\n    const createPointerSelection = (deps) => {";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "hitScorePosition implementation is missing");
    assert.notEqual(end, -1, "hitScorePosition boundary is missing");
    const implementation = source.slice(start, end);
    const masterBar = { index: 2 };
    const beats = [
        { id: "first", voice: { bar: { masterBar } } },
        { id: "third", voice: { bar: { masterBar } } },
    ];
    const api = {
        score: { masterBars: [{}, {}, masterBar] },
        renderer: {
            boundsLookup: {
                getBeatAtPos: (x) => (x < 200 ? beats[0] : beats[1]),
                findMasterBarByIndex: () => null,
            },
        },
        tickCache: {
            getBeatStart: (beat) => (beat.id === "first" ? 2_040 : 2_520),
        },
    };
    const scoreElement = {
        getBoundingClientRect: () => ({ left: 0, top: 0 }),
    };
    const barPayload = () => ({ index: 2, startTick: 1_920, endTick: 2_880 });
    const execute = new Function(
        "api",
        "scoreElement",
        "barPayload",
        `${implementation}\nreturn hitScorePosition;`
    );
    const hitScorePosition = execute(api, scoreElement, barPayload);

    assert.deepEqual(
        hitScorePosition(100, 100),
        { bar: barPayload(), seekTick: 2_040 },
        "a tap must preserve the first beat tick instead of reducing it to the bar start"
    );
    assert.deepEqual(
        hitScorePosition(300, 100),
        { bar: barPayload(), seekTick: 2_520 },
        "different beats in one bar must produce different seek ticks"
    );
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
    const scoreHit = (index, seekTick = index * 960) => ({ bar: bar(index), seekTick });

    function makeHarness(barAt) {
        const posted = [];
        const timerFns = [];
        const viewport = {
            scrolls: [],
            getBoundingClientRect: () => ({ top: 0, bottom: 600, left: 0, right: 800 }),
            scrollBy(dx, dy) { this.scrolls.push(dy); },
        };
        const interactionClasses = new Set();
        const element = {
            setPointerCapture() {},
            getBoundingClientRect: () => ({ top: 0, left: 0 }),
            style: { setProperty() {} },
            classList: {
                add(...names) { names.forEach((name) => interactionClasses.add(name)); },
                remove(...names) { names.forEach((name) => interactionClasses.delete(name)); },
            },
        };
        const scheduleLongPress = (fn) => {
            timerFns.push(fn);
            return timerFns.length;
        };
        const cancelLongPress = () => {
            timerFns.length = 0;
        };
        const execute = new Function(
            "hitScorePosition",
            "post",
            "viewport",
            "element",
            "scheduleLongPress",
            "cancelLongPress",
            `${implementation}\nreturn createPointerSelection({ element, viewport, hitScorePosition, post, scheduleLongPress, cancelLongPress });`
        );
        const selection = execute(
            (x, y) => {
                const hit = barAt(x, y);
                return hit && "bar" in hit ? hit : (hit ? { bar: hit, seekTick: hit.startTick } : null);
            },
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
            interactionClasses,
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
        const h = makeHarness((x, y) => (
            x < 400 ? scoreHit(2, 2_160) : scoreHit(8, 8_160)
        ));
        h.pointerDown(100, 100);
        h.pointerUp(100, 100);
        assert.deepEqual(
            h.posted,
            [["barHit", { ...bar(2), seekTick: 2_160 }]],
            "a plain tap must seek via barHit at the precise beat tick"
        );
    }

    {
        const h = makeHarness((x, y) => scoreHit(x < 400 ? 2 : 8));
        h.pointerDown(100, 100);
        h.pointerMove(104, 103);
        h.pointerUp(104, 103);
        assert.deepEqual(
            h.posted,
            [["barHit", { ...bar(2), seekTick: bar(2).startTick }]],
            "jitter under the slop threshold must still count as a tap"
        );
    }

    {
        const h = makeHarness((x, y) => bar(y < 200 ? 2 : 5));
        h.pointerDown(100, 100);
        assert.equal(h.interactionClasses.has("range-press-pending"), true);
        h.fireLongPress();
        assert.equal(h.interactionClasses.has("range-selecting"), true);
        h.pointerMove(100, 300);
        h.pointerUp(100, 300);
        assert.equal(h.interactionClasses.size, 0);
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
        h.pointerMove(109, 100);
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

    {
        const h = makeHarness((x, y) => bar(2));
        h.pointerDown(100, 100);
        h.pointerCancel(100, 100);
        assert.equal(h.pendingTimers(), 0, "cancelling before the long press must clear its timer");
        assert.deepEqual(h.posted, [], "a cancelled pending tap must not seek or select");
    }

    {
        const h = makeHarness((x, y) => (y >= 600 ? null : bar(2)));
        h.pointerDown(100, 100);
        h.fireLongPress();
        h.pointerMove(100, 900);
        h.pointerUp(100, 900);
        assert.deepEqual(
            h.posted,
            [["pointerDown", bar(2)], ["pointerMove", bar(2)], ["pointerUp"]],
            "dragging outside the score must keep the last hit bar and still commit"
        );
    }

    {
        const h = makeHarness((x, y) => bar(x < 400 ? 2 : 8));
        h.pointerDown(350, 100);
        h.pointerMove(352, 101);
        h.pointerUp(420, 100);
        assert.deepEqual(
            h.posted,
            [["barHit", { ...bar(8), seekTick: bar(8).startTick }]],
            "a tap that slides under the slop must seek the bar at the release position"
        );
    }

    {
        const h = makeHarness((x, y) => bar(y < 200 ? 2 : 5));
        h.pointerDown(100, 100);
        h.fireLongPress();
        h.pointerMove(100, 300);
        h.pointerMove(100, 150);
        h.pointerUp(100, 150);
        assert.deepEqual(
            h.posted,
            [
                ["pointerDown", bar(2)],
                ["pointerMove", bar(5)],
                ["pointerMove", bar(2)],
                ["pointerMove", bar(2)],
                ["pointerUp"],
            ],
            "dragging back over the start bar must shrink the selection to a single bar"
        );
    }
}

console.log("GP playback transport policy passed");
console.log("GP long-press drag selection pointer flow passed");

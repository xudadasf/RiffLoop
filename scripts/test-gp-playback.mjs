import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
    new URL("../RiffLoop/Resources/GpWeb/riffloop-gp.js", import.meta.url),
    "utf8"
);

assert.doesNotMatch(
    source,
    /\.isPlaying\b/,
    "alphaTab 1.8.4 exposes playerState, not an isPlaying property"
);

{
    const startMarker = "    const reinforceLongLegatoTargets = (midiFile, score) => {";
    const endMarker = "\n    const configureMetronomeEvents";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "long legato target reinforcement is missing");
    assert.notEqual(end, -1, "long legato target reinforcement boundary is missing");
    const implementation = source.slice(start, end);

    class NoteBendEvent {
        constructor(track, tick, channel, noteKey, value) {
            Object.assign(this, { kind: "bend", track, tick, channel, noteKey, value });
        }
    }
    class NoteOnEvent {
        constructor(track, tick, channel, noteKey, noteVelocity) {
            Object.assign(this, { kind: "on", track, tick, channel, noteKey, noteVelocity });
        }
    }
    class NoteOffEvent {
        constructor(track, tick, channel, noteKey, noteVelocity) {
            Object.assign(this, { kind: "off", track, tick, channel, noteKey, noteVelocity });
        }
    }
    const alphaTab = {
        model: { SlideOutType: { Legato: 2 } },
        midi: { NoteBendEvent, NoteOnEvent, NoteOffEvent },
    };
    const reinforceLongLegatoTargets = new Function(
        "alphaTab",
        `${implementation}\nreturn reinforceLongLegatoTargets;`
    )(alphaTab);
    const firstOrigin = { slideOutType: 2, slideOrigin: null };
    const secondOrigin = { slideOutType: 2, slideOrigin: firstOrigin };
    const singleOrigin = { slideOutType: 2, slideOrigin: null };
    const targetBeat = { absolutePlaybackStart: 36_480, playbackDuration: 1_440 };
    const singleBeat = { absolutePlaybackStart: 50_000, playbackDuration: 480 };
    const score = {
        tracks: [{
            index: 0,
            playbackInfo: { primaryChannel: 0 },
            staves: [{ bars: [{ voices: [{ beats: [
                { ...targetBeat, notes: [{
                    beat: targetBeat,
                    realValue: 58,
                    dynamics: 4,
                    slideOrigin: secondOrigin,
                }] },
                { ...singleBeat, notes: [{
                    beat: singleBeat,
                    realValue: 62,
                    dynamics: 4,
                    slideOrigin: singleOrigin,
                }] },
            ] }] }] }],
        }],
    };
    const events = [];
    const midiFile = { tickShift: 0, addEvent(event) { events.push(event); } };

    assert.equal(reinforceLongLegatoTargets(midiFile, score), 1);
    assert.deepEqual(events.map((event) => ({ ...event })), [
        { kind: "bend", track: 0, tick: 36_480, channel: 0, noteKey: 58, value: 0x80000000 },
        { kind: "on", track: 0, tick: 36_480, channel: 0, noteKey: 58, noteVelocity: 55 },
        { kind: "off", track: 0, tick: 37_919, channel: 0, noteKey: 58, noteVelocity: 55 },
    ]);
}

assert.match(
    source,
    /setPlaybackSpeed\(speed\) \{ api\.playbackSpeed = Number\(speed\); synthApi\.playbackSpeed = Number\(speed\); \}/,
    "score synth and embedded backing must always use the same playback speed"
);
assert.doesNotMatch(
    source,
    /midiEventsPlayed[\s\S]*?pdfClickMetronome\.play/,
    "the audible metronome must share alphaTab's buffered playback clock at every speed"
);

{
    const startMarker = "    const metronomeAccent = (pulse) => {";
    const endMarker = "\n    const reinforceLongLegatoTargets";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "GP metronome accent implementation is missing");
    assert.notEqual(end, -1, "GP metronome accent boundary is missing");
    const implementation = source.slice(start, end);

    class TimeSignatureEvent {
        constructor(tick, numerator, denominatorIndex) {
            Object.assign(this, { tick, numerator, denominatorIndex });
        }
    }
    class ControlChangeEvent {
        constructor(track, tick, channel, controller, value) {
            Object.assign(this, { track, tick, channel, controller, value });
        }
    }
    class PitchBendEvent {
        constructor(track, tick, channel, value) {
            Object.assign(this, { track, tick, channel, value });
        }
    }
    class NoteOnEvent {
        constructor(tick, channel) {
            Object.assign(this, { tick, channel });
        }
    }
    class ProgramChangeEvent {}
    const alphaTab = {
        midi: {
            TimeSignatureEvent,
            ControlChangeEvent,
            PitchBendEvent,
            NoteOnEvent,
            ProgramChangeEvent,
            ControllerType: {
                DataEntryCoarse: 6,
                VolumeCoarse: 7,
                RegisteredParameterFine: 100,
                RegisteredParameterCourse: 101,
            },
        },
    };
    const execute = new Function(
        "alphaTab",
        "metronomeSubdivisionFactor",
        "beatAccents",
        `${implementation}\nreturn { addMetronomeAccentControls, metronomeControlValue, metronomePitchWheel };`
    );
    const { addMetronomeAccentControls, metronomeControlValue, metronomePitchWheel } = execute(
        alphaTab,
        1,
        ["strong", "normal", "subAccent", "muted"]
    );
    const midiFile = {
        division: 960,
        tickShift: 0,
        events: [
            new TimeSignatureEvent(0, 4, 2),
            new NoteOnEvent(0, 1),
            { tick: 3_840 },
        ],
        addEvent(event) { this.events.push(event); },
    };

    assert.equal(addMetronomeAccentControls(midiFile), 4);
    const controls = midiFile.events.filter((event) => (
        event instanceof ControlChangeEvent && event.controller === 7
    ));
    assert.deepEqual(
        controls.map(({ tick, channel, controller, value }) => ({ tick, channel, controller, value })),
        [
            { tick: 0, channel: 2, controller: 7, value: metronomeControlValue(0) },
            { tick: 960, channel: 2, controller: 7, value: metronomeControlValue(1) },
            { tick: 1_920, channel: 2, controller: 7, value: metronomeControlValue(2) },
            { tick: 2_880, channel: 2, controller: 7, value: metronomeControlValue(3) },
        ],
        "all four opening beats must be scheduled in the synth buffer before playback"
    );
    assert.equal(controls[0].value > controls[2].value, true);
    assert.equal(controls[2].value > controls[1].value, true);
    assert.equal(controls[3].value, 0);
    assert.deepEqual(
        midiFile.events
            .filter((event) => event instanceof ControlChangeEvent && event.controller !== 7)
            .map(({ tick, channel, controller, value }) => ({ tick, channel, controller, value })),
        [
            { tick: 0, channel: 2, controller: 101, value: 0 },
            { tick: 0, channel: 2, controller: 100, value: 0 },
            { tick: 0, channel: 2, controller: 6, value: 12 },
        ],
        "the dedicated GP metronome channel must use a wide pitch range"
    );
    const pitchBends = midiFile.events.filter((event) => event instanceof PitchBendEvent);
    assert.deepEqual(
        pitchBends.map(({ tick, channel, value }) => ({ tick, channel, value })),
        [
            { tick: 0, channel: 2, value: metronomePitchWheel(0) },
            { tick: 960, channel: 2, value: metronomePitchWheel(1) },
            { tick: 1_920, channel: 2, value: metronomePitchWheel(2) },
            { tick: 2_880, channel: 2, value: metronomePitchWheel(3) },
        ],
        "GP downbeat, ordinary beat and secondary accent need distinct buffered timbres"
    );
    assert.equal(new Set(pitchBends.map((event) => event.value)).size, 4);

    const pickupMidiFile = {
        division: 960,
        tickShift: 480,
        events: [
            new TimeSignatureEvent(0, 4, 2),
            new NoteOnEvent(480, 0),
            { tick: 2_400 },
        ],
        addEvent(event) { this.events.push(event); },
    };
    assert.equal(addMetronomeAccentControls(pickupMidiFile), 2);
    assert.deepEqual(
        pickupMidiFile.events
            .filter((event) => event instanceof ControlChangeEvent && event.controller === 7)
            .map(({ tick, channel }) => ({ tick, channel })),
        [
            { tick: 480, channel: 1 },
            { tick: 1_440, channel: 1 },
        ],
        "opening metronome controls must follow alphaTab's pickup tick shift and channel"
    );

    const fullSongMidiFile = {
        division: 960,
        tickShift: 0,
        events: [
            new TimeSignatureEvent(0, 8, 3),
            new NoteOnEvent(0, 0),
            { tick: 38 * 3_840 },
        ],
        addEvent(event) { this.events.push(event); },
    };
    assert.equal(addMetronomeAccentControls(fullSongMidiFile), 38 * 8);
    const fullSongControls = fullSongMidiFile.events
        .filter((event) => event instanceof ControlChangeEvent && event.controller === 7);
    assert.equal(
        fullSongControls.at(-1)?.tick,
        38 * 3_840 - 480,
        "metronome accents must remain scheduled through the final subdivision of a long score"
    );
}

{
    const startMarker = "    const backingAudioMimeType = (bytes) => {";
    const endMarker = "\n    const probeTypedBackingMetadata";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "iPad backing MIME compatibility layer is missing");
    assert.notEqual(end, -1, "iPad backing MIME compatibility boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function(
        "alphaTab",
        `${implementation}\nreturn { backingAudioMimeType, nativeBackingPayload };`
    );
    const alphaTab = {
        midi: {
            MidiFileGenerator: {
                generateSyncPoints: () => [
                    { synthTime: 0, syncTime: -2798.639455782313 },
                    { synthTime: 140307, syncTime: 137508.3605442177 },
                ],
            },
        },
    };
    const { backingAudioMimeType, nativeBackingPayload } = execute(alphaTab);

    const mp3 = new Uint8Array([0x49, 0x44, 0x33, 0x04]);
    assert.equal(backingAudioMimeType(mp3), "audio/mpeg");
    assert.equal(backingAudioMimeType(new Uint8Array([0x52, 0x49, 0x46, 0x46])), "audio/wav");
    assert.deepEqual(
        nativeBackingPayload({ backingTrack: { rawAudioFile: mp3 } }),
        {
            mimeType: "audio/mpeg",
            data: "SUQzBA==",
            syncPoints: [
                { synthTime: 0, syncTime: -2798.639455782313 },
                { synthTime: 140307, syncTime: 137508.3605442177 },
            ],
        },
        "WKWebView must hand audio bytes and the GP timeline mapping to the native player"
    );
}

{
    const startMarker = "    const createSynthOutputController = (playerApi) => {";
    const endMarker = "\n    const synthOutput = createSynthOutputController(api);";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "independent GP synth output controller is missing");
    assert.notEqual(end, -1, "independent GP synth output controller boundary is missing");
    const implementation = source.slice(start, end);
    const createSynthOutputController = new Function(
        `${implementation}\nreturn createSynthOutputController;`
    )();
    const calls = [];
    const api = {
        masterVolume: 0,
        changeTrackVolume(tracks, volume) { calls.push(["volume", tracks[0].index, volume]); },
        changeTrackMute(tracks, muted) { calls.push(["mute", tracks[0].index, muted]); },
    };
    const tracks = [
        { index: 0, playbackInfo: { volume: 16, isMute: false } },
        { index: 1, playbackInfo: { volume: 8, isMute: true } },
    ];
    const output = createSynthOutputController(api);

    output.reset(tracks);
    assert.equal(api.masterVolume, 1, "the alphaTab master must stay audible for the independent metronome");
    assert.deepEqual(calls.slice(-4), [
        ["volume", 0, 0.75],
        ["mute", 0, false],
        ["volume", 1, 0.375],
        ["mute", 1, true],
    ]);

    output.setEnabled(false);
    assert.equal(api.masterVolume, 1);
    assert.deepEqual(calls.slice(-2), [["mute", 0, true], ["mute", 1, true]]);

    output.setMasterVolume(0.4);
    output.setEnabled(true);
    assert.deepEqual(calls.slice(-4), [
        ["volume", 0, 0.4],
        ["volume", 1, 0.2],
        ["mute", 0, false],
        ["mute", 1, true],
    ]);

    output.setTrackVolume(1, 0.9);
    output.setTrackMute(0, true);
    assert.deepEqual(calls.slice(-4), [
        ["volume", 1, 0.9 * 0.4],
        ["mute", 1, true],
        ["volume", 0, 0.4],
        ["mute", 0, true],
    ]);
}

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
        /api\.playerFinished\.on\(\(\) => \{[\s\S]*?rangeLoopingEnabled[\s\S]*?completeCommittedRangeLoop\(\)/,
        "alphaTab native playback-range finishes must feed the explicit loop completion state machine"
    );
    assert.match(
        source,
        /let loopCountInEnabled = false;[\s\S]*?api\.isLooping = Boolean\(\(useRange && !loopCountInEnabled\) \|\| wholeSongLoopingEnabled\)/,
        "per-loop count-in must disable alphaTab native range wrapping so only one owner can restart at A"
    );
    assert.match(
        source,
        /setLoopCountInEnabled\(enabled\) \{[\s\S]*?loopCountInEnabled = Boolean\(enabled\);[\s\S]*?applyLoopMode\(\)/,
        "changing per-loop count-in must immediately switch range-loop ownership"
    );
    assert.match(
        source,
        /if \(!completeCommittedRangeLoop\(\)\) return false;[\s\S]*?if \(!loopCountInEnabled\)[\s\S]*?seekBoth\(committedRange\.startTick/,
        "a count-in range boundary must wait for the acknowledged restart instead of seeking while alphaTab is finishing"
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
        /const stopTick = \(\) => rangeLoopingEnabled && committedRange \? committedRange\.startTick : 0;[\s\S]*?stop\(\) \{[\s\S]*?transport\.stop\(\); seekBoth\(stopTick\(\)\); \}/,
        "stop must return to A while range looping is active and to the song start otherwise"
    );

    const loopStartMarker = "    let rangeCompletionAwaitingReset = false;";
    const loopEndMarker = "\n    const createRangeCountInRestarter";
    const loopStart = source.indexOf(loopStartMarker);
    const loopEnd = source.indexOf(loopEndMarker, loopStart);
    assert.notEqual(loopStart, -1, "range enforcement implementation is missing");
    assert.notEqual(loopEnd, -1, "range enforcement implementation boundary is missing");
    const loopImplementation = source.slice(loopStart, loopEnd);
    const makeRangeEnforcer = new Function(
        "seekBoth",
        "post",
        "rangeLoopingEnabled",
        "committedRange",
        "loopCountInEnabled",
        `${loopImplementation}\nreturn { enforceCommittedRange, completeCommittedRangeLoop };`
    );
    const seeks = [];
    const posts = [];
    const { enforceCommittedRange, completeCommittedRangeLoop } = makeRangeEnforcer(
        (tick, options) => seeks.push({ tick, options }),
        (event) => posts.push(event),
        true,
        { startTick: 30720, endTick: 34560 },
        false
    );
    assert.equal(enforceCommittedRange({ currentTick: 34559, isSeek: false }), false);
    assert.equal(enforceCommittedRange({ currentTick: 34560, isSeek: false }), true);
    assert.deepEqual(
        seeks,
        [{ tick: 30720, options: { reveal: false } }],
        "crossing B must return both transports to A without jumping the viewport"
    );
    assert.deepEqual(
        posts,
        ["rangeLoopCompleted"],
        "crossing B must explicitly report one completed range loop before the corrective seek"
    );
    assert.equal(
        enforceCommittedRange({ currentTick: 40000, isSeek: true }),
        false,
        "the corrective seek notification must not recursively seek"
    );
    assert.deepEqual(
        posts,
        ["rangeLoopCompleted"],
        "the corrective seek notification must not count the same loop twice"
    );

    assert.equal(
        enforceCommittedRange({ currentTick: 34580, isSeek: false }),
        false,
        "queued worker positions beyond B must be ignored until the loop has returned to A"
    );
    assert.deepEqual(
        posts,
        ["rangeLoopCompleted"],
        "multiple queued boundary positions from one physical loop must report one completion"
    );

    assert.equal(enforceCommittedRange({ currentTick: 30720, isSeek: true }), false);
    assert.equal(
        completeCommittedRangeLoop(),
        true,
        "alphaTab playerFinished must complete a native range loop even without an observed B position"
    );
    assert.equal(
        completeCommittedRangeLoop(),
        false,
        "a late second completion signal for the same native loop must be ignored"
    );
    assert.deepEqual(posts, ["rangeLoopCompleted", "rangeLoopCompleted"]);

    const countInBoundaryCalls = [];
    const countInRange = makeRangeEnforcer(
        (tick, options) => countInBoundaryCalls.push(["seek", tick, options]),
        (event) => countInBoundaryCalls.push(["post", event]),
        true,
        { startTick: 30720, endTick: 34560 },
        true
    );
    assert.equal(countInRange.enforceCommittedRange({ currentTick: 34563, isSeek: false }), true);
    assert.deepEqual(
        countInBoundaryCalls,
        [["post", "rangeLoopCompleted"]],
        "a count-in boundary must count once and wait for Swift to apply any ladder speed before restarting"
    );

    const countInStartMarker = "    const createRangeCountInRestarter = (deps) => {";
    const countInEndMarker = "\n    const rangeCountInRestarter";
    const countInStart = source.indexOf(countInStartMarker);
    const countInEnd = source.indexOf(countInEndMarker, countInStart);
    assert.notEqual(countInStart, -1, "per-loop count-in restart state machine is missing");
    assert.notEqual(countInEnd, -1, "per-loop count-in restart boundary is missing");
    const countInImplementation = source.slice(countInStart, countInEnd);
    const createRangeCountInRestarter = new Function(
        `${countInImplementation}\nreturn createRangeCountInRestarter;`
    )();
    const countInCalls = [];
    const scheduledRestarts = [];
    const countInRestarter = createRangeCountInRestarter({
        transport: {
            pause: () => countInCalls.push("pause"),
            play: () => countInCalls.push("play"),
        },
        seekBoth: (tick, options) => countInCalls.push(["seek", tick, options]),
        schedule: (action) => scheduledRestarts.push(action),
        isPaused: (state) => state === "paused",
    });
    countInRestarter.restart(30_720);
    assert.deepEqual(
        countInCalls,
        ["pause", ["seek", 30_720, { reveal: false }]],
        "per-loop count-in must pause and seek A without guessing when playback can resume"
    );
    assert.equal(countInRestarter.handlePlayerState("playing"), false);
    assert.equal(scheduledRestarts.length, 0, "a late Playing state must not restart count-in");
    assert.equal(countInRestarter.handlePlayerState("paused"), true);
    assert.equal(countInRestarter.handlePlayerState("paused"), false);
    assert.equal(scheduledRestarts.length, 1, "one confirmed pause must schedule one restart");
    scheduledRestarts[0]();
    assert.deepEqual(countInCalls.at(-1), "play");

    const swiftViewModel = readFileSync(
        new URL("../RiffLoop/GP/GpWebViewModel.swift", import.meta.url),
        "utf8"
    );
    assert.match(
        swiftViewModel,
        /func setLoopCountInEnabled\(_ enabled: Bool\)[\s\S]*?call\("setLoopCountInEnabled", arguments: \[enabled\]\)/,
        "Swift must send loop ownership to the local JS player"
    );
    assert.match(
        swiftViewModel,
        /private func recordLoopCompletion\(\)[\s\S]*?call\("restartRangeWithCountIn"\)/,
        "Swift must apply the completed-loop speed update before acknowledging one count-in restart"
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
        { mode: "smooth", targetTop: null },
        "a loop taller than the viewport must keep the current playback row centered with smooth following"
    );
}

{
    const startMarker = "    const createBackingAligner = (deps) => {";
    const endMarker = "\n    const createTransportController";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "backing aligner is missing");
    assert.notEqual(end, -1, "backing aligner boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function(`${implementation}\nreturn createBackingAligner;`);
    const createBackingAligner = execute();
    const backing = {
        timePosition: 0,
        pauseCalls: 0,
        playCalls: 0,
        pause() { this.pauseCalls += 1; this.isPlaying = false; },
        play() { this.playCalls += 1; this.isPlaying = true; },
    };
    const aligner = createBackingAligner({
        synthApi: backing,
        canUseBacking: () => true,
    });

    assert.equal(aligner.align(9_200), true);
    assert.equal(backing.timePosition, 9_200, "enabling backing must seek it to the score time");
    assert.equal(backing.pauseCalls, 0, "alignment itself must not inject an audible pause");
    assert.equal(backing.playCalls, 0, "alignment itself must not restart audio");
    const positionHandler = source.slice(
        source.indexOf("    api.playerPositionChanged.on"),
        source.indexOf("    api.playerStateChanged.on")
    );
    assert.doesNotMatch(
        positionHandler,
        /playerPositionChanged[\s\S]*?backingAligner\.(?:correct|align)/,
        "ordinary position updates must never hard-seek the backing while it is playing"
    );
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
    const endMarker = "\n    const backingAligner = createBackingAligner";
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, "coordinated transport implementation is missing");
    assert.notEqual(end, -1, "coordinated transport implementation boundary is missing");
    const implementation = source.slice(start, end);
    const execute = new Function("alphaTab", `${implementation}\nreturn createTransportController;`);
    const createTransportController = execute({ synth: { PlayerState: { Playing: 1 } } });

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
        synthApi.play = function () { this.playCalls += 1; };
        const scheduled = [];
        const reportedStates = [];
        const backingAudibility = [];
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => true,
            schedule: (action, delay) => scheduled.push({ action, delay }),
            reportState: (playing, stopped) => reportedStates.push({ playing, stopped }),
            setBackingAudible: (audible) => backingAudibility.push(audible),
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
        assert.deepEqual(backingAudibility, [false], "backing must prewarm silently");
        assert.equal(transport.startDeferredBacking(2_480), false);
        api.timePosition = 2_500;
        assert.equal(transport.markBackingStarted(api.timePosition), true);
        assert.equal(synthApi.timePosition, 2_500, "startup correction must use the latest score time");
        assert.deepEqual(backingAudibility, [false, true], "backing becomes audible only after both clocks are ready");
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
        let resumeCalls = 0;
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => true,
            usesNativeBacking: true,
            resumeBacking: () => { resumeCalls += 1; },
            setBackingAudible: () => {},
            schedule: () => {},
        });

        transport.play();
        assert.equal(api.playCalls, 1);
        assert.equal(synthApi.playCalls, 0, "native backing mode must not start WKWebView media");
        assert.equal(resumeCalls, 0, "native backing mode must not resume WKWebView media directly");
        assert.equal(
            transport.startDeferredBacking(2_400),
            false,
            "a stationary score position must not end count-in priming"
        );
        assert.equal(
            transport.startDeferredBacking(2_480),
            true,
            "native backing may start only after the score timeline advances"
        );
    }

    {
        const api = player(false, 2400);
        const synthApi = player(false, 2400);
        let mediaPaused = true;
        let resumeCalls = 0;
        let directPauseCalls = 0;
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => true,
            alignBacking: (scoreTime) => { synthApi.timePosition = scoreTime; },
            setBackingAudible: () => {},
            resumeBacking: () => {
                resumeCalls += 1;
                mediaPaused = false;
                return true;
            },
            pauseBacking: () => {
                directPauseCalls += 1;
                mediaPaused = true;
                return true;
            },
            schedule: () => {},
        });

        transport.play();
        assert.equal(mediaPaused, false, "the first backing start must verify the media element is running");
        transport.pause();
        assert.equal(mediaPaused, true, "pause must also stop a stale iOS media element directly");
        transport.play();
        assert.equal(
            mediaPaused,
            false,
            "resume must restart the media element when alphaTab's player state and WKWebView diverge"
        );
        assert.equal(resumeCalls, 2, "every backing start must verify the underlying media state");
        assert.equal(directPauseCalls, 1);
    }

    {
        const api = player(false, 2400);
        const synthApi = player(false, 0);
        const backingAudibility = [];
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => true,
            alignBacking: (scoreTime) => { synthApi.timePosition = scoreTime; },
            setBackingAudible: (audible) => backingAudibility.push(audible),
            schedule: () => {},
        });

        transport.play();
        assert.equal(api.playCalls, 1, "the score transport must start the count-in immediately");
        assert.equal(
            synthApi.playCalls,
            1,
            "the embedded backing transport must prewarm during count-in"
        );
        assert.deepEqual(backingAudibility, [false], "prewarmed backing must remain silent during count-in");
        assert.equal(transport.markBackingStarted(api.timePosition), false);

        assert.equal(
            transport.startDeferredBacking(api.timePosition),
            false,
            "a stationary position notification at the playback anchor is still part of the count-in"
        );
        assert.equal(
            synthApi.playCalls,
            1,
            "stationary count-in events must not restart the prewarmed backing"
        );

        assert.equal(transport.startDeferredBacking(2_480), true);
        assert.equal(synthApi.timePosition, 2_480, "backing must align to the first real score position");
        assert.equal(synthApi.playCalls, 1, "backing playback must be started exactly once");
        assert.deepEqual(backingAudibility, [false, true]);
        assert.equal(
            transport.startDeferredBacking(2_500),
            false,
            "ordinary score position updates must not restart the backing"
        );
    }

    {
        const api = player(false, 2400);
        const synthApi = player(false, 0);
        const backingAudibility = [];
        const transport = createTransportController({
            api,
            synthApi,
            canUseBacking: () => true,
            alignBacking: (scoreTime) => { synthApi.timePosition = scoreTime; },
            setBackingAudible: (audible) => backingAudibility.push(audible),
            schedule: () => {},
        });

        transport.play();
        delete synthApi.isPlaying;
        synthApi.playerState = 1;
        assert.equal(
            transport.startDeferredBacking(2_480),
            true,
            "score progress must use alphaTab playerState to finish priming when its state event is missing"
        );
        assert.deepEqual(
            backingAudibility,
            [false, true],
            "a missing backing state event must not leave embedded audio muted forever"
        );
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

    for (const speed of [0.5, 0.75, 1, 1.25, 1.5]) {
        for (const anchor of [0, 45_000, 90_000]) {
            for (const backingStartsFirst of [false, true]) {
                const api = player(false, anchor, anchor);
                const synthApi = player(false, 0, 0);
                if (!backingStartsFirst) {
                    synthApi.play = function () { this.playCalls += 1; };
                }
                api.playbackSpeed = speed;
                synthApi.playbackSpeed = speed;
                const backingAudibility = [];
                const transport = createTransportController({
                    api,
                    synthApi,
                    canUseBacking: () => true,
                    alignBacking: (scoreTime) => { synthApi.timePosition = scoreTime; },
                    setBackingAudible: (audible) => backingAudibility.push(audible),
                    schedule: () => {},
                });

                transport.play();
                assert.equal(transport.startDeferredBacking(anchor), false);
                assert.equal(transport.startDeferredBacking(anchor), false);
                const advancedTime = anchor + 120 * speed;
                if (backingStartsFirst) {
                    assert.equal(transport.markBackingStarted(anchor), false);
                    assert.equal(transport.startDeferredBacking(advancedTime), true);
                } else {
                    assert.equal(transport.startDeferredBacking(advancedTime), false);
                    api.timePosition = advancedTime + 20 * speed;
                    assert.equal(transport.markBackingStarted(api.timePosition), true);
                }
                assert.equal(synthApi.playCalls, 1);
                assert.deepEqual(backingAudibility, [false, true]);
                assert.equal(
                    synthApi.timePosition,
                    backingStartsFirst ? advancedTime : api.timePosition,
                    `backing must align once at ${speed}x from ${anchor}ms`
                );
                assert.equal(transport.startDeferredBacking(advancedTime + 500), false);
            }
        }
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
        { id: "first", playbackDuration: 240, voice: { bar: { masterBar } } },
        { id: "third", playbackDuration: 120, voice: { bar: { masterBar } } },
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
        { bar: barPayload(), seekTick: 2_040, seekEndTick: 2_280 },
        "a tap must preserve the first beat tick instead of reducing it to the bar start"
    );
    assert.deepEqual(
        hitScorePosition(300, 100),
        { bar: barPayload(), seekTick: 2_520, seekEndTick: 2_640 },
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
    const scoreHit = (index, seekTick = index * 960, seekEndTick = seekTick + 240) => ({
        bar: bar(index),
        seekTick,
        seekEndTick,
    });
    const payload = (hit) => ({ ...hit.bar, seekTick: hit.seekTick, seekEndTick: hit.seekEndTick });

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
                return hit && "bar" in hit
                    ? hit
                    : (hit ? { bar: hit, seekTick: hit.startTick, seekEndTick: hit.endTick } : null);
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
            [["barHit", payload(scoreHit(2, 2_160))]],
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
            [["barHit", payload(scoreHit(2))]],
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
                ["pointerDown", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerMove", payload(scoreHit(5, 5 * 960, 6 * 960))],
                ["pointerMove", payload(scoreHit(5, 5 * 960, 6 * 960))],
                ["pointerUp"],
            ],
            "long press, drag, and release must report selection start, move, final bar, and commit"
        );
    }

    {
        const firstBeat = scoreHit(2, 2_160, 2_400);
        const laterBeat = scoreHit(2, 2_640, 2_880);
        const h = makeHarness((x) => (x < 200 ? firstBeat : laterBeat));
        h.pointerDown(100, 100);
        h.fireLongPress();
        h.pointerMove(300, 100);
        h.pointerUp(300, 100);
        assert.deepEqual(
            h.posted,
            [
                ["pointerDown", payload(firstBeat)],
                ["pointerMove", payload(laterBeat)],
                ["pointerMove", payload(laterBeat)],
                ["pointerUp"],
            ],
            "dragging between beats in one bar must preserve note-level loop endpoints"
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
            [
                ["pointerDown", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerMove", payload(scoreHit(5, 5 * 960, 6 * 960))],
                ["pointerCancel"],
            ],
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
            [
                ["pointerDown", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerMove", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerUp"],
            ],
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
            [
                ["pointerDown", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerMove", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerUp"],
            ],
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
            [["barHit", payload(scoreHit(8, bar(8).startTick, bar(8).endTick))]],
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
                ["pointerDown", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerMove", payload(scoreHit(5, 5 * 960, 6 * 960))],
                ["pointerMove", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerMove", payload(scoreHit(2, 2 * 960, 3 * 960))],
                ["pointerUp"],
            ],
            "dragging back over the start bar must shrink the selection to a single bar"
        );
    }
}

console.log("GP playback transport policy passed");
console.log("GP long-press drag selection pointer flow passed");

import './test-gp-follow.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = name => readFileSync(new URL(`../RiffLoop/Resources/GpWeb/${name}`, import.meta.url), 'utf8');
const window = {};
new Function('window', read('riffloop-count-in.js'))(window);
const { plan, create } = window.RiffLoopCountIn;
const sequence = plan({ beats: 4, unit: 8, bpm: 120, volume: 4, accents: ['strong', 'subAccent', 'normal', 'muted'] });
assert.equal(sequence.duration, 1);
assert.deepEqual(sequence.pulses.map(p => p.time), [0, .25, .5, .75]);
assert.ok(sequence.pulses[0].gain > sequence.pulses[1].gain);
assert.ok(sequence.pulses[1].gain > sequence.pulses[2].gain);
assert.equal(sequence.pulses[3].gain, 0);
assert.equal(plan({ volume: 4 }).pulses[0].gain, plan({ volume: 2 }).pulses[0].gain * 2);

assert.equal(plan({ volume: 16 }).pulses[0].gain, plan({ volume: 1 }).pulses[0].gain * 16, 'Count-in must honor the shared 1600% maximum');
assert.equal(plan({ volume: 99 }).pulses[0].gain, plan({ volume: 16 }).pulses[0].gain);
assert.equal(plan({ volume: NaN }).pulses[0].gain, 0);

let resume, completed = 0;
const oscillators = [], gains = [];
const context = {
    currentTime: 10, destination: {},
    resume: () => new Promise(resolve => { resume = resolve; }),
    createOscillator: () => {
        const node = { frequency: {}, connect() {}, disconnect() { this.disconnected = true; },
            start(time) { this.startTime = time; }, stop(time) { this.endTime = time; } };
        oscillators.push(node); return node;
    },
    createGain: () => {
        const node = { gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} },
            connect() {}, disconnect() { this.disconnected = true; } };
        gains.push(node); return node;
    }
};
const clicks = create({ makeContext: () => context,
    settings: () => ({ volume: 1, beats: 4, bpm: 120, accents: ['strong', 'normal', 'normal', 'muted'] }),
    onError: error => { throw error; } });
assert.equal(clicks.start(() => completed++), true);
clicks.cancel(); resume(); await Promise.resolve();
assert.equal(oscillators.length, 0, 'Pause before AudioContext resume must cancel all scheduled work');
clicks.start(() => completed++); resume(); await Promise.resolve();
assert.equal(oscillators.length, 4, 'Three audible beats plus a silent completion node');
const staleCompletion = oscillators.at(-1).onended;
clicks.cancel(); staleCompletion();
assert.equal(completed, 0, 'Canceled count-in must never restart playback');
assert.ok(gains.every(g => g.disconnected), 'Cancel must disconnect gain nodes too');
clicks.start(() => completed++); resume(); await Promise.resolve();
const end = oscillators.at(-1);
assert.equal(end.endTime - end.startTime, 2);
end.onended();
assert.equal(completed, 1);
assert.equal(clicks.active, false);
let errors = 0;
assert.equal(create({ makeContext: () => { throw Error('unavailable'); }, settings: () => ({ volume: 1 }),
    onError: () => errors++ }).start(() => completed++), false);
assert.equal(errors, 1);

let timeout, stalledErrors = 0, lateResume;
const stalled = create({ makeContext: () => ({ state: 'suspended', resume: () => new Promise(resolve => { lateResume = resolve; }) }),
    settings: () => ({ volume: 1 }), onError: () => stalledErrors++,
    schedule: callback => { timeout = callback; return 1; }, unschedule() {} });
stalled.start(() => completed++);
timeout();
assert.equal(stalled.active, false, 'A suspended iPad audio clock must not leave playback pending forever');
assert.equal(stalledErrors, 1);
lateResume(); await Promise.resolve();
assert.equal(completed, 1, 'A late clock resume after timeout must not start the score');

const source = read('riffloop-gp.js');
function extract(name, next) {
    const start = source.indexOf(`    const ${name} =`);
    const end = source.indexOf(`    const ${next} =`, start);
    assert.ok(start >= 0 && end > start);
    return new Function(`${source.slice(start, end)}; return ${name};`)();
}
let output = 0;
const synth = extract('createSynthOutputController', 'synthOutput')({
    changeTrackVolume: (_, value) => { output = value; }, changeTrackMute() {}
});
synth.reset([{ index: 0 }]); synth.setMasterVolume(2);
const previousMaximum = output;
synth.setMasterVolume(4);
assert.equal(output, previousMaximum * 2, '400% must reach the actual synth track gain');
const callbacks = [], transitions = [];
let playing = false;
const restarter = extract('createRangeCountInRestarter', 'scheduleAfterCursorPaint')({
    transport: { pause() { assert.equal(transitions.at(-1), true); }, play() { playing = true; } },
    onTransition: active => transitions.push(active), seekBoth() {}, schedule: action => callbacks.push(action), isPaused: () => true
});
restarter.prepare(960); restarter.resume(); restarter.handlePlayerPosition({ currentTick: 960, isSeek: true });
assert.equal(transitions.at(-1), true, 'Logical playback remains active while waiting to jump to A');
callbacks.shift()(); assert.equal(playing, true); assert.equal(transitions.at(-1), false);
restarter.prepare(960); restarter.resume(); restarter.handlePlayerPosition({ currentTick: 960, isSeek: true });
playing = false; restarter.cancel(); callbacks.shift()(); assert.equal(playing, false);

// Exercise the shipped public setting against the actual transport and range handshake.
// The audio clock and player receipts are controlled so every transition edge is reachable.
const transportFactory = new Function('alphaTab', source.slice(
    source.indexOf('    const createTransportController ='), source.indexOf('    const backingAligner ='))
    + '; return createTransportController;')({ synth: { PlayerState: { Playing: 1 } } });
const restarterFactory = extract('createRangeCountInRestarter', 'scheduleAfterCursorPaint');
const loopCountInMethod = source.slice(source.indexOf('        setLoopCountInEnabled(enabled) {'),
    source.indexOf('        showTracks(indices) {'));
const clearRangeMethod = source.slice(source.indexOf('        clearPlaybackRange() {'),
    source.indexOf('        previewRange(firstBar, lastBar, startTick, endTick) {'));
const loopModeMethods = source.slice(source.indexOf('        setRangeLoopingEnabled(enabled) {'),
    source.indexOf('        restartRangeWithCountIn() {'));
const applyLoopModeImplementation = source.slice(source.indexOf('    const applyLoopMode ='),
    source.indexOf('    const loopScrollPlan ='));
const cancelTransitionStart = source.indexOf('    const cancelRangeTransition =');
const cancelTransitionImplementation = cancelTransitionStart < 0 ? '' : source.slice(cancelTransitionStart,
    source.indexOf('    const playPauseBoth =', cancelTransitionStart));
const makeToggleHarness = new Function('createTransport', 'createRestarter', 'createClicks', `
    let loopCountInEnabled = true, loopTransitioning = false;
    let rangeLoopingEnabled = true, wholeSongLoopingEnabled = false, rangeCompletionAwaitingReset = false;
    let committedRange = { firstBar: 0, lastBar: 0, startTick: 960, endTick: 1920 };
    let pendingRangeHighlight = committedRange;
    const window = { riffloopCommittedBars: [0, 0, 960, 1920] };
    const pointerSelection = { cancel() {} };
    const restoreScoreScrollPolicy = () => {}, applyRangeScrollPolicy = () => {};
    const reports = [], restarts = [], pauseRetries = [], nodes = [];
    const player = () => ({
        playerState: 0, timePosition: 0, tickPosition: 0, starts: 0,
        play() { this.starts++; this.playerState = 1; return true; },
        pause() { this.playerState = 0; }, stop() { this.playerState = 0; }
    });
    const api = player(), synthApi = player();
    api.clearPlaybackRangeHighlight = () => {};
    const countIn = createClicks({
        makeContext: () => ({ currentTime: 0, destination: {}, resume: () => Promise.resolve(),
            createOscillator() {
                const node = { frequency: {}, connect() {}, disconnect() {}, start() {}, stop() {} };
                nodes.push(node); return node;
            },
            createGain: () => ({ gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} },
                connect() {}, disconnect() {} })
        }),
        settings: () => ({ volume: loopCountInEnabled ? 1 : 0, bpm: 120 }),
        schedule: () => 1, unschedule() {}, onError(error) { throw error; }
    });
    const transport = createTransport({ api, synthApi, canUseBacking: () => false,
        schedule: callback => pauseRetries.push(callback),
        startCountIn: callback => countIn.start(callback), cancelCountIn: () => countIn.cancel(),
        reportState(playing, stopped) {
            reports.push({ playing, stopped, transitioning: loopTransitioning || countIn.active });
        }
    });
    const rangeCountInRestarter = createRestarter({ transport,
        onTransition: active => { loopTransitioning = active; },
        seekBoth: tick => { api.tickPosition = tick; },
        schedule: callback => restarts.push(callback), isPaused: state => state === 'paused'
    });
    ${applyLoopModeImplementation}
    ${cancelTransitionImplementation}
    const controls = { ${loopCountInMethod} ${clearRangeMethod} ${loopModeMethods} };
    applyLoopMode();
    return { api, countIn, transport, rangeCountInRestarter, controls, reports, nodes,
        mode: () => ({ rangeLoopingEnabled, wholeSongLoopingEnabled, committedRange,
            playbackRange: api.playbackRange, synthRange: synthApi.playbackRange,
            isLooping: api.isLooping, committedBars: window.riffloopCommittedBars }),
        advancePause: () => rangeCountInRestarter.handlePlayerState('paused'),
        advanceSeek: () => rangeCountInRestarter.handlePlayerPosition({ currentTick: 960, isSeek: true }),
        flushRestarts: () => restarts.splice(0).forEach(callback => callback()),
        flushPauseRetries: () => pauseRetries.splice(0).forEach(callback => callback())
    };
`);
const exitCommands = [
    ['setLoopCountInEnabled', false], ['clearPlaybackRange', undefined],
    ['setRangeLoopingEnabled', false], ['setWholeSongLoopingEnabled', true]
];
function assertLoopMode(h, command) {
    const retainsRange = command !== 'clearPlaybackRange';
    const rangeEnabled = command === 'setLoopCountInEnabled';
    const wholeEnabled = command === 'setWholeSongLoopingEnabled';
    const storedRange = { firstBar: 0, lastBar: 0, startTick: 960, endTick: 1920 };
    const playbackRange = rangeEnabled ? { startTick: 960, endTick: 1920 } : null;
    assert.deepEqual(h.mode(), { rangeLoopingEnabled: rangeEnabled, wholeSongLoopingEnabled: wholeEnabled,
        committedRange: retainsRange ? storedRange : null,
        playbackRange, synthRange: playbackRange, isLooping: rangeEnabled || wholeEnabled,
        committedBars: retainsRange ? [0, 0, 960, 1920] : null },
    `${command} must keep its intended range and whole-song semantics`);
}
for (const [command, argument] of exitCommands) {
for (const phase of ['waitingForPause', 'waitingForSeek', 'waitingForResume', 'scheduled', 'clicks']) {
    const h = makeToggleHarness(transportFactory, restarterFactory, create);
    h.transport.play(true);
    h.rangeCountInRestarter.prepare(960);
    if (phase !== 'waitingForPause') h.advancePause();
    if (['waitingForResume', 'scheduled', 'clicks'].includes(phase)) h.advanceSeek();
    if (['scheduled', 'clicks'].includes(phase)) h.rangeCountInRestarter.resume();
    if (phase === 'clicks') { h.flushRestarts(); await Promise.resolve(); }
    const lateClickCompletion = h.nodes.at(-1)?.onended;
    const startsBeforeDisable = h.api.starts;
    assert.equal(h.reports.at(-1).transitioning, true, `${phase} must first expose the real transition`);

    h.controls[command](argument);

    assert.deepEqual(h.reports.at(-1), { playing: false, stopped: false, transitioning: false },
        `${command}/${phase}: exiting a transition must publish a settled pause, so native stage time stays frozen`);
    assertLoopMode(h, command);
    assert.equal(h.transport.isPlayingIntent(), false);
    assert.equal(h.countIn.active, false);
    h.advancePause(); h.advanceSeek(); h.rangeCountInRestarter.resume();
    h.flushRestarts(); lateClickCompletion?.(); h.flushPauseRetries();
    assert.equal(h.api.starts, startsBeforeDisable, `${phase}: stale work must not resume automatically`);

    h.transport.play(command !== 'setLoopCountInEnabled');
    assert.equal(h.api.starts, startsBeforeDisable + 1, `${command}/${phase}: explicit Play must resume`);
    assert.equal(h.transport.isPlayingIntent(), true);
    h.transport.pause(true);
}
    const h = makeToggleHarness(transportFactory, restarterFactory, create);
    h.transport.play(true);
    h.controls[command](argument);
    assertLoopMode(h, command);
    assert.equal(h.transport.isPlayingIntent(), true, `${command} during score audio must keep playing`);
    assert.equal(h.api.playerState, 1);
    assert.equal(h.reports.at(-1).playing, true);
    h.controls.setLoopCountInEnabled(true);
    assert.equal(h.transport.isPlayingIntent(), true, 'Arming count-in must not interrupt the current score loop');
    h.transport.pause(true);
}
console.log('GP count-in cancellation, accented timing, 400% output, loop transition and visibility passed');

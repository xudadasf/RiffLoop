import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const source = readFileSync(new URL('../RiffLoop/Resources/GpWeb/riffloop-gp.js', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
const alphaTab = createRequire(import.meta.url)('../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const implementation = source.slice(source.indexOf('    const createTransportController ='), source.indexOf('    const backingAligner ='));
const createTransport = new Function('alphaTab', `${implementation}; return createTransportController;`)(alphaTab);

// Use the shipped synthesizer's actual rejection branch while a replacement MIDI
// is not ready. Rejected play must not leave the next tap acting as a pause.
const synth = { state: alphaTab.synth.PlayerState.Paused, qp: false };
const states = [];
let acceptedStarts = 0;
const api = {
    timePosition: 0, playerState: 0,
    play() {
        if (!synth.qp) return alphaTab.synth.AlphaSynth.prototype.play.call(synth);
        acceptedStarts++; return true;
    },
    pause() {}, stop() {}
};
const transport = createTransport({
    api, synthApi: { pause() {}, stop() {} }, canUseBacking: () => false,
    schedule: () => {}, reportState: (playing) => states.push(playing)
});
transport.toggle();
assert.equal(transport.isPlayingIntent(), false, 'Rejected play must leave the control retryable');
assert.equal(states.at(-1), false, 'Rejected play must not display Playing');
synth.qp = true;
transport.toggle();
assert.equal(acceptedStarts, 1, 'The first tap after replacement player readiness must play');
console.log('GP replacement-player rejection and retry passed');

// Device trace: pause, seek, four-second count-in, then the watchdog runs 7 ms
// after play was requested, before the worker delivers its Playing receipt.
{
    let time = 1000, check, completeCountIn, playingReceipt;
    const reports = [];
    const countIn = { active: false, cancel() { this.active = false; } };
    const api = {
        timePosition: 212000, tickPosition: 203520, playerState: 0,
        playerStateChanged: { on(fn) { playingReceipt = fn; } },
        play() { return true; }, pause() {}, stop() {}
    };
    const reportStart = source.indexOf('        reportState:', source.indexOf('    const transport ='));
    const reportEnd = source.indexOf('\n    });\n    const isPlaybackReady', reportStart);
    const report = source.slice(reportStart + '        reportState:'.length, reportEnd);
    const watchStart = source.indexOf('    api.playerStateChanged.on(state =>');
    const watchEnd = source.indexOf('    document.addEventListener("playing"', watchStart);
    assert.ok(reportStart > 0 && reportEnd > reportStart && watchEnd > watchStart);
    const controller = new Function('createTransport', 'api', 'countIn', 'performance', 'window', 'post', `
        let playbackProgressAt = 0;
        const loopTransitioning = false;
        const rangeCountInRestarter = { cancel() {} };
        const transport = createTransport({ api, synthApi: { pause() {}, stop() {} },
            canUseBacking: () => false, schedule: () => {},
            startCountIn: action => { countIn.active = true; window.complete = action; return true; },
            cancelCountIn: () => countIn.cancel(), reportState: ${report} });
        ${source.slice(watchStart, watchEnd)}
        return transport;
    `)(createTransport, api, countIn, { now: () => time }, {
        setInterval(fn) { check = fn; }, set complete(fn) { completeCountIn = fn; }
    }, (name, details) => reports.push({ name, details }));
    controller.pause(true);
    controller.play();
    time += 4025;
    check();
    assert.equal(reports.some(e => e.name === 'error'), false, 'Count-in is not a stall');
    countIn.active = false;
    completeCountIn();
    time += 7;
    check();
    assert.equal(reports.some(e => e.name === 'error'), false,
        'A fresh start must get its own grace period before the worker Playing receipt');
    time += 13;
    playingReceipt({ state: 1 });
    time += 3499;
    check();
    assert.equal(reports.some(e => e.name === 'error'), false);
    time += 1;
    check();
    assert.equal(reports.filter(e => e.name === 'error').length, 1,
        'A real lack of playback progress must still pause and report after 3.5 seconds');
    assert.equal(controller.isPlayingIntent(), false);
    console.log('GP four-second count-in/worker receipt race and real stall detection passed');
}

const readyEvents = [];
const readiness = source.slice(source.indexOf('    const isPlaybackReady ='), source.indexOf('    const applyLoopMode ='));
const readyHarness = new Function('post', `
    let scoreHasLoaded = false, didNotifyPlayerReady = false;
    let mainPlayerReadyForScore = false, backingPlayerReadyForScore = false;
    const usesNativeBacking = true, canUseBacking = () => true;
    const api = { isReadyForPlayback: true }, synthApi = { isReadyForPlayback: false };
    ${readiness}
    return {
        load() { resetPlaybackReadiness(); scoreHasLoaded = true; notifyPlayerReady(); },
        ready() { mainPlayerReadyForScore = true; notifyPlayerReady(); }
    };
`)(event => readyEvents.push(event));
readyHarness.load();
assert.equal(readyEvents.length, 0, 'A previous score\'s cached readiness must not enable the new file');
readyHarness.ready();
assert.deepEqual(readyEvents, ['playerReady'], 'Native backing must not wait for the unused WebKit backing player');
readyHarness.load();
assert.equal(readyEvents.length, 1, 'Changing files must invalidate the fresh-ready receipt');
console.log('GP per-score readiness and native-backing independence passed');

// Real AlphaSynth prebuffers count-in samples. WebAudio discards that queue on
// pause, so a manual resume must discard the synth's outstanding sample count.
{
    const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(readFileSync(new URL('../RiffLoopTests/Fixtures/transport.gp', import.meta.url)));
    const midi = new alphaTab.midi.MidiFile();
    new alphaTab.midi.MidiFileGenerator(score, new alphaTab.Settings(), new alphaTab.midi.AlphaSynthMidiFileHandler(midi)).generate();
    const event = () => ({ on(fn) { this.fn = fn; }, fire(value) { this.fn?.(value); } });
    const output = {
        sampleRate: 44100, ready: event(), sampleRequest: event(), samplesPlayed: event(),
        open() { this.ready.fire(); }, activate() {}, play() {},
        pause() { this.buffer = null; }, resetSamples() { this.buffer = null; },
        addSamples(samples) { this.buffer = samples; }
    };
    const player = new alphaTab.synth.AlphaSynth(output, 0);
    player.loadMidiFile(midi);
    player.playbackSpeed = 0.9;
    player.countInVolume = 1;
    player.playbackRange = { startTick: 7680, endTick: 11520 };
    // AlphaTabApi exposes main-score positions, not the count-in's local tick.
    let lastPosition = 7680, furthestPosition = 7680;
    player.positionChanged.on(position => {
        lastPosition = position.currentTick;
        furthestPosition = Math.max(furthestPosition, lastPosition);
    });
    const api = {
        get playerState() { return player.state; },
        get timePosition() { return player.timePosition; },
        get tickPosition() { return lastPosition; },
        set tickPosition(tick) { player.tickPosition = tick; },
        play: () => player.play(), pause: () => player.pause(), stop: () => player.stop()
    };
    const transport = createTransport({ api, synthApi: { pause() {}, stop() {} },
        canUseBacking: () => false, schedule: () => {} });
    for (let cycle = 0; cycle < 20; cycle++) {
        player.tickPosition = 7680;
        furthestPosition = 7680;
        transport.toggle();
        for (let index = 0; index < 4; index++) output.sampleRequest.fire();
        transport.toggle(); // Pause while count-in audio is buffered.
        transport.toggle();
        for (let index = 0; index < 400 && furthestPosition < 8100; index++) {
            output.sampleRequest.fire();
            if (output.buffer?.length) output.samplesPlayed.fire(output.buffer.length / 2);
        }
        assert.ok(furthestPosition >= 8100, `Count-in pause/resume cycle ${cycle} must reach the score`);
        transport.stop();
    }
    console.log('GP real-synth interrupted count-in recovery passed for 20 cycles');
}

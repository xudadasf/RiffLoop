import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const source = readFileSync(new URL('../RiffLoop/Resources/GpWeb/riffloop-gp.js', import.meta.url), 'utf8');
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

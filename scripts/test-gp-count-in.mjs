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

const source = read('riffloop-gp.js');
function extract(name, next) {
    const start = source.indexOf(`    const ${name} =`);
    const end = source.indexOf(`    const ${next} =`, start);
    assert.ok(start >= 0 && end > start);
    return new Function(`${source.slice(start, end)}; return ${name};`)();
}
const visible = extract('visibleBarScrollTop', 'revealLoopTick');
assert.equal(visible(700, 900, 0, 600), 324, 'B row bottom must fit above the controls');
assert.equal(visible(100, 250, 324, 600), 76, 'B to A must reveal the whole A row immediately');
assert.equal(visible(100, 250, 76, 600), 76, 'Fully visible rows must not jitter');
assert.equal(visible(100, 900, 500, 600), 76, 'Oversized rows align their beginning');
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
console.log('GP count-in cancellation, accented timing, 400% output, loop transition and visibility passed');

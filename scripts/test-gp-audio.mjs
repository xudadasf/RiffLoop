import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const at = createRequire(import.meta.url)('../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const read = name => readFileSync(new URL(`../RiffLoop/Resources/GpWeb/${name}`, import.meta.url), 'utf8');
const window = {};
new Function('window', read('riffloop-audio.js'))(window);
new Function('window', read('riffloop-count-in.js'))(window);
const { limit, latency, install } = window.RiffLoopAudio;
assert.equal(limit(0.2), 0.2);
assert.equal(limit(-0.5), -0.5);
assert.ok(limit(16) < 1 && limit(-16) > -1);
assert.ok(Math.abs(latency({ currentTime: 10, getOutputTimestamp: () => ({ contextTime: 9.85, performanceTime: 950 }) }, 0, 1000) - 0.1) < 1e-8);
assert.equal(latency({}, 0.12, 0), 0.12);

let time = 0, next = 0;
const timers = new Map(), delivered = [];
const node = () => ({ gain: {}, connect() {}, disconnect() {} });
const context = { state: 'running', currentTime: 0, sampleRate: 44100, destination: {},
    createGain: node, createWaveShaper: node, addEventListener() {} };
const output = { context, onSamplesPlayed: n => delivered.push(n), pause() {}, resetSamples() {}, destroy() {} };
install(output, { nativeLatency: () => 0.1, now: () => time,
    schedule: fn => { timers.set(++next, fn); return next; }, unschedule: id => timers.delete(id) });
output.onSamplesPlayed(128);
assert.deepEqual(delivered, [], 'Rendered audio is not yet heard at the device');
time = 100; [...timers.values()][0](); timers.clear();
assert.deepEqual(delivered, [128]);
output.onSamplesPlayed(256); output.pause();
assert.equal(timers.size, 0, 'Pause must invalidate outstanding cursor receipts');
output.onSamplesPlayed(128); output.resetSamples();
assert.equal(timers.size, 0, 'Seek must invalidate the previous audio position');

// Reproduce the shipped worklet's async play -> immediate pause/file switch race.
const vendor = read('alphaTab.min.js');
const classStart = vendor.indexOf('xa=class extends Ks');
const classEnd = vendor.indexOf(',Ta=class', classStart);
assert.ok(classStart >= 0 && classEnd > classStart);
let finishWorklet, connections = 0;
const worklets = { createAlphaSynthAudioWorklet: () => new Promise(resolve => { finishWorklet = resolve; }) };
const Worklet = class {
    port = { addEventListener() {}, removeEventListener() {}, start() {}, postMessage() {} };
    connect() { connections++; } disconnect() {}
};
const Output = new Function('Ks', 'Ba', 'AudioWorkletNode', 'O', `return ${vendor.slice(classStart + 3, classEnd)}`)(
    at.synth.AlphaSynthWebAudioOutputBase, worklets, Worklet, { error() {} });
const audio = new Output('test');
audio.context = { state: 'running', sampleRate: 44100, createBuffer() {},
    createBufferSource() { return { connect() {}, disconnect() {},
        start() { this.started = true; }, stop() { if (!this.started) throw Object.assign(Error(), { name: 'InvalidStateError' }); } }; } };
audio.play(); const stale = finishWorklet;
assert.doesNotThrow(() => audio.pause());
audio.play(); const fresh = finishWorklet;
stale(); await Promise.resolve();
assert.equal(connections, 0, 'Late worklet initialization cannot attach to a new source');
fresh(); await Promise.resolve();
assert.equal(connections, 1);
audio.pause();

// Disconnect during a started count-in: no error alert and no late score restart.
let stateChange, interrupted = 0, completed = 0;
const oscillators = [];
const clicks = { ...context, resume: () => Promise.resolve(),
    addEventListener: (_, fn) => { stateChange = fn; }, removeEventListener() {},
    createOscillator: () => { const n = { frequency: {}, connect() {}, disconnect() {}, start() {}, stop() {} }; oscillators.push(n); return n; },
    createGain: () => ({ ...node(), gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} } }) };
const countIn = window.RiffLoopCountIn.create({ makeContext: () => clicks, settings: () => ({ volume: 6 }),
    onError: error => { throw error; }, onInterrupted: () => interrupted++ });
countIn.start(() => completed++); await Promise.resolve();
const lateEnd = oscillators.at(-1).onended;
clicks.state = 'suspended'; stateChange(); lateEnd();
assert.equal(interrupted, 1); assert.equal(completed, 0); assert.equal(countIn.active, false);
clicks.state = 'running'; countIn.start(() => completed++); await Promise.resolve();
oscillators.at(-1).onended(); assert.equal(completed, 1, 'The next Play works without a Stop');

// Render the shipped soundfont through AlphaSynth at the old and new maxima.
const score = at.importer.ScoreLoader.loadScoreFromBytes(readFileSync(new URL('../RiffLoopTests/Fixtures/transport.gp', import.meta.url)));
const midi = new at.midi.MidiFile();
new at.midi.MidiFileGenerator(score, new at.Settings(), new at.midi.AlphaSynthMidiFileHandler(midi)).generate();
const sf = new Uint8Array(readFileSync(new URL('../RiffLoop/Resources/GpWeb/soundfont/sonivox.sf3', import.meta.url)));
const energy = volume => {
    const options = new at.synth.AudioExportOptions(); options.soundFonts = [sf];
    options.trackVolume = new Map(score.tracks.flatMap(t => [t.playbackInfo.primaryChannel, t.playbackInfo.secondaryChannel].map(c => [c, volume])));
    const renderer = at.synth.AlphaSynth.prototype.exportAudio.call(null, options, midi, [], new Map());
    const samples = renderer.render(4000).samples;
    return { raw: Math.sqrt(samples.reduce((sum, s) => sum + s * s, 0) / samples.length),
        protected: Math.sqrt(samples.reduce((sum, s) => sum + limit(s) ** 2, 0) / samples.length),
        peak: samples.reduce((peak, s) => Math.max(peak, Math.abs(limit(s))), 0) };
};
const old = energy(4), boosted = energy(16);
assert.ok(boosted.raw > old.raw * 3.9);
assert.ok(boosted.protected > old.protected * 1.3);
assert.ok(boosted.peak < 1);
console.log('GP audio: interrupted count-in, async worklet race, device latency and real 1600% synth gain passed');

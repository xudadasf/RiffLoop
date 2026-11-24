import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { create } = createRequire(import.meta.url)('../RiffLoop/Resources/GpWeb/riffloop-sync-monitor.js');

function fixture() {
    let time = 0;
    const reports = [];
    const monitor = create({ now: () => time, report: (event, payload) => reports.push({ event, payload }) });
    function step(seconds, { drift = 0, age = 0, seek = false, generation = 0,
        audioTime = seconds, state = 'running', playing = true, visible = true,
        transitioning = false, position = true, frameDelayMilliseconds = 16, layoutDelay = 0 } = {}) {
        time = seconds * 1000 - age;
        if (position) monitor.observePosition({ currentTime: time + drift, currentTick: time,
            modifiedTempo: 75, isSeek: seek });
        time = seconds * 1000 + layoutDelay;
        return monitor.sample({ audio: { time: audioTime, performanceTime: seconds * 1000,
            state, sampleRate: 44100, resetGeneration: generation }, playing, visible,
            transitioning, frameDelayMilliseconds });
    }
    return { monitor, reports, step, anomalies: () => reports.filter(r => r.event === 'reproductionSyncAnomaly') };
}

// Independent clocks may have different origins; delayed bridge delivery alone
// must not be interpreted as drift when the sampling times are aligned.
{
    const f = fixture();
    for (let second = 0; second < 20; second++) f.step(second, { audioTime: second + 417, age: second % 2 ? 49 : 0 });
    assert.equal(f.anomalies().length, 0);
    f.step(20, { drift: 180, audioTime: 437 });
    f.step(21, { audioTime: 438 });
    assert.equal(f.anomalies().length, 0, 'A transient delayed receipt must not create an incident');
    for (let second = 22; second < 28; second++) f.step(second, { drift: 400, audioTime: second + 417 });
    assert.equal(f.anomalies().length, 1);
    assert.equal(f.anomalies()[0].payload.type, 'score_audio_clock_drift');
    assert.equal(f.anomalies()[0].payload.clockDriftMilliseconds, 400);
}
{
    const f = fixture();
    f.step(0); f.step(1);
    for (let second = 2; second < 12; second++) f.step(second, { layoutDelay: 180 });
    assert.equal(f.anomalies().length, 0, 'DOM layout after the audio snapshot must not become apparent clock drift');
}
// Ordinary seek, speed changes, short loops, pre-roll and background suspension
// reset comparisons. Their history is bounded and remains in a manual sample.
{
    const f = fixture();
    f.step(0); f.step(1); f.step(2);
    f.monitor.transition('speed_requested', { speed: 1.5 });
    for (let second = 3; second < 9; second++) f.step(second, { drift: 2500, generation: 1 });
    for (let second = 9; second < 15; second++) f.step(second, { drift: -4000, seek: true });
    f.step(20, { transitioning: true });
    f.step(80, { visible: false });
    f.step(81); f.step(82); f.step(83);
    assert.equal(f.anomalies().length, 0);
    for (let i = 0; i < 50; i++) f.monitor.transition('range_loop_completed');
    const sample = f.step(84);
    assert.equal(sample.transitions.length, 8);
}
{
    const f = fixture();
    f.step(0); f.step(1); f.step(2);
    f.step(3, { position: false }); f.step(4, { position: false });
    assert.equal(f.anomalies()[0].payload.type, 'score_position_stalled');
    const paused = fixture();
    for (let second = 0; second < 8; second++) paused.step(second, { audioTime: 0, playing: false, position: false });
    assert.equal(paused.anomalies().length, 0);
}
{
    const f = fixture();
    f.step(0); f.step(1); f.step(2);
    f.step(3, { audioTime: 2 }); f.step(4, { audioTime: 2 });
    assert.ok(f.anomalies().some(a => a.payload.type === 'audio_clock_stalled'));
    const frames = fixture();
    frames.step(0); frames.step(1);
    frames.step(2, { frameDelayMilliseconds: 900 }); frames.step(3, { frameDelayMilliseconds: 950 });
    assert.ok(frames.anomalies().some(a => a.payload.type === 'cursor_frame_delayed'));
}
{
    const f = fixture();
    f.step(0); f.step(1); f.step(2);
    f.monitor.setOutputInfo({ route: 'Spark', sampleRate: 44100 });
    f.monitor.setOutputInfo({ route: 'Speaker', sampleRate: 48000 });
    f.step(3, { audioTime: 0, generation: 1 });
    f.step(4, { audioTime: 1, generation: 1 });
    f.step(5, { audioTime: 2, generation: 1 });
    assert.equal(f.anomalies().length, 0);
    assert.ok(f.reports.some(r => r.payload.reason === 'audio_output_changed'));
    assert.doesNotThrow(() => create({ report: () => { throw Error('bridge unavailable'); } }).transition('pause'));
}
console.log('GP sync capture: aligned clocks, drift, stalls, bounded transitions and pause/route isolation passed');

(() => {
    "use strict";
    // Preserve quiet samples; round only peaks near full scale, including boosts > 100%.
    const limit = value => {
        const magnitude = Math.abs(value);
        return magnitude <= 0.75 ? value
            : Math.sign(value) * (0.75 + 0.23 * Math.tanh((magnitude - 0.75) / 0.23));
    };
    const latency = (context, nativeLatency) => {
        const positive = value => Number.isFinite(value) && value > 0 ? value : 0;
        // Web Audio specifies outputLatency for this estimate: currentTime minus
        // getOutputTimestamp().contextTime fluctuates with rendering quanta.
        const device = positive(context.outputLatency);
        const reported = device > 0 ? device + positive(context.baseLatency) : positive(nativeLatency);
        return Math.min(0.5, reported);
    };
    const install = (output, { nativeLatency = () => 0, report = () => {},
        now = () => performance.now(), schedule = setTimeout, unschedule = clearTimeout } = {}) => {
        if (!output?.context || output.riffloopAudioInstalled) return;
        output.riffloopAudioInstalled = true;
        const context = output.context;
        const input = context.createGain(), shaper = context.createWaveShaper();
        input.gain.value = 1 / 32;
        const curve = new Float32Array(65537);
        for (let i = 0; i < curve.length; i++) curve[i] = limit((i / (curve.length - 1) * 2 - 1) * 32);
        shaper.curve = curve;
        input.connect(shaper); shaper.connect(context.destination);
        output.riffloopDestination = input;

        // alphaTab advances the cursor when a block is rendered, before the audio
        // device presents it. Delay that receipt, not MIDI/audio generation itself.
        let pending = [], timer, epoch = 0, lastReport = -Infinity;
        const delivered = output.onSamplesPlayed.bind(output);
        const clear = () => { epoch++; unschedule(timer); timer = undefined; pending = []; };
        const flush = () => {
            timer = undefined;
            const generation = epoch, time = now();
            let samples = 0;
            while (pending.length && pending[0].due <= time + 1) samples += pending.shift().samples;
            if (samples) delivered(samples);
            if (generation === epoch && pending.length) timer = schedule(flush, Math.max(1, pending[0].due - now()));
        };
        output.onSamplesPlayed = samples => {
            if (!(samples > 0)) return;
            const time = now(), delay = latency(context, nativeLatency());
            if (time - lastReport >= 1000) {
                lastReport = time;
                report({ state: context.state, time: context.currentTime, sampleRate: context.sampleRate,
                    latency: delay, nativeLatency: nativeLatency(), pendingBlocks: pending.length });
            }
            pending.push({ due: Math.max(time + delay * 1000, pending.at(-1)?.due || 0), samples });
            if (timer === undefined) timer = schedule(flush, delay * 1000);
        };
        for (const method of ["pause", "resetSamples", "destroy"]) {
            const original = output[method].bind(output);
            output[method] = (...args) => {
                clear();
                if (method === "destroy") { input.disconnect(); shaper.disconnect(); }
                return original(...args);
            };
        }
        context.addEventListener?.("statechange", () => report({ event: "statechange", state: context.state,
            time: context.currentTime, sampleRate: context.sampleRate }));
    };
    window.RiffLoopAudio = { limit, latency, install };
})();

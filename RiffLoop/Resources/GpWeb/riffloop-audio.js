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
        let pending = [], timer, epoch = 0, lastReport = -Infinity, playbackAllowed = true;
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
            if (!playbackAllowed || !(samples > 0)) return;
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
        // Worker commands are asynchronous. Stop the local audio node immediately
        // and reject a queued play receipt until the user requests another start.
        const play = output.play?.bind(output);
        if (play) output.play = (...args) => { if (playbackAllowed) return play(...args); };
        output.riffloopSetPlaybackAllowed = allowed => {
            playbackAllowed = Boolean(allowed);
            input.gain.value = playbackAllowed ? 1 / 32 : 0;
            if (!playbackAllowed) output.pause();
        };
        context.addEventListener?.("statechange", () => report({ event: "statechange", state: context.state,
            time: context.currentTime, sampleRate: context.sampleRate }));
    };
    function applyPedals(file, score, lookup, at) {
        for (const track of score?.tracks || []) {
            const staff = track.staves.find(s => s.bars.some(b => b.sustainPedals.length));
            if (!staff || !lookup) continue;
            const channels = new Set([track.playbackInfo.primaryChannel, track.playbackInfo.secondaryChannel]);
            const holds = [];
            let down = false;
            function change(tick, next) {
                if (down === next) return;
                down = next;
                const atTick = Math.round(tick) + file.tickShift;
                if (down) holds.push({ start: atTick, end: atTick });
                else holds[holds.length - 1].end = atTick;
                for (const channel of channels) {
                    file.addEvent(new at.midi.ControlChangeEvent(track.index, Math.round(tick) + file.tickShift, channel, 64, next ? 127 : 0));
                }
            }
            for (const occurrence of lookup.masterBars) {
                const bar = staff.bars[occurrence.masterBar.index];
                const markers = bar.sustainPedals;
                if (down && !markers.length) change(occurrence.start, false);
                for (const marker of markers) {
                    const tick = occurrence.start + marker.ratioPosition * (occurrence.end - occurrence.start);
                    change(tick, marker.pedalType !== at.model.SustainPedalMarkerType.Up);
                }
            }
            if (lookup.masterBars.length) change(lookup.masterBars.at(-1).end, false);
            // The bundled synth does not sustain guitar samples on CC64 alone.
            // Delay the actual release, stopping before a same-key re-attack.
            for (const midiTrack of file.tracks) {
                const releases = new Set(), nextAttack = new Map();
                let interval = holds.length - 1;
                for (let i = midiTrack.events.length - 1; i >= 0 && interval >= 0; i--) {
                    const event = midiTrack.events[i];
                    if (event.track !== track.index || !channels.has(event.channel)) continue;
                    const key = event.channel * 128 + event.noteKey;
                    if (event instanceof at.midi.NoteOnEvent) nextAttack.set(key, event.tick);
                    if (!(event instanceof at.midi.NoteOffEvent)) continue;
                    while (interval >= 0 && event.tick < holds[interval].start) interval--;
                    if (interval < 0 || event.tick >= holds[interval].end) continue;
                    const end = Math.min(holds[interval].end, nextAttack.get(key) ?? Infinity);
                    if (end > event.tick) { event.tick = end; releases.add(event); }
                }
                if (releases.size) midiTrack.events.sort((a,b) => a.tick-b.tick || Number(releases.has(b))-Number(releases.has(a)));
            }
        }
    }
    function installPedal(api, at) {
        api.midiLoad.on(file => applyPedals(file, api.score, api.tickCache, at));
    }
    window.RiffLoopAudio = { limit, latency, install, applyPedals, installPedal };
})();

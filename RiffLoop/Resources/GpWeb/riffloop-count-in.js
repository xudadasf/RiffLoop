(() => {
    "use strict";
    const plan = ({ beats = 4, unit = 4, bpm = 120, accents = [], volume = 1 }) => {
        const count = Math.min(32, Math.max(1, Math.round(beats)));
        const interval = 60 / Math.max(1, bpm) * 4 / Math.max(1, unit);
        return { duration: interval * count, pulses: Array.from({ length: count }, (_, beat) => {
            const accent = accents[beat] || (beat === 0 ? "strong" : "normal");
            const level = { strong: 1, subAccent: 0.62, normal: 0.34, muted: 0 }[accent] ?? 0.34;
            return { time: beat * interval, gain: level * Math.min(4, Math.max(0, volume)) * 0.2,
                frequency: { strong: 1600, subAccent: 1100, normal: 750, muted: 750 }[accent] || 750 };
        }) };
    };
    const create = ({ makeContext, settings, onError }) => {
        let context, generation = 0, active = false, nodes = [], gains = [];
        const cancel = () => {
            generation++; active = false;
            for (const node of nodes) { node.onended = null; try { node.stop(); } catch {} node.disconnect(); }
            for (const gain of gains) gain.disconnect();
            nodes = [];
            gains = [];
        };
        const start = (completion) => {
            const options = settings();
            if (!(options.volume > 0)) return false;
            cancel(); active = true;
            const request = generation;
            try {
                context ||= makeContext();
                Promise.resolve(context.resume()).then(() => {
                    if (request !== generation) return;
                    const sequence = plan(options);
                    const origin = context.currentTime + 0.025;
                    for (const pulse of sequence.pulses) {
                        if (!pulse.gain) continue;
                        const oscillator = context.createOscillator(), gain = context.createGain();
                        oscillator.frequency.value = pulse.frequency;
                        gain.gain.setValueAtTime(pulse.gain, origin + pulse.time);
                        gain.gain.exponentialRampToValueAtTime(0.0001, origin + pulse.time + 0.075);
                        oscillator.connect(gain); gain.connect(context.destination);
                        oscillator.onended = () => { oscillator.disconnect(); gain.disconnect(); };
                        oscillator.start(origin + pulse.time); oscillator.stop(origin + pulse.time + 0.08);
                        nodes.push(oscillator);
                        gains.push(gain);
                    }
                    // A silent scheduled node owns completion even when the last beat is muted.
                    const end = context.createOscillator(), silent = context.createGain();
                    silent.gain.value = 0; end.connect(silent); silent.connect(context.destination);
                    end.onended = () => {
                        end.disconnect(); silent.disconnect();
                        if (request !== generation) return;
                        active = false; nodes = []; gains = []; completion();
                    };
                    end.start(origin); end.stop(origin + sequence.duration); nodes.push(end); gains.push(silent);
                }).catch(error => { if (request === generation) { cancel(); onError(error); } });
            } catch (error) { cancel(); onError(error); }
            return active;
        };
        return { start, cancel, get active() { return active; } };
    };
    window.RiffLoopCountIn = { plan, create };
})();

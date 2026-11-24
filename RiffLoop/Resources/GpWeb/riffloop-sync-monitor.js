(() => {
    "use strict";

    // Observe transport clocks only. Detection must never seek, pause or retime audio.
    function create({ now = () => performance.now(), report = () => {} } = {}) {
        let position = null, positionAt = 0, previous = null, baseline = null;
        let active = false, settlingUntil = 0, sequence = 0;
        let outputInfo = null, lastAudio = null;
        const transitions = [], streaks = new Map(), lastIncident = new Map();
        const emit = (name, payload) => {
            try { report(name, payload); } catch { /* Diagnostics cannot interrupt playback. */ }
        };
        const reset = () => { previous = null; baseline = null; streaks.clear(); };
        function transition(reason, details = {}) {
            const time = now();
            transitions.push({ sequence: ++sequence, performanceTime: time, reason, details,
                position, audio: lastAudio });
            if (transitions.length > 8) transitions.shift();
            settlingUntil = time + 1000;
            reset();
            emit("reproductionSyncTransition", transitions.at(-1));
        }
        function observePosition(value) {
            if (!Number.isFinite(value?.currentTime) || !Number.isFinite(value?.currentTick)) return;
            if (value.isSeek) transition("position_seek", { time: value.currentTime, tick: value.currentTick });
            position = { currentTime: value.currentTime, currentTick: value.currentTick,
                modifiedTempo: value.modifiedTempo, isSeek: Boolean(value.isSeek) };
            positionAt = now();
        }
        function setOutputInfo(value) {
            const changed = outputInfo && (outputInfo.route !== value?.route
                || outputInfo.sampleRate !== value?.sampleRate);
            outputInfo = value;
            if (changed) transition("audio_output_changed", value);
            else if (["interruption", "media_services_reset", "playback_activated", "scene_inactive"].includes(value?.reason)) {
                transition("audio_" + value.reason);
            }
        }
        function check(type, condition, sample, required = 3) {
            const count = condition ? (streaks.get(type) || 0) + 1 : 0;
            streaks.set(type, count);
            if (count < required || sample.performanceTime - (lastIncident.get(type) ?? -Infinity) < 30000) return;
            lastIncident.set(type, sample.performanceTime);
            emit("reproductionSyncAnomaly", { type, consecutiveSamples: count, ...sample });
        }
        function sample({ audio, playing, transitioning = false, visible = true, visual = null,
            frameDelayMilliseconds = null } = {}) {
            const time = now();
            if (audio) lastAudio = { time: audio.time, performanceTime: audio.performanceTime,
                resetGeneration: audio.resetGeneration, receivedSamples: audio.receivedSamples,
                deliveredSamples: audio.deliveredSamples, pendingSamples: audio.pendingSamples };
            const eligible = Boolean(playing && !transitioning && visible);
            if (eligible !== active) {
                active = eligible;
                reset();
                settlingUntil = time + 1000;
            }
            const positionAge = position ? Math.max(0, time - positionAt) : null;
            const snapshot = { performanceTime: time, playing: Boolean(playing), transitioning,
                visible, position, positionAgeMilliseconds: positionAge, audio: audio || null,
                outputInfo, visual, frameDelayMilliseconds, transitions: transitions.slice() };
            if (!eligible || !audio || !Number.isFinite(audio.time) || !position) {
                reset();
                emit("reproductionSync", snapshot);
                return snapshot;
            }
            const generationChanged = previous && previous.generation !== audio.resetGeneration;
            if (generationChanged) { reset(); settlingUntil = time + 1000; }
            const gap = previous ? time - previous.time : 0;
            const audioDelta = previous ? (audio.time - previous.audioTime) * 1000 : 0;
            snapshot.audioAdvanceMilliseconds = previous ? audioDelta : null;
            snapshot.pollGapMilliseconds = previous ? gap : null;
            // Position reports are asynchronous. Compare clocks at the same instant,
            // extrapolating only a recent non-seek report from uninterrupted playback.
            const audioSampleAt = Number.isFinite(audio.performanceTime) ? audio.performanceTime : time;
            const audioPositionAge = audioSampleAt - positionAt;
            const recent = !position.isSeek && audioPositionAge >= 0 && audioPositionAge <= 250
                && audio.state === "running";
            if (recent && time >= settlingUntil) {
                const scoreTime = position.currentTime + audioPositionAge;
                if (!baseline) baseline = { scoreTime, audioTime: audio.time };
                snapshot.clockDriftMilliseconds = scoreTime - baseline.scoreTime
                    - (audio.time - baseline.audioTime) * 1000;
                check("score_audio_clock_drift", Math.abs(snapshot.clockDriftMilliseconds) > 120, snapshot);
            } else {
                streaks.delete("score_audio_clock_drift");
            }
            if (time >= settlingUntil) {
                check("audio_clock_stalled", gap >= 750 && gap <= 2500 && audioDelta < 10, snapshot, 2);
                check("score_position_stalled", positionAge > 750 && audioDelta > 250, snapshot, 2);
                check("audio_context_not_running", audio.state !== "running", snapshot, 2);
                check("cursor_frame_delayed", frameDelayMilliseconds > 750, snapshot, 2);
                // A throttled or blocked foreground page may return in one jump.
                check("foreground_scheduler_gap", gap > 2500, snapshot, 1);
            }
            previous = { time, audioTime: audio.time, generation: audio.resetGeneration };
            emit("reproductionSync", snapshot);
            return snapshot;
        }
        return { transition, observePosition, setOutputInfo, sample };
    }
    const api = { create };
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    else window.RiffLoopSyncMonitor = api;
})();

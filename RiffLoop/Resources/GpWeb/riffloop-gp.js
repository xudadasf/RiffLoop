(() => {
    "use strict";

    const scoreElement = document.getElementById("score");
    const post = (event, payload) => {
        const handler = window.webkit?.messageHandlers?.riffloop;
        if (handler) {
            handler.postMessage(payload === undefined ? { event } : { event, payload });
        }
    };
    const errorMessage = (error) => error?.message || String(error);

    const api = new alphaTab.AlphaTabApi(scoreElement, {
        core: {
            scriptFile: new URL("./alphaTab.min.js", window.location.href).href,
            fontDirectory: "./font/",
            useWorkers: true,
            enableLazyLoading: true,
            includeNoteBounds: true
        },
        display: {
            layoutMode: alphaTab.LayoutMode.Page,
            staveProfile: alphaTab.StaveProfile.ScoreTab,
            barsPerRow: 2,
            scale: 0.82
        },
        player: {
            playerMode: alphaTab.PlayerMode.EnabledAutomatic,
            soundFont: null,
            scrollElement: "#viewport",
            enableCursor: true,
            enableUserInteraction: true
        }
    });
    const synthApi = new alphaTab.AlphaTabApi(document.getElementById("synth-score"), {
        core: {
            scriptFile: new URL("./alphaTab.min.js", window.location.href).href,
            fontDirectory: "./font/",
            useWorkers: true
        },
        display: { scale: 0.1 },
        player: {
            playerMode: alphaTab.PlayerMode.EnabledSynthesizer,
            soundFont: null,
            enableCursor: false,
            enableUserInteraction: false
        }
    });
    let synthEnabled = true;
    let backingEnabled = true;
    let backingVolume = 0.75;
    let startingBoth = false;
    let soundFontBytes = null;
    let committedRange = null;
    let rangeLoopingEnabled = false;
    let wholeSongLoopingEnabled = false;
    let loadedScoreBytes = null;
    let metronomeSubdivisionFactor = 1;
    let metronomeMasterVolume = 0;
    let beatAccents = ["strong", "normal", "normal", "normal"];
    const metronomeGain = (pulse) => {
        const factor = Math.max(1, metronomeSubdivisionFactor);
        if (pulse % factor !== 0) return 0.20;
        const accent = beatAccents[Math.floor(pulse / factor)]
            || (pulse === 0 ? "strong" : "normal");
        if (accent === "strong") return 1;
        if (accent === "subAccent") return 0.62;
        if (accent === "muted") return 0;
        return 0.34;
    };
    const applyMetronomePulse = (pulse) => {
        const volume = metronomeMasterVolume * metronomeGain(pulse);
        api.metronomeVolume = volume;
        synthApi.metronomeVolume = volume;
    };
    const configureMetronomeEvents = (playerApi) => {
        playerApi.midiEventsPlayedFilter = [alphaTab.midi.MidiEventType.AlphaTabMetronome];
        playerApi.midiLoad.on((midiFile) => {
            if (metronomeSubdivisionFactor === 1) return;
            const denominatorOffset = Math.log2(metronomeSubdivisionFactor);
            for (const event of midiFile.events) {
                if (event instanceof alphaTab.midi.TimeSignatureEvent) {
                    event.numerator *= metronomeSubdivisionFactor;
                    event.denominatorIndex += denominatorOffset;
                }
            }
        });
        playerApi.midiEventsPlayed.on((event) => {
            const metronomeEvents = Array.from(event.events)
                .filter((item) => item instanceof alphaTab.midi.AlphaTabMetronomeEvent);
            const current = metronomeEvents[metronomeEvents.length - 1];
            if (!current) return;
            const pulseCount = Math.max(1, beatAccents.length * metronomeSubdivisionFactor);
            applyMetronomePulse((Number(current.metronomeNumerator) + 1) % pulseCount);
        });
    };
    configureMetronomeEvents(api);
    configureMetronomeEvents(synthApi);
    const canUseBacking = () => Boolean(api.score?.backingTrack);
    const applyLoopMode = () => {
        const useRange = rangeLoopingEnabled && committedRange;
        const range = useRange ? {
            startTick: committedRange.startTick,
            endTick: committedRange.endTick
        } : null;
        api.playbackRange = range;
        synthApi.playbackRange = range ? { ...range } : null;
        api.isLooping = Boolean(useRange || wholeSongLoopingEnabled);
        synthApi.isLooping = Boolean(useRange || wholeSongLoopingEnabled);
    };
    const playPauseBoth = () => {
        if (startingBoth) return;
        startingBoth = true;
        const shouldPlay = canUseBacking()
            ? !(api.isPlaying || synthApi.isPlaying)
            : !api.isPlaying;
        if (shouldPlay) {
            if (canUseBacking()) {
                if (backingEnabled || synthEnabled) api.play();
                if (synthEnabled) synthApi.play();
            } else if (synthEnabled) {
                api.play();
            }
        } else {
            api.pause();
            synthApi.pause();
        }
        startingBoth = false;
    };

    const trackPayload = (track) => ({
        index: track.index,
        name: track.name || `轨道 ${track.index + 1}`,
        shortName: track.shortName || "",
        volume: track.playbackInfo?.volume ?? 16,
        isMute: track.playbackInfo?.isMute ?? false,
        isSolo: track.playbackInfo?.isSolo ?? false
    });

    const barPayload = (index) => {
        if (!api.score || index < 0 || index >= api.score.masterBars.length) {
            return null;
        }

        const masterBar = api.score.masterBars[index];
        const tickLookup = api.tickCache?.getMasterBar(masterBar);
        const startTick = tickLookup?.start ?? masterBar.start;
        const endTick = tickLookup?.end ?? startTick + masterBar.calculateDuration();
        return { index, startTick, endTick };
    };

    api.error.on((error) => post("error", { message: errorMessage(error) }));
    synthApi.error.on((error) => post("error", {
        message: `合成音色加载失败：${errorMessage(error)}`
    }));
    api.scoreLoaded.on((score) => {
        if (soundFontBytes && !score.backingTrack) {
            api.loadSoundFont(soundFontBytes.slice(), false);
        }
        post("scoreLoaded", {
            title: score.title || "未命名乐谱",
            artist: score.artist || "",
            bars: score.masterBars.length,
            hasBackingTrack: Boolean(score.backingTrack),
            tracks: score.tracks.map(trackPayload),
            beatsPerMeasure: score.masterBars[0]?.timeSignatureNumerator || 4,
            beatUnit: score.masterBars[0]?.timeSignatureDenominator || 4
        });
    });
    const drawTiedTabDestinations = () => {
        let layer = document.getElementById("tie-labels");
        if (!layer) {
            layer = document.createElement("div");
            layer.id = "tie-labels";
            scoreElement.appendChild(layer);
        }
        layer.replaceChildren();
        const lookup = api.renderer?.boundsLookup;
        if (!lookup) return;
        const seen = new Set();
        for (const track of api.tracks || []) {
            for (const staff of track.staves || []) {
                if (!staff.showTablature) continue;
                for (const bar of staff.bars || []) {
                    for (const voice of bar.voices || []) {
                        for (const beat of voice.beats || []) {
                            for (const note of beat.notes || []) {
                                const origin = note.tieOrigin;
                                if (!origin || !note.isTieDestination || origin.beat?.voice?.bar !== bar || seen.has(note)) {
                                    continue;
                                }
                                seen.add(note);
                                const noteBounds = (lookup.findBeats(beat) || [])
                                    .flatMap((bounds) => bounds.notes || [])
                                    .filter((bounds) => bounds.note === note && bounds.noteHeadBounds.w <= 0.01)
                                    .sort((left, right) => right.noteHeadBounds.y - left.noteHeadBounds.y)[0];
                                if (!noteBounds) continue;
                                const label = document.createElement("span");
                                label.className = "tie-label";
                                label.textContent = `(${Math.round(origin.fret - (bar.staff?.transpositionPitch || 0))})`;
                                label.style.left = `${noteBounds.noteHeadBounds.x}px`;
                                label.style.top = `${noteBounds.noteHeadBounds.y}px`;
                                layer.appendChild(label);
                            }
                        }
                    }
                }
            }
        }
    };
    api.renderFinished.on((result) => {
        drawTiedTabDestinations();
        post("renderFinished", {
            width: Number(result.totalWidth || scoreElement.scrollWidth || 0),
            height: Number(result.totalHeight || scoreElement.scrollHeight || 0)
        });
    });
    api.playerReady.on(() => {
        if (!canUseBacking()) post("playerReady");
    });
    synthApi.playerReady.on(() => {
        if (canUseBacking()) post("playerReady");
    });
    api.playerPositionChanged.on((position) => post("positionChanged", {
        currentTime: position.currentTime,
        totalTime: position.endTime,
        currentTick: position.currentTick,
        endTick: position.endTick,
        isSeek: Boolean(position.isSeek)
    }));
    api.playerStateChanged.on((state) => post("playerStateChanged", {
        state: state.state,
        stopped: state.stopped
    }));
    api.playerFinished.on(() => post("playerFinished"));
    const firstBeatInBar = (index) => {
        for (const track of api.score?.tracks || []) {
            for (const staff of track.staves || []) {
                const bar = staff.bars?.[index];
                for (const voice of bar?.voices || []) {
                    if (voice.beats?.length) return voice.beats[0];
                }
            }
        }
        return null;
    };

    const lastBeatInBar = (index) => {
        let result = null;
        for (const track of api.score?.tracks || []) {
            for (const staff of track.staves || []) {
                const bar = staff.bars?.[index];
                for (const voice of bar?.voices || []) {
                    if (voice.beats?.length) result = voice.beats[voice.beats.length - 1];
                }
            }
        }
        return result;
    };

    const hitBar = (clientX, clientY) => {
        const lookup = api.renderer?.boundsLookup;
        if (!lookup || !api.score?.masterBars?.length) return null;
        const rect = scoreElement.getBoundingClientRect();
        const x = clientX - rect.left;
        const y = clientY - rect.top;
        const beat = lookup.getBeatAtPos(x, y);
        const beatIndex = beat?.voice?.bar?.masterBar?.index;
        if (Number.isInteger(beatIndex)) return barPayload(beatIndex);

        let nearest = null;
        let nearestDistance = Number.POSITIVE_INFINITY;
        for (let index = 0; index < api.score.masterBars.length; index += 1) {
            const bounds = lookup.findMasterBarByIndex(index)?.realBounds;
            if (!bounds) continue;
            const dx = x < bounds.x ? bounds.x - x : (x > bounds.x + bounds.w ? x - bounds.x - bounds.w : 0);
            const dy = y < bounds.y ? bounds.y - y : (y > bounds.y + bounds.h ? y - bounds.y - bounds.h : 0);
            const distance = dx * dx + dy * dy;
            if (distance < nearestDistance) {
                nearestDistance = distance;
                nearest = barPayload(index);
            }
        }
        return nearest;
    };

    let pointer = null;

    scoreElement.addEventListener("pointerdown", (event) => {
        if (!event.isPrimary) return;
        const hit = hitBar(event.clientX, event.clientY);
        if (!hit) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        scoreElement.setPointerCapture(event.pointerId);
        pointer = {
            id: event.pointerId,
            clientX: event.clientX,
            clientY: event.clientY,
            startX: event.clientX,
            startY: event.clientY,
            previousY: event.clientY,
            dragging: false
        };
    }, true);

    scoreElement.addEventListener("pointermove", (event) => {
        if (!pointer || pointer.id !== event.pointerId) return;
        const distance = Math.hypot(event.clientX - pointer.startX, event.clientY - pointer.startY);
        if (distance > 14) {
            pointer.dragging = true;
        }
        if (pointer.dragging) {
            document.getElementById("viewport").scrollBy(0, pointer.previousY - event.clientY);
        }
        pointer.previousY = event.clientY;
    }, true);

    const finishPointer = (event, cancelled) => {
        if (!pointer || pointer.id !== event.pointerId) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (!cancelled && !pointer.dragging) {
            const hit = hitBar(event.clientX, event.clientY);
            if (hit) post("barHit", hit);
        }
        pointer = null;
    };
    scoreElement.addEventListener("pointerup", (event) => finishPointer(event, false), true);
    scoreElement.addEventListener("pointercancel", (event) => finishPointer(event, true), true);

    const decodeBase64 = (base64) => {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index += 1) {
            bytes[index] = binary.charCodeAt(index);
        }
        return bytes;
    };

    window.riffloop = {
        loadSoundFont(base64) {
            try {
                soundFontBytes = decodeBase64(base64);
                synthApi.loadSoundFont(soundFontBytes.slice(), false);
                if (api.score && !canUseBacking()) {
                    api.loadSoundFont(soundFontBytes.slice(), false);
                }
            } catch (error) {
                post("error", { message: `音色加载失败：${errorMessage(error)}` });
            }
        },
        loadScore(base64) {
            try {
                window.riffloopCommittedBars = null;
                committedRange = null;
                rangeLoopingEnabled = false;
                wholeSongLoopingEnabled = false;
                loadedScoreBytes = decodeBase64(base64);
                api.load(loadedScoreBytes.slice());
                synthApi.load(loadedScoreBytes.slice());
            } catch (error) {
                post("error", { message: `乐谱加载失败：${errorMessage(error)}` });
            }
        },
        playPause() { playPauseBoth(); },
        pause() { api.pause(); synthApi.pause(); },
        stop() { api.stop(); synthApi.stop(); },
        seekTick(tick) { api.tickPosition = Number(tick); synthApi.tickPosition = Number(tick); },
        setPlaybackSpeed(speed) { api.playbackSpeed = Number(speed); synthApi.playbackSpeed = Number(speed); },
        setMasterVolume(volume) {
            const value = Number(volume);
            synthApi.masterVolume = value;
            if (!canUseBacking()) api.masterVolume = value;
        },
        setBackingVolume(volume) {
            backingVolume = Number(volume);
            if (canUseBacking()) api.masterVolume = backingEnabled ? backingVolume : 0;
        },
        setSynthEnabled(enabled) {
            synthEnabled = Boolean(enabled);
            if (!synthEnabled) {
                if (canUseBacking()) synthApi.pause();
                else api.pause();
            }
        },
        setBackingEnabled(enabled) {
            backingEnabled = Boolean(enabled);
            if (canUseBacking()) {
                api.masterVolume = backingEnabled ? backingVolume : 0;
                if (!backingEnabled && !synthEnabled) api.pause();
            }
        },
        setMetronomeVolume(volume) {
            metronomeMasterVolume = Number(volume);
            applyMetronomePulse(0);
        },
        setMetronomeSubdivision(factor) {
            const value = Number(factor);
            if (![1, 2, 4, 8].includes(value) || value === metronomeSubdivisionFactor) return;
            metronomeSubdivisionFactor = value;
            applyMetronomePulse(0);
            if (loadedScoreBytes) {
                api.pause();
                synthApi.pause();
                api.load(loadedScoreBytes.slice());
                synthApi.load(loadedScoreBytes.slice());
            }
        },
        setBeatAccents(accents) {
            beatAccents = Array.isArray(accents) && accents.length > 0
                ? accents.map(String)
                : ["strong", "normal", "normal", "normal"];
            applyMetronomePulse(0);
        },
        setCountInVolume(volume) {
            const value = Number(volume);
            synthApi.countInVolume = value;
            if (!canUseBacking()) api.countInVolume = value;
        },
        showTracks(indices) {
            if (!api.score) return;
            const tracks = indices
                .map((index) => api.score.tracks[index])
                .filter(Boolean);
            if (tracks.length > 0) api.renderTracks(tracks);
        },
        setTrackMute(index, mute) {
            const track = api.score?.tracks[index];
            if (track) api.changeTrackMute([track], Boolean(mute));
            const synthTrack = synthApi.score?.tracks[index];
            if (synthTrack) synthApi.changeTrackMute([synthTrack], Boolean(mute));
        },
        setTrackSolo(index, solo) {
            const track = api.score?.tracks[index];
            if (track) api.changeTrackSolo([track], Boolean(solo));
            const synthTrack = synthApi.score?.tracks[index];
            if (synthTrack) synthApi.changeTrackSolo([synthTrack], Boolean(solo));
        },
        setTrackVolume(index, volume) {
            const track = api.score?.tracks[index];
            if (track) api.changeTrackVolume([track], Number(volume));
            const synthTrack = synthApi.score?.tracks[index];
            if (synthTrack) synthApi.changeTrackVolume([synthTrack], Number(volume));
        },
        setPlaybackRange(startTick, endTick) {
            api.playbackRange = {
                startTick: Number(startTick),
                endTick: Number(endTick)
            };
        },
        clearPlaybackRange() {
            committedRange = null;
            rangeLoopingEnabled = false;
            window.riffloopCommittedBars = null;
            applyLoopMode();
            api.clearPlaybackRangeHighlight();
        },
        previewRange(firstBar, lastBar) {
            const startBeat = firstBeatInBar(Number(firstBar));
            const endBeat = lastBeatInBar(Number(lastBar));
            if (startBeat && endBeat) api.highlightPlaybackRange(startBeat, endBeat);
        },
        commitRange(firstBar, lastBar, startTick, endTick) {
            committedRange = {
                startTick: Number(startTick),
                endTick: Number(endTick)
            };
            rangeLoopingEnabled = true;
            wholeSongLoopingEnabled = false;
            applyLoopMode();
            window.riffloop.previewRange(firstBar, lastBar);
            window.riffloopCommittedBars = [Number(firstBar), Number(lastBar)];
        },
        setRangeLoopingEnabled(enabled) {
            rangeLoopingEnabled = Boolean(enabled) && Boolean(committedRange);
            if (rangeLoopingEnabled) wholeSongLoopingEnabled = false;
            applyLoopMode();
        },
        setWholeSongLoopingEnabled(enabled) {
            wholeSongLoopingEnabled = Boolean(enabled);
            if (wholeSongLoopingEnabled) rangeLoopingEnabled = false;
            applyLoopMode();
        },
        restartRangeWithCountIn() {
            if (!committedRange) return;
            api.pause();
            synthApi.pause();
            api.tickPosition = committedRange.startTick;
            synthApi.tickPosition = committedRange.startTick;
            setTimeout(playPauseBoth, 50);
        },
        cancelRangePreview() {
            const bars = window.riffloopCommittedBars;
            if (bars) window.riffloop.previewRange(bars[0], bars[1]);
            else api.clearPlaybackRangeHighlight();
        },
        lifecycle(active) {
            if (!active) { api.pause(); synthApi.pause(); }
        }
    };

    post("ready");
})();

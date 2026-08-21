(() => {
    "use strict";

    const scoreElement = document.getElementById("score");
    const viewportElement = document.getElementById("viewport");
    const scoreFollowOffset = (height) => -Math.round(Math.max(0, Number(height) || 0) * 0.42);
    const LONG_PRESS_MILLISECONDS = 600;
    const POSITION_POST_INTERVAL_MILLISECONDS = 50;
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
            // Keep the rendered score on the synthesizer clock. Some GP files contain a
            // very short embedded backing clip; using that clip as the visible player's
            // clock makes the cursor stop as soon as the clip ends.
            playerMode: alphaTab.PlayerMode.EnabledSynthesizer,
            soundFont: null,
            scrollElement: "#viewport",
            scrollMode: alphaTab.ScrollMode.Smooth,
            scrollOffsetY: scoreFollowOffset(viewportElement.clientHeight || window.innerHeight),
            enableCursor: true,
            enableAnimatedBeatCursor: true,
            enableElementHighlighting: true,
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
            // This hidden player is only started when the score has a backing track.
            playerMode: alphaTab.PlayerMode.EnabledAutomatic,
            soundFont: null,
            enableCursor: false,
            enableUserInteraction: false
        }
    });
    let synthEnabled = true;
    let backingEnabled = true;
    let synthVolume = 0.75;
    let backingVolume = 0.75;
    let soundFontBytes = null;
    let committedRange = null;
    let rangeLoopingEnabled = false;
    let wholeSongLoopingEnabled = false;
    let loadedScoreBytes = null;
    let metronomeSubdivisionFactor = 1;
    let metronomeMasterVolume = 0;
    let beatAccents = ["strong", "normal", "normal", "normal"];
    let scoreHasLoaded = false;
    let didNotifyPlayerReady = false;
    let pendingRangeHighlight = null;
    let lastPositionPostTime = Number.NEGATIVE_INFINITY;
    const metronomeGain = (pulse) => {
        const factor = Math.max(1, metronomeSubdivisionFactor);
        if (pulse % factor !== 0) return 0.20;
        const accent = beatAccents[Math.floor(pulse / factor)]
            || (pulse === 0 ? "strong" : "normal");
        if (accent === "strong") return 1;
        if (accent === "subAccent") return 0.45;
        if (accent === "muted") return 0;
        return 0.18;
    };
    const applyMetronomePulse = (pulse) => {
        const volume = metronomeMasterVolume * metronomeGain(pulse);
        api.metronomeVolume = volume;
        synthApi.metronomeVolume = 0;
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
    const canUseBacking = () => Boolean(api.score?.backingTrack);
    const createTransportController = (deps) => {
        const { api, synthApi, canUseBacking, schedule } = deps;
        const reportState = deps.reportState || (() => {});
        let wantsPlayback = false;
        let pauseGeneration = 0;
        const pauseNow = () => {
            api.pause();
            synthApi.pause();
        };
        const pause = () => {
            wantsPlayback = false;
            const generation = ++pauseGeneration;
            pauseNow();
            reportState(false, false);
            const pauseAgain = () => {
                if (!wantsPlayback && generation === pauseGeneration) pauseNow();
            };
            schedule(pauseAgain, 80);
            schedule(pauseAgain, 240);
        };
        const play = () => {
            wantsPlayback = true;
            pauseGeneration += 1;
            if (canUseBacking()) synthApi.tickPosition = api.tickPosition;
            api.play();
            if (canUseBacking()) synthApi.play();
            reportState(true, false);
        };
        const toggle = () => {
            if (wantsPlayback || api.isPlaying || synthApi.isPlaying) pause();
            else play();
        };
        const stop = () => {
            wantsPlayback = false;
            pauseGeneration += 1;
            api.stop();
            synthApi.stop();
            reportState(false, true);
        };
        const markStopped = () => {
            wantsPlayback = false;
            pauseGeneration += 1;
            reportState(false, true);
        };
        return { play, pause, toggle, stop, markStopped };
    };
    const transport = createTransportController({
        api,
        synthApi,
        canUseBacking,
        schedule: window.setTimeout.bind(window),
        reportState: (playing, stopped) => post("playerStateChanged", {
            state: playing ? 1 : 0,
            stopped
        })
    });
    const isPlaybackReady = (state) => state.hasLoaded
        && state.mainReady
        && (!state.hasBacking || state.synthReady);
    const resetPlaybackReadiness = () => {
        scoreHasLoaded = false;
        didNotifyPlayerReady = false;
    };
    const notifyPlayerReady = () => {
        if (didNotifyPlayerReady || !isPlaybackReady({
            hasLoaded: scoreHasLoaded,
            hasBacking: canUseBacking(),
            mainReady: Boolean(api.isReadyForPlayback),
            synthReady: Boolean(synthApi.isReadyForPlayback)
        })) return;
        didNotifyPlayerReady = true;
        post("playerReady");
    };
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
    const seekBoth = (tick) => {
        const position = Number(tick);
        api.tickPosition = position;
        synthApi.tickPosition = position;
        window.setTimeout(() => {
            if (api.isReadyForPlayback) api.scrollToCursor();
        }, 50);
    };
    const enforceCommittedRange = (position) => {
        if (
            !rangeLoopingEnabled
            || !committedRange
            || position.isSeek
            || Number(position.currentTick) < committedRange.endTick
        ) return false;
        seekBoth(committedRange.startTick);
        return true;
    };
    const playPauseBoth = () => {
        transport.toggle();
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
        message: `内嵌伴奏加载失败：${errorMessage(error)}`
    }));
    api.scoreLoaded.on((score) => {
        scoreHasLoaded = true;
        if (soundFontBytes) {
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
        notifyPlayerReady();
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
        refreshPendingRangeHighlight();
        post("renderFinished", {
            width: Number(result.totalWidth || scoreElement.scrollWidth || 0),
            height: Number(result.totalHeight || scoreElement.scrollHeight || 0)
        });
    });
    api.playerReady.on(notifyPlayerReady);
    synthApi.playerReady.on(notifyPlayerReady);
    api.playerPositionChanged.on((position) => {
        // alphaTab's native range can be lost when its internal player is rebuilt.
        // Keep the visible synth and embedded backing transport inside the committed range.
        if (enforceCommittedRange(position)) return;
        const now = performance.now();
        if (!position.isSeek && now - lastPositionPostTime < POSITION_POST_INTERVAL_MILLISECONDS) return;
        lastPositionPostTime = now;
        post("positionChanged", {
            currentTime: position.currentTime,
            totalTime: position.endTime,
            currentTick: position.currentTick,
            endTick: position.endTick,
            isSeek: Boolean(position.isSeek)
        });
    });
    api.playerStateChanged.on((state) => post("playerStateChanged", {
        state: state.state,
        stopped: state.stopped
    }));
    api.playerFinished.on(() => {
        if (api.isLooping || rangeLoopingEnabled || wholeSongLoopingEnabled) return;
        transport.markStopped();
        post("playerFinished");
    });
    const playbackRangeTrack = () => api.tracks?.[0] || api.score?.tracks?.[0];
    const playbackRangeBeats = (index) => playbackRangeTrack()
        ?.staves?.[0]
        ?.bars?.[index]
        ?.voices?.[0]
        ?.beats || [];
    const firstBeatInBar = (index) => {
        const beats = playbackRangeBeats(index);
        return beats[0] || null;
    };

    const lastBeatInBar = (index) => {
        const beats = playbackRangeBeats(index);
        return beats[beats.length - 1] || null;
    };

    const refreshPendingRangeHighlight = () => {
        if (!pendingRangeHighlight) return;
        const startBeat = firstBeatInBar(pendingRangeHighlight.firstBar);
        const endBeat = lastBeatInBar(pendingRangeHighlight.lastBar);
        if (!startBeat || !endBeat) return;
        try {
            api.highlightPlaybackRange(startBeat, endBeat);
            pendingRangeHighlight = null;
        } catch {
            // Bounds can be unavailable during the frame that replaces a rendered track.
            api.clearPlaybackRangeHighlight();
        }
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

    const createPointerSelection = (deps) => {
        const DRAG_SLOP_PIXELS = 8;
        const EDGE_SCROLL_ZONE_PIXELS = 64;
        const EDGE_SCROLL_STEP_PIXELS = 12;

        const { element, viewport, hitBar, post, scheduleLongPress, cancelLongPress } = deps;
        let pointer = null;
        let longPressTimer = null;

        const clearLongPress = () => {
            if (longPressTimer !== null) {
                cancelLongPress(longPressTimer);
                longPressTimer = null;
            }
        };
        const startSelection = () => {
            if (!pointer || pointer.mode !== "pending") return;
            longPressTimer = null;
            pointer.mode = "select";
            element.classList.remove("range-press-pending");
            element.classList.add("range-selecting");
            post("pointerDown", pointer.hit);
        };
        const clearInteractionFeedback = () => {
            element.classList.remove("range-press-pending", "range-selecting");
        };
        const scrollToward = (clientY) => {
            const rect = viewport.getBoundingClientRect();
            const topDistance = clientY - rect.top;
            const bottomDistance = rect.bottom - clientY;
            if (topDistance < EDGE_SCROLL_ZONE_PIXELS) {
                const strength = 1 - topDistance / EDGE_SCROLL_ZONE_PIXELS;
                viewport.scrollBy(0, -(EDGE_SCROLL_STEP_PIXELS * strength + 1));
            } else if (bottomDistance < EDGE_SCROLL_ZONE_PIXELS) {
                const strength = 1 - bottomDistance / EDGE_SCROLL_ZONE_PIXELS;
                viewport.scrollBy(0, EDGE_SCROLL_STEP_PIXELS * strength + 1);
            }
        };

        return {
            pointerDown(event) {
                if (!event.isPrimary) return;
                const hit = hitBar(event.clientX, event.clientY);
                if (!hit) return;
                event.preventDefault();
                event.stopImmediatePropagation();
                element.setPointerCapture(event.pointerId);
                pointer = {
                    id: event.pointerId,
                    startX: event.clientX,
                    startY: event.clientY,
                    previousY: event.clientY,
                    hit,
                    mode: "pending"
                };
                const rect = element.getBoundingClientRect();
                element.style.setProperty("--range-press-x", `${event.clientX - rect.left}px`);
                element.style.setProperty("--range-press-y", `${event.clientY - rect.top}px`);
                element.classList.add("range-press-pending");
                longPressTimer = scheduleLongPress(startSelection);
            },
            pointerMove(event) {
                if (!pointer || pointer.id !== event.pointerId) return;
                if (pointer.mode === "pending") {
                    const distance = Math.hypot(
                        event.clientX - pointer.startX,
                        event.clientY - pointer.startY
                    );
                    if (distance > DRAG_SLOP_PIXELS) {
                        clearLongPress();
                        pointer.mode = "scroll";
                        clearInteractionFeedback();
                    }
                }
                if (pointer.mode === "scroll") {
                    viewport.scrollBy(0, pointer.previousY - event.clientY);
                    pointer.previousY = event.clientY;
                    return;
                }
                if (pointer.mode === "select") {
                    event.preventDefault();
                    const hit = hitBar(event.clientX, event.clientY);
                    if (hit && hit.index !== pointer.hit.index) {
                        pointer.hit = hit;
                        post("pointerMove", hit);
                    }
                    scrollToward(event.clientY);
                }
            },
            pointerUp(event) {
                if (!pointer || pointer.id !== event.pointerId) return;
                event.preventDefault();
                event.stopImmediatePropagation();
                clearLongPress();
                const mode = pointer.mode;
                const lastHit = pointer.hit;
                pointer = null;
                clearInteractionFeedback();
                if (mode === "select") {
                    post("pointerMove", lastHit);
                    post("pointerUp");
                    return;
                }
                if (mode === "pending") {
                    const hit = hitBar(event.clientX, event.clientY) || lastHit;
                    if (hit) post("barHit", hit);
                }
            },
            pointerCancel(event) {
                if (!pointer || pointer.id !== event.pointerId) return;
                clearLongPress();
                const mode = pointer.mode;
                pointer = null;
                clearInteractionFeedback();
                if (mode === "select") post("pointerCancel");
            }
        };
    };

    const pointerSelection = createPointerSelection({
        element: scoreElement,
        viewport: document.getElementById("viewport"),
        hitBar,
        post,
        scheduleLongPress: (callback) => setTimeout(callback, LONG_PRESS_MILLISECONDS),
        cancelLongPress: clearTimeout
    });

    scoreElement.addEventListener("pointerdown", (event) => pointerSelection.pointerDown(event), true);
    scoreElement.addEventListener("pointermove", (event) => pointerSelection.pointerMove(event), true);
    scoreElement.addEventListener("pointerup", (event) => pointerSelection.pointerUp(event), true);
    scoreElement.addEventListener("pointercancel", (event) => pointerSelection.pointerCancel(event), true);

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
                if (api.score) {
                    api.loadSoundFont(soundFontBytes.slice(), false);
                }
            } catch (error) {
                post("error", { message: `音色加载失败：${errorMessage(error)}` });
            }
        },
        loadScore(base64) {
            try {
                transport.pause();
                resetPlaybackReadiness();
                window.riffloopCommittedBars = null;
                pendingRangeHighlight = null;
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
        pause() { transport.pause(); },
        stop() { transport.stop(); seekBoth(0); },
        seekTick(tick) { seekBoth(tick); },
        setPlaybackSpeed(speed) { api.playbackSpeed = Number(speed); synthApi.playbackSpeed = Number(speed); },
        setMasterVolume(volume) {
            const value = Number(volume);
            synthVolume = value;
            api.masterVolume = synthEnabled ? synthVolume : 0;
        },
        setBackingVolume(volume) {
            backingVolume = Number(volume);
            if (canUseBacking()) synthApi.masterVolume = backingEnabled ? backingVolume : 0;
        },
        setSynthEnabled(enabled) {
            synthEnabled = Boolean(enabled);
            api.masterVolume = synthEnabled ? synthVolume : 0;
        },
        setBackingEnabled(enabled) {
            backingEnabled = Boolean(enabled);
            if (canUseBacking()) {
                synthApi.masterVolume = backingEnabled ? backingVolume : 0;
            }
        },
        setMetronomeVolume(volume) {
            metronomeMasterVolume = Number(volume);
            applyMetronomePulse(0);
        },
        prepareMetronomeSubdivision(factor) {
            const value = Number(factor);
            if ([1, 2, 4, 8].includes(value)) metronomeSubdivisionFactor = value;
        },
        setMetronomeSubdivision(factor) {
            const value = Number(factor);
            if (![1, 2, 4, 8].includes(value) || value === metronomeSubdivisionFactor) return;
            metronomeSubdivisionFactor = value;
            applyMetronomePulse(0);
            if (loadedScoreBytes) {
                transport.pause();
                resetPlaybackReadiness();
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
            api.countInVolume = value;
            synthApi.countInVolume = 0;
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
            pendingRangeHighlight = null;
            committedRange = null;
            rangeLoopingEnabled = false;
            window.riffloopCommittedBars = null;
            applyLoopMode();
            api.clearPlaybackRangeHighlight();
        },
        previewRange(firstBar, lastBar) {
            pendingRangeHighlight = {
                firstBar: Number(firstBar),
                lastBar: Number(lastBar)
            };
            refreshPendingRangeHighlight();
        },
        commitRange(firstBar, lastBar, startTick, endTick) {
            const rangeStartTick = Number(startTick);
            committedRange = {
                startTick: rangeStartTick,
                endTick: Number(endTick)
            };
            rangeLoopingEnabled = true;
            wholeSongLoopingEnabled = false;
            applyLoopMode();
            seekBoth(rangeStartTick);
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
            transport.pause();
            api.tickPosition = committedRange.startTick;
            synthApi.tickPosition = committedRange.startTick;
            setTimeout(transport.play, 50);
        },
        cancelRangePreview() {
            const bars = window.riffloopCommittedBars;
            if (bars) window.riffloop.previewRange(bars[0], bars[1]);
            else api.clearPlaybackRangeHighlight();
        },
        lifecycle(active) {
            if (!active) transport.pause();
        }
    };

    post("ready");
})();

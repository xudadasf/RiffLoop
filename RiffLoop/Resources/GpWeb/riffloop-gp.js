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
    // Temporary diagnostics for GP backing audio on a physical iPad. Remove after
    // the WebKit/native output breakpoint has been identified.
    const mediaSnapshot = (media) => {
        const mediaElements = Array.from(document.querySelectorAll("audio"));
        return ({
        hasMedia: Boolean(media),
        mediaIndex: media ? mediaElements.indexOf(media) : -1,
        mediaCount: mediaElements.length,
        paused: media?.paused ?? null,
        ended: media?.ended ?? null,
        currentTime: Number(media?.currentTime ?? 0),
        duration: Number(media?.duration ?? 0),
        readyState: media?.readyState ?? null,
        networkState: media?.networkState ?? null,
        muted: media?.muted ?? null,
        volume: media?.volume ?? null,
        playbackRate: media?.playbackRate ?? null,
        errorCode: media?.error?.code ?? null,
        errorMessage: media?.error?.message ?? null,
        actualPlayerMode: Number(synthApi.actualPlayerMode),
        playerState: Number(synthApi.playerState),
        apiTime: Number(synthApi.timePosition),
        masterVolume: Number(synthApi.masterVolume),
        visibility: document.visibilityState
        });
    };
    const postBackingDiagnostic = (stage, media = document.querySelector("audio"), extra = {}) => {
        post("diagnostic", {
            message: JSON.stringify({ stage, ...mediaSnapshot(media), ...extra })
        });
    };
    const probeTypedBackingMetadata = (score) => {
        const bytes = score?.backingTrack?.rawAudioFile;
        if (!bytes?.length) return;

        const isMp3 = (
            (bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33)
            || (bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0)
        );
        if (!isMp3) {
            postBackingDiagnostic("typed-probe-skipped", undefined, { reason: "not-mp3" });
            return;
        }

        const probe = document.createElement("audio");
        probe.dataset.riffloopDiagnosticProbe = "true";
        probe.preload = "metadata";
        probe.style.display = "none";
        document.body.appendChild(probe);
        const probeUrl = URL.createObjectURL(new Blob([bytes], { type: "audio/mpeg" }));
        let finished = false;
        const finish = (stage) => {
            if (finished) return;
            finished = true;
            postBackingDiagnostic(stage, probe, { probeMime: "audio/mpeg" });
            window.setTimeout(() => {
                probe.removeAttribute("src");
                probe.load();
                probe.remove();
                URL.revokeObjectURL(probeUrl);
            }, 0);
        };
        probe.addEventListener("loadedmetadata", () => finish("typed-probe-loadedmetadata"), { once: true });
        probe.addEventListener("error", () => finish("typed-probe-error"), { once: true });
        window.setTimeout(() => finish("typed-probe-timeout"), 3000);
        probe.src = probeUrl;
        probe.load();
    };
    const originalMediaPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (...argumentsList) {
        const media = this;
        postBackingDiagnostic("media-play-called", media);
        let result;
        try {
            result = originalMediaPlay.apply(media, argumentsList);
        } catch (error) {
            postBackingDiagnostic("media-play-threw", media, { thrown: errorMessage(error) });
            throw error;
        }
        if (result && typeof result.then === "function") {
            result.then(
                () => {
                    postBackingDiagnostic("media-play-resolved", media);
                    window.setTimeout(() => postBackingDiagnostic("media-after-500ms", media), 500);
                    window.setTimeout(() => postBackingDiagnostic("media-after-2000ms", media), 2000);
                },
                (error) => postBackingDiagnostic("media-play-rejected", media, {
                    rejection: errorMessage(error)
                })
            );
        }
        return result;
    };
    for (const eventName of [
        "loadedmetadata", "canplay", "play", "playing", "pause", "waiting",
        "stalled", "suspend", "emptied", "ended", "error"
    ]) {
        document.addEventListener(eventName, (event) => {
            if (!(event.target instanceof HTMLMediaElement)) return;
            if (event.target.dataset.riffloopDiagnosticProbe === "true") return;
            postBackingDiagnostic(`media-event-${eventName}`, event.target);
        }, true);
    }
    const createSynthOutputController = (playerApi) => {
        const tracks = new Map();
        const requestedVolumes = new Map();
        const requestedMutes = new Map();
        let enabled = true;
        let masterVolume = 0.75;
        const clampVolume = (value) => Math.min(1, Math.max(0, Number(value) || 0));
        const applyVolume = (track) => {
            const requested = requestedVolumes.get(track.index) ?? 1;
            playerApi.changeTrackVolume([track], requested * masterVolume);
        };
        const applyMute = (track) => {
            playerApi.changeTrackMute(
                [track],
                !enabled || Boolean(requestedMutes.get(track.index))
            );
        };
        const applyTrack = (track) => {
            applyVolume(track);
            applyMute(track);
        };
        const reset = (scoreTracks) => {
            tracks.clear();
            requestedVolumes.clear();
            requestedMutes.clear();
            playerApi.masterVolume = 1;
            for (const track of scoreTracks || []) {
                tracks.set(track.index, track);
                requestedVolumes.set(
                    track.index,
                    clampVolume(Number(track.playbackInfo?.volume ?? 16) / 16)
                );
                requestedMutes.set(track.index, Boolean(track.playbackInfo?.isMute));
                applyTrack(track);
            }
        };
        const setMasterVolume = (volume) => {
            masterVolume = clampVolume(volume);
            for (const track of tracks.values()) applyVolume(track);
        };
        const setEnabled = (value) => {
            enabled = Boolean(value);
            for (const track of tracks.values()) applyMute(track);
        };
        const setTrackVolume = (index, volume) => {
            requestedVolumes.set(Number(index), clampVolume(volume));
            const track = tracks.get(Number(index));
            if (track) applyTrack(track);
        };
        const setTrackMute = (index, muted) => {
            requestedMutes.set(Number(index), Boolean(muted));
            const track = tracks.get(Number(index));
            if (track) applyTrack(track);
        };
        return { reset, setMasterVolume, setEnabled, setTrackVolume, setTrackMute };
    };
    const synthOutput = createSynthOutputController(api);
    let backingEnabled = true;
    let backingVolume = 0.75;
    let soundFontBytes = null;
    let committedRange = null;
    let rangeLoopingEnabled = false;
    let wholeSongLoopingEnabled = false;
    let loadedScoreBytes = null;
    let metronomeSubdivisionFactor = 1;
    let metronomeMasterVolume = 0;
    let countInMasterVolume = 0;
    let beatAccents = ["strong", "normal", "normal", "normal"];
    let scoreHasLoaded = false;
    let didNotifyPlayerReady = false;
    let pendingRangeHighlight = null;
    let lastPositionPostTime = Number.NEGATIVE_INFINITY;
    const metronomeAccent = (pulse) => {
        const factor = Math.max(1, metronomeSubdivisionFactor);
        if (pulse % factor !== 0) return "subdivision";
        return beatAccents[Math.floor(pulse / factor)]
            || (pulse === 0 ? "strong" : "normal");
    };
    const metronomeGain = (pulse) => {
        const accent = metronomeAccent(pulse);
        if (accent === "strong") return 0.95;
        if (accent === "subAccent") return 0.66;
        if (accent === "normal") return 0.44;
        if (accent === "subdivision") return 0.30;
        return 0;
    };
    const applyMetronomePulse = (pulse) => {
        api.metronomeVolume = metronomeMasterVolume * metronomeGain(pulse);
        synthApi.metronomeVolume = 0;
    };
    const reinforceLongLegatoTargets = (midiFile, score) => {
        if (!score) return 0;
        let reinforcedCount = 0;
        for (const track of score.tracks) {
            for (const staff of track.staves) {
                for (const bar of staff.bars) {
                    for (const voice of bar.voices) {
                        for (const beat of voice.beats) {
                            for (const note of beat.notes) {
                                const origin = note.slideOrigin;
                                if (
                                    origin?.slideOutType !== alphaTab.model.SlideOutType.Legato
                                    || origin.slideOrigin?.slideOutType !== alphaTab.model.SlideOutType.Legato
                                ) continue;
                                const tick = Number(beat.absolutePlaybackStart) + Number(midiFile.tickShift || 0);
                                const duration = Math.max(2, Number(beat.playbackDuration) || 0);
                                const noteKey = Number(note.realValue);
                                const trackIndex = Number(track.index);
                                const channel = Number(track.playbackInfo?.primaryChannel) || 0;
                                const velocity = Math.max(32, Math.min(72, Number(note.dynamics ?? 4) * 16 - 9));
                                midiFile.addEvent(new alphaTab.midi.NoteBendEvent(
                                    trackIndex, tick, channel, noteKey, 0x80000000
                                ));
                                midiFile.addEvent(new alphaTab.midi.NoteOnEvent(
                                    trackIndex, tick, channel, noteKey, velocity
                                ));
                                midiFile.addEvent(new alphaTab.midi.NoteOffEvent(
                                    trackIndex, tick + duration - 1, channel, noteKey, velocity
                                ));
                                reinforcedCount += 1;
                            }
                        }
                    }
                }
            }
        }
        return reinforcedCount;
    };
    const configureMetronomeEvents = (playerApi) => {
        playerApi.midiEventsPlayedFilter = [alphaTab.midi.MidiEventType.AlphaTabMetronome];
        playerApi.midiLoad.on((midiFile) => {
            if (metronomeSubdivisionFactor !== 1) {
                const denominatorOffset = Math.log2(metronomeSubdivisionFactor);
                for (const event of midiFile.events) {
                    if (event instanceof alphaTab.midi.TimeSignatureEvent) {
                        event.numerator *= metronomeSubdivisionFactor;
                        event.denominatorIndex += denominatorOffset;
                    }
                }
            }
            reinforceLongLegatoTargets(midiFile, api.score);
        });
        playerApi.midiEventsPlayed.on((event) => {
            const metronomeEvents = Array.from(event.events)
                .filter((item) => item instanceof alphaTab.midi.AlphaTabMetronomeEvent);
            const current = metronomeEvents[metronomeEvents.length - 1];
            if (!current) return;
            const pulseCount = Math.max(1, beatAccents.length * metronomeSubdivisionFactor);
            const nextPulse = (Number(current.metronomeNumerator) + 1) % pulseCount;
            applyMetronomePulse(nextPulse);
        });
    };
    configureMetronomeEvents(api);
    applyMetronomePulse(0);
    const canUseBacking = () => Boolean(api.score?.backingTrack);
    const backingMediaElement = () => document.querySelector("audio");
    const resumeBackingMedia = () => {
        const media = backingMediaElement();
        if (!media || !media.paused) return false;
        const result = media.play();
        if (result && typeof result.catch === "function") {
            result.catch((error) => postBackingDiagnostic("media-resume-rejected", media, {
                rejection: errorMessage(error)
            }));
        }
        return true;
    };
    const pauseBackingMedia = () => {
        const media = backingMediaElement();
        if (!media || media.paused) return false;
        media.pause();
        return true;
    };
    const createBackingAligner = (deps) => {
        const { synthApi, canUseBacking } = deps;
        const align = (scoreTime) => {
            const target = Number(scoreTime);
            if (!canUseBacking() || !Number.isFinite(target)) return false;
            synthApi.timePosition = Math.max(0, target);
            return true;
        };
        return { align };
    };
    const createTransportController = (deps) => {
        const { api, synthApi, canUseBacking, schedule } = deps;
        const reportState = deps.reportState || (() => {});
        const playerIsPlaying = (player) => (
            player.playerState === alphaTab.synth.PlayerState.Playing
        );
        const alignBacking = deps.alignBacking || (() => {
            synthApi.timePosition = api.timePosition;
        });
        const setBackingAudible = deps.setBackingAudible || (() => {});
        const resumeBacking = deps.resumeBacking || (() => false);
        const pauseBacking = deps.pauseBacking || (() => false);
        let wantsPlayback = false;
        let backingPriming = false;
        let backingStarted = false;
        let scoreAdvanced = false;
        let playbackAnchorTime = 0;
        let latestScoreTime = 0;
        let pauseGeneration = 0;
        const resetBackingPriming = () => {
            backingPriming = false;
            backingStarted = false;
            scoreAdvanced = false;
            setBackingAudible(true);
        };
        const finishBackingPriming = () => {
            if (!wantsPlayback || !backingPriming || !backingStarted || !scoreAdvanced) return false;
            backingPriming = false;
            alignBacking(latestScoreTime);
            setBackingAudible(true);
            return true;
        };
        const pauseNow = () => {
            api.pause();
            synthApi.pause();
            pauseBacking();
        };
        const pause = () => {
            wantsPlayback = false;
            resetBackingPriming();
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
            playbackAnchorTime = Number(api.timePosition) || 0;
            latestScoreTime = playbackAnchorTime;
            backingPriming = canUseBacking();
            backingStarted = false;
            scoreAdvanced = false;
            if (backingPriming) {
                alignBacking(playbackAnchorTime);
                setBackingAudible(false);
                synthApi.play();
                // alphaTab can remain in Playing while its HTMLMediaElement stays
                // paused after the first pause on iOS WKWebView. Nudge only that
                // stale media state; ordinary starts are already unpaused here.
                resumeBacking();
            }
            api.play();
            reportState(true, false);
        };
        const startDeferredBacking = (scoreTime) => {
            const target = Number(scoreTime);
            if (
                !wantsPlayback
                || !backingPriming
                || !canUseBacking()
                || !Number.isFinite(target)
                || target <= playbackAnchorTime + 0.5
            ) return false;
            scoreAdvanced = true;
            latestScoreTime = target;
            if (playerIsPlaying(synthApi)) backingStarted = true;
            return finishBackingPriming();
        };
        const markBackingStarted = (scoreTime) => {
            if (!wantsPlayback || !backingPriming || !canUseBacking()) return false;
            backingStarted = true;
            const target = Number(scoreTime);
            if (scoreAdvanced && Number.isFinite(target)) latestScoreTime = target;
            return finishBackingPriming();
        };
        const toggle = () => {
            if (wantsPlayback || playerIsPlaying(api) || playerIsPlaying(synthApi)) pause();
            else play();
        };
        const stop = () => {
            wantsPlayback = false;
            resetBackingPriming();
            pauseGeneration += 1;
            api.stop();
            synthApi.stop();
            pauseBacking();
            reportState(false, true);
        };
        const markStopped = () => {
            wantsPlayback = false;
            resetBackingPriming();
            pauseGeneration += 1;
            reportState(false, true);
        };
        const applyBackingOutput = () => setBackingAudible(!backingPriming);
        const isPlayingIntent = () => wantsPlayback;
        return {
            play,
            pause,
            toggle,
            stop,
            markStopped,
            startDeferredBacking,
            markBackingStarted,
            applyBackingOutput,
            isPlayingIntent
        };
    };
    const backingAligner = createBackingAligner({
        synthApi,
        canUseBacking
    });
    const transport = createTransportController({
        api,
        synthApi,
        canUseBacking,
        alignBacking: (scoreTime = api.timePosition) => backingAligner.align(scoreTime),
        resumeBacking: resumeBackingMedia,
        pauseBacking: pauseBackingMedia,
        setBackingAudible: (audible) => {
            if (canUseBacking()) {
                synthApi.masterVolume = audible && backingEnabled ? backingVolume : 0;
            }
        },
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
    const loopScrollPlan = (rangeTop, rangeBottom, viewportHeight) => {
        const rangeHeight = Math.max(0, Number(rangeBottom) - Number(rangeTop));
        const visibleHeight = Math.max(0, Number(viewportHeight));
        if (rangeHeight <= Math.max(0, visibleHeight - 64)) {
            return {
                mode: "locked",
                targetTop: Math.max(0, Math.round(Number(rangeTop) - (visibleHeight - rangeHeight) / 2))
            };
        }
        return { mode: "smooth", targetTop: null };
    };
    const applyRangeScrollPolicy = (firstBar, lastBar) => {
        const lookup = api.renderer?.boundsLookup;
        const firstBounds = lookup?.findMasterBarByIndex(Number(firstBar))?.realBounds;
        const lastBounds = lookup?.findMasterBarByIndex(Number(lastBar))?.realBounds;
        if (!firstBounds || !lastBounds) return;
        const plan = loopScrollPlan(
            firstBounds.y,
            lastBounds.y + lastBounds.h,
            viewportElement.clientHeight
        );
        const scrollMode = plan.mode === "locked"
            ? alphaTab.ScrollMode.Off
            : alphaTab.ScrollMode.Smooth;
        if (api.settings.player.scrollMode !== scrollMode) {
            api.settings.player.scrollMode = scrollMode;
            api.settings.player.scrollSpeed = 450;
            api.settings.player.nativeBrowserSmoothScroll = false;
            if (plan.mode === "smooth") {
                api.settings.player.scrollOffsetY = scoreFollowOffset(
                    viewportElement.clientHeight || window.innerHeight
                );
            }
            api.updateSettings();
        }
        if (plan.targetTop !== null && Math.abs(viewportElement.scrollTop - plan.targetTop) > 2) {
            viewportElement.scrollTo({ top: plan.targetTop, behavior: "smooth" });
        }
    };
    const restoreScoreScrollPolicy = () => {
        if (api.settings.player.scrollMode === alphaTab.ScrollMode.Smooth) return;
        api.settings.player.scrollMode = alphaTab.ScrollMode.Smooth;
        api.settings.player.scrollOffsetY = scoreFollowOffset(viewportElement.clientHeight || window.innerHeight);
        api.updateSettings();
    };
    const seekBoth = (tick, options = {}) => {
        const position = Number(tick);
        api.tickPosition = position;
        synthApi.tickPosition = position;
        refreshPendingRangeHighlight();
        if (options.reveal === false) return;
        window.setTimeout(() => {
            if (api.isReadyForPlayback) api.scrollToCursor();
            refreshPendingRangeHighlight();
        }, 50);
    };
    const stopTick = () => rangeLoopingEnabled && committedRange ? committedRange.startTick : 0;
    const enforceCommittedRange = (position) => {
        if (
            !rangeLoopingEnabled
            || !committedRange
            || position.isSeek
            || Number(position.currentTick) < committedRange.endTick
        ) return false;
        seekBoth(committedRange.startTick, { reveal: false });
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
        synthOutput.reset(score.tracks);
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
    synthApi.playerReady.on(() => postBackingDiagnostic("synth-player-ready"));
    synthApi.scoreLoaded.on((score) => {
        postBackingDiagnostic("synth-score-loaded", undefined, {
            hasBackingTrack: Boolean(score.backingTrack),
            rawAudioBytes: Number(score.backingTrack?.rawAudioFile?.length ?? 0),
            syncPointCount: Number(score.backingTrack?.syncPoints?.length ?? 0),
            userAgent: navigator.userAgent
        });
        probeTypedBackingMetadata(score);
    });
    synthApi.playerStateChanged.on((state) => {
        postBackingDiagnostic("synth-player-state", undefined, {
            eventState: Number(state?.state)
        });
        if (
            synthApi.playerState === alphaTab.synth.PlayerState.Playing
            || state?.state === alphaTab.synth.PlayerState.Playing
        ) {
            transport.markBackingStarted(api.timePosition);
        }
    });
    document.addEventListener("playing", (event) => {
        if (event.target !== backingMediaElement()) return;
        transport.markBackingStarted(api.timePosition);
    }, true);
    api.playerPositionChanged.on((position) => {
        if (!position.isSeek) transport.startDeferredBacking(position.currentTime);
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

    const beatTickRange = (beat) => {
        const startTick = Number(api.tickCache?.getBeatStart(beat) ?? beat.absolutePlaybackStart);
        const duration = Math.max(1, Number(beat.playbackDuration || beat.displayDuration || 0));
        return { startTick, endTick: startTick + duration };
    };

    const closestRangeBeat = (barIndex, tick, useEnd) => {
        let closest = null;
        let closestDistance = Number.POSITIVE_INFINITY;
        for (const beat of playbackRangeBeats(barIndex)) {
            const range = beatTickRange(beat);
            const value = useEnd ? range.endTick : range.startTick;
            const distance = Math.abs(value - Number(tick));
            if (distance < closestDistance) {
                closest = beat;
                closestDistance = distance;
            }
        }
        return closest;
    };

    const refreshPendingRangeHighlight = () => {
        if (!pendingRangeHighlight) return;
        const startBeat = closestRangeBeat(
            pendingRangeHighlight.firstBar,
            pendingRangeHighlight.startTick,
            false
        ) || firstBeatInBar(pendingRangeHighlight.firstBar);
        const endBeat = closestRangeBeat(
            pendingRangeHighlight.lastBar,
            pendingRangeHighlight.endTick,
            true
        ) || lastBeatInBar(pendingRangeHighlight.lastBar);
        if (!startBeat || !endBeat) return;
        try {
            api.highlightPlaybackRange(startBeat, endBeat);
        } catch {
            // Bounds can be unavailable during the frame that replaces a rendered track.
            api.clearPlaybackRangeHighlight();
        }
    };
    api.playerStateChanged.on((state) => {
        refreshPendingRangeHighlight();
        post("playerStateChanged", {
            state: transport.isPlayingIntent() ? 1 : 0,
            stopped: Boolean(state.stopped) && !transport.isPlayingIntent()
        });
    });

    const hitScorePosition = (clientX, clientY) => {
        const lookup = api.renderer?.boundsLookup;
        if (!lookup || !api.score?.masterBars?.length) return null;
        const rect = scoreElement.getBoundingClientRect();
        const x = clientX - rect.left;
        const y = clientY - rect.top;
        const beat = lookup.getBeatAtPos(x, y);
        const beatIndex = beat?.voice?.bar?.masterBar?.index;
        if (Number.isInteger(beatIndex)) {
            const bar = barPayload(beatIndex);
            if (!bar) return null;
            const beatTick = Number(api.tickCache?.getBeatStart(beat) ?? beat.absolutePlaybackStart);
            const beatDuration = Math.max(1, Number(beat.playbackDuration || beat.displayDuration || 0));
            return {
                bar,
                seekTick: Number.isFinite(beatTick) ? beatTick : bar.startTick,
                seekEndTick: Number.isFinite(beatTick) ? beatTick + beatDuration : bar.endTick
            };
        }

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
        return nearest ? {
            bar: nearest,
            seekTick: nearest.startTick,
            seekEndTick: nearest.endTick
        } : null;
    };

    const createPointerSelection = (deps) => {
        const DRAG_SLOP_PIXELS = 8;
        const EDGE_SCROLL_ZONE_PIXELS = 64;
        const EDGE_SCROLL_STEP_PIXELS = 12;

        const { element, viewport, hitScorePosition, post, scheduleLongPress, cancelLongPress } = deps;
        const bridgeHitPayload = (hit) => ({
            ...hit.bar,
            seekTick: hit.seekTick,
            seekEndTick: hit.seekEndTick
        });
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
            post("pointerDown", bridgeHitPayload(pointer.hit));
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
                const hit = hitScorePosition(event.clientX, event.clientY);
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
                    const hit = hitScorePosition(event.clientX, event.clientY);
                    if (hit && hit.seekTick !== pointer.hit.seekTick) {
                        pointer.hit = hit;
                        post("pointerMove", bridgeHitPayload(hit));
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
                    post("pointerMove", bridgeHitPayload(lastHit));
                    post("pointerUp");
                    return;
                }
                if (mode === "pending") {
                    const hit = hitScorePosition(event.clientX, event.clientY) || lastHit;
                    if (hit) post("barHit", bridgeHitPayload(hit));
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
        hitScorePosition,
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
                restoreScoreScrollPolicy();
                loadedScoreBytes = decodeBase64(base64);
                api.load(loadedScoreBytes.slice());
                synthApi.load(loadedScoreBytes.slice());
            } catch (error) {
                post("error", { message: `乐谱加载失败：${errorMessage(error)}` });
            }
        },
        playPause() { playPauseBoth(); },
        pause() { transport.pause(); },
        stop() { transport.stop(); seekBoth(stopTick()); },
        seekTick(tick) { seekBoth(tick); },
        setPlaybackSpeed(speed) { api.playbackSpeed = Number(speed); synthApi.playbackSpeed = Number(speed); },
        setMasterVolume(volume) {
            synthOutput.setMasterVolume(volume);
        },
        setBackingVolume(volume) {
            backingVolume = Number(volume);
            transport.applyBackingOutput();
        },
        setSynthEnabled(enabled) {
            synthOutput.setEnabled(enabled);
        },
        setBackingEnabled(enabled) {
            const wasEnabled = backingEnabled;
            backingEnabled = Boolean(enabled);
            if (canUseBacking()) {
                if (backingEnabled && !wasEnabled) {
                    transport.pause();
                    backingAligner.align(api.timePosition);
                }
                transport.applyBackingOutput();
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
            countInMasterVolume = Number.isFinite(value) ? Math.max(0, value) : 0;
            api.countInVolume = countInMasterVolume;
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
            synthOutput.setTrackMute(index, mute);
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
            synthOutput.setTrackVolume(index, volume);
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
            restoreScoreScrollPolicy();
            api.clearPlaybackRangeHighlight();
        },
        previewRange(firstBar, lastBar, startTick, endTick) {
            pendingRangeHighlight = {
                firstBar: Number(firstBar),
                lastBar: Number(lastBar),
                startTick: Number(startTick),
                endTick: Number(endTick)
            };
            refreshPendingRangeHighlight();
        },
        commitRange(firstBar, lastBar, startTick, endTick) {
            const rangeStartTick = Number(startTick);
            committedRange = {
                startTick: rangeStartTick,
                endTick: Number(endTick),
                firstBar: Number(firstBar),
                lastBar: Number(lastBar)
            };
            rangeLoopingEnabled = true;
            wholeSongLoopingEnabled = false;
            applyLoopMode();
            seekBoth(rangeStartTick, { reveal: false });
            window.riffloop.previewRange(firstBar, lastBar, rangeStartTick, endTick);
            window.riffloopCommittedBars = [
                Number(firstBar),
                Number(lastBar),
                rangeStartTick,
                Number(endTick)
            ];
            window.setTimeout(() => applyRangeScrollPolicy(firstBar, lastBar), 50);
        },
        setRangeLoopingEnabled(enabled) {
            rangeLoopingEnabled = Boolean(enabled) && Boolean(committedRange);
            if (rangeLoopingEnabled) wholeSongLoopingEnabled = false;
            applyLoopMode();
            if (rangeLoopingEnabled) {
                applyRangeScrollPolicy(committedRange.firstBar, committedRange.lastBar);
            } else {
                restoreScoreScrollPolicy();
            }
        },
        setWholeSongLoopingEnabled(enabled) {
            wholeSongLoopingEnabled = Boolean(enabled);
            if (wholeSongLoopingEnabled) rangeLoopingEnabled = false;
            applyLoopMode();
            if (wholeSongLoopingEnabled) restoreScoreScrollPolicy();
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
            if (bars) window.riffloop.previewRange(bars[0], bars[1], bars[2], bars[3]);
            else {
                pendingRangeHighlight = null;
                api.clearPlaybackRangeHighlight();
            }
        },
        lifecycle(active) {
            if (!active) transport.pause();
        }
    };

    post("ready");
})();

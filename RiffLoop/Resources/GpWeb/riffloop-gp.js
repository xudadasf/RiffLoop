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
            scriptFile: "./alphaTab.min.js",
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
            soundFont: "./soundfont/sonivox.sf3",
            scrollElement: "#viewport",
            enableCursor: true,
            enableUserInteraction: true
        }
    });

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
    api.scoreLoaded.on((score) => post("scoreLoaded", {
        title: score.title || "未命名乐谱",
        artist: score.artist || "",
        bars: score.masterBars.length,
        tracks: score.tracks.map(trackPayload)
    }));
    api.renderFinished.on((result) => post("renderFinished", {
        width: Number(result.totalWidth || scoreElement.scrollWidth || 0),
        height: Number(result.totalHeight || scoreElement.scrollHeight || 0)
    }));
    api.playerReady.on(() => post("playerReady"));
    api.playerPositionChanged.on((position) => post("positionChanged", {
        currentTime: position.currentTime,
        totalTime: position.endTime,
        currentTick: position.currentTick,
        endTick: position.endTick
    }));
    api.playerStateChanged.on((state) => post("playerStateChanged", {
        state: state.state,
        stopped: state.stopped
    }));
    api.beatMouseDown.on((beat) => {
        const bar = barPayload(beat?.voice?.bar?.masterBar?.index ?? -1);
        if (bar) post("barHit", bar);
    });

    const decodeBase64 = (base64) => {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index += 1) {
            bytes[index] = binary.charCodeAt(index);
        }
        return bytes;
    };

    window.riffloop = {
        loadScore(base64) {
            try {
                api.load(decodeBase64(base64));
            } catch (error) {
                post("error", { message: `乐谱加载失败：${errorMessage(error)}` });
            }
        },
        playPause() { api.playPause(); },
        pause() { api.pause(); },
        stop() { api.stop(); },
        seekTick(tick) { api.tickPosition = Number(tick); },
        setPlaybackSpeed(speed) { api.playbackSpeed = Number(speed); },
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
        },
        setTrackSolo(index, solo) {
            const track = api.score?.tracks[index];
            if (track) api.changeTrackSolo([track], Boolean(solo));
        },
        setTrackVolume(index, volume) {
            const track = api.score?.tracks[index];
            if (track) api.changeTrackVolume([track], Number(volume));
        },
        setPlaybackRange(startTick, endTick) {
            api.playbackRange = {
                startTick: Number(startTick),
                endTick: Number(endTick)
            };
        },
        clearPlaybackRange() { api.playbackRange = null; },
        lifecycle(active) {
            if (!active) api.pause();
        }
    };

    post("ready");
})();

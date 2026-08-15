import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
    new URL("../RiffLoop/Resources/GpWeb/riffloop-gp.js", import.meta.url),
    "utf8"
);
const startMarker = "    const playPauseBoth = () => {";
const endMarker = "\n\n    const trackPayload";
const start = source.indexOf(startMarker);
const end = source.indexOf(endMarker, start);
assert.notEqual(start, -1, "playPauseBoth implementation is missing");
assert.notEqual(end, -1, "playPauseBoth implementation boundary is missing");
const implementation = source.slice(start, end);

function runPlayback({ hasBacking, synthEnabled, mainPlaying = false, synthPlaying = false }) {
    const api = player(mainPlaying);
    const synthApi = player(synthPlaying);
    const execute = new Function(
        "api",
        "synthApi",
        "canUseBacking",
        "synthEnabled",
        `let startingBoth = false;\n${implementation}\nplayPauseBoth();`
    );
    execute(api, synthApi, () => hasBacking, synthEnabled);
    return { api, synthApi };
}

function player(isPlaying) {
    return {
        isPlaying,
        playCalls: 0,
        pauseCalls: 0,
        play() { this.playCalls += 1; },
        pause() { this.pauseCalls += 1; },
    };
}

{
    const { api, synthApi } = runPlayback({ hasBacking: true, synthEnabled: false });
    assert.equal(api.playCalls, 1, "muting both sources must not disable the main transport");
    assert.equal(synthApi.playCalls, 0, "muted synthesis must stay silent");
}

{
    const { api } = runPlayback({ hasBacking: false, synthEnabled: false });
    assert.equal(api.playCalls, 1, "a score without backing must still allow silent transport");
}

{
    const { api, synthApi } = runPlayback({ hasBacking: true, synthEnabled: true });
    assert.equal(api.playCalls, 1);
    assert.equal(synthApi.playCalls, 1);
}

{
    const { api, synthApi } = runPlayback({
        hasBacking: true,
        synthEnabled: true,
        mainPlaying: true,
    });
    assert.equal(api.pauseCalls, 1);
    assert.equal(synthApi.pauseCalls, 1);
}

console.log("GP playback transport policy passed");

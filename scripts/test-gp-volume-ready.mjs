import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const alphaTab = createRequire(import.meta.url)('../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const source = readFileSync(new URL('../RiffLoop/Resources/GpWeb/riffloop-gp.js', import.meta.url), 'utf8').replaceAll('\r\n', '\n');

// Ow installs the shipped alphaTab's real ready callback, including its reset of
// displayed tracks to the volumes from the score. A later ready notification can
// occur after Swift has already restored the user's settings for this score.
let prototype = alphaTab.AlphaTabApi.prototype;
while (!Object.prototype.hasOwnProperty.call(prototype, 'Ow')) prototype = Object.getPrototypeOf(prototype);
const tracks = [
    { index: 0, playbackInfo: { volume: 8, primaryChannel: 0, secondaryChannel: 1, isMute: false } },
    { index: 1, playbackInfo: { volume: 16, primaryChannel: 2, secondaryChannel: 3, isMute: false } }
];
const native = { tracks: [tracks[0]], Hw() {}, $w() {}, onError() {}, Vw() {}, zw() {}, Uw() {}, Xw() {}, jw() {}, Jw() {} };
prototype.Ow.call(native);
const playerReadyGetter = Object.getOwnPropertyDescriptor(prototype, 'playerReady')?.get;
assert.ok(playerReadyGetter, 'shipped alphaTab playerReady getter is missing');
const channels = new Map();
native.Mw.setChannelVolume = (channel, volume) => channels.set(channel, volume);
const api = {
    get playerReady() { return playerReadyGetter.call(native); },
    changeTrackVolume([track], volume) {
        native.Mw.setChannelVolume(track.playbackInfo.primaryChannel, volume);
        native.Mw.setChannelVolume(track.playbackInfo.secondaryChannel, volume);
    },
    changeTrackMute() {},
    masterVolume: 1
};
const synthCode = source.slice(source.indexOf('    const createSynthOutputController ='), source.indexOf('    const synthOutput ='));
const synthOutput = new Function(`${synthCode}; return createSynthOutputController;`)()(api);
synthOutput.reset(tracks);
synthOutput.setMasterVolume(4);
assert.equal(channels.get(0), 2);
assert.equal(channels.get(2), 4);

const readyCode = source.slice(source.indexOf('    api.playerReady.on(() => {'), source.indexOf('    synthApi.playerReady.on(() => {'));
assert.ok(readyCode.includes('api.playerReady.on'), 'production ready callback is missing');
new Function('api', 'synthOutput', 'configureAudioOutput', 'notifyPlayerReady',
    `let mainPlayerReadyForScore = false; ${readyCode}`)(api, synthOutput, () => {}, () => {});

native.Mw.readyForPlayback.trigger();
assert.equal(channels.get(0), 2, 'alphaTab ready must not replace the saved master/track volume');
assert.equal(channels.get(1), 2, 'secondary channel must keep the same selected volume');
assert.equal(channels.get(2), 4, 'other tracks retain their selected volume');
native.Mw.readyForPlayback.trigger();
assert.equal(channels.get(0), 2, 'a repeated ready event must not change the volume');
console.log('GP saved volume survives actual alphaTab ready callback order');

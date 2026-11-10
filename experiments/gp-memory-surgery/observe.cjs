// Experimental local importer, stdin/stdout pipes only. Output may contain
// score data and must remain in the local parent process, never in CI logs.
const fs = require('node:fs');
const { createHash } = require('node:crypto');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const settings = new alpha.Settings();
const pick = (object, keys) => Object.fromEntries(keys.map(key => [key, object[key] ?? null]));
const automation = value => ({
    ...pick(value, ['type', 'value', 'ratioPosition', 'isLinear', 'isVisible', 'text']),
    syncPointValue: value.syncPointValue == null ? null :
        pick(value.syncPointValue, ['barOccurence', 'millisecondOffset'])
});
function backingTrack(score) {
    if (score.backingTrack == null) return null;
    const audio = score.backingTrack.rawAudioFile;
    if (audio == null) return { audio: null };
    if (!(audio instanceof Uint8Array)) throw new TypeError('Unexpected backing track data');
    // The digest is local comparison data and must not be uploaded or logged.
    return { audio: { length: audio.byteLength, sha256: createHash('sha256').update(audio).digest('hex') } };
}
function snapshot(score) {
    return {
        metadata: pick(score, ['title', 'artist', 'album', 'copyright', 'tempo']),
        backingTrack: backingTrack(score),
        bars: score.masterBars.map(bar => ({
            ...pick(bar, ['start', 'timeSignatureNumerator', 'timeSignatureDenominator', 'isRepeatStart',
                'repeatCount', 'alternateEndings', 'tripletFeel', 'isFreeTime']),
            tempo: bar.tempoAutomations.map(automation),
            // A missing list and a present empty list remain distinguishable.
            syncPoints: bar.syncPoints == null ? null : bar.syncPoints.map(automation)
        })),
        tracks: score.tracks.map(track => ({
            ...pick(track, ['name']),
            playback: pick(track.playbackInfo, ['program', 'bank', 'port', 'primaryChannel',
                'secondaryChannel', 'volume', 'balance', 'isMute', 'isSolo']),
            staves: track.staves.map(staff => ({
                tuning: Array.from(staff.stringTuning.tunings),
                ...pick(staff, ['capo', 'transpositionPitch', 'displayTranspositionPitch', 'isPercussion']),
                bars: staff.bars.map(bar => bar.voices.map(voice => voice.beats.map(beat => ({
                    ...pick(beat, ['duration', 'dots', 'tupletNumerator', 'tupletDenominator', 'graceType',
                        'displayStart', 'displayDuration', 'playbackStart', 'playbackDuration',
                        'isLetRing', 'isPalmMute', 'text', 'pickStroke', 'tremoloPicking', 'vibrato', 'dynamics']),
                    // Bank and SyncPoint share a numeric type; keep beat and
                    // master-bar automations in separate locations.
                    automations: beat.automations.map(automation),
                    notes: beat.notes.map(note => ({
                        ...pick(note, ['string', 'fret', 'realValue', 'octave', 'tone', 'accidentalMode',
                            'isDead', 'isGhost', 'isStaccato', 'isPalmMute', 'isLetRing', 'isHammerPullOrigin',
                            'isTieDestination', 'isSlurDestination', 'slideInType', 'slideOutType',
                            'harmonicType', 'harmonicValue', 'vibrato', 'trillValue', 'trillSpeed',
                            'leftHandFinger', 'rightHandFinger', 'accentuated', 'bendType']),
                        bendPoints: note.bendPoints?.map(point => pick(point, ['offset', 'value'])) ?? [],
                    }))
                }))))
            }))
        }))
    };
}

if (require.main === module) {
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    process.stdout.write(JSON.stringify(input.map(base64 => snapshot(
        alpha.importer.ScoreLoader.loadScoreFromBytes(Buffer.from(base64, 'base64'), settings)
    ))));
}
module.exports = { snapshot };

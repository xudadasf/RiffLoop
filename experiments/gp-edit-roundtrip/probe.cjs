// Offline experiment only: does not write a GP file or modify the source.
const fs = require('node:fs');
const path = require('node:path');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');

const pick = (obj, keys) => Object.fromEntries(keys.map(key => [key, obj[key] ?? null]));
function snapshot(score) {
    return {
        metadata: pick(score, ['title', 'artist', 'album', 'copyright', 'music', 'words', 'tempo']),
        bars: score.masterBars.map(bar => ({
            ...pick(bar, ['timeSignatureNumerator', 'timeSignatureDenominator', 'isRepeatStart',
                'repeatCount', 'alternateEndings', 'tripletFeel', 'isFreeTime']),
            tempo: bar.tempoAutomations.map(item => pick(item, ['type', 'value', 'ratioPosition', 'isLinear'])),
        })),
        tracks: score.tracks.map(track => ({
            name: track.name,
            playback: pick(track.playbackInfo, ['program', 'volume', 'balance', 'isMute', 'isSolo']),
            staves: track.staves.map(staff => ({
                tuning: Array.from(staff.stringTuning.tunings),
                ...pick(staff, ['capo', 'transpositionPitch', 'displayTranspositionPitch', 'isPercussion']),
                bars: staff.bars.map(bar => bar.voices.map(voice => voice.beats.map(beat => ({
                    ...pick(beat, ['duration', 'dots', 'tupletNumerator', 'tupletDenominator', 'graceType',
                        'isLetRing', 'isPalmMute', 'text', 'pickStroke', 'tremoloPicking', 'vibrato', 'dynamics']),
                    notes: beat.notes.map(note => ({
                        ...pick(note, ['string', 'fret', 'realValue', 'octave', 'tone', 'isDead', 'isGhost', 'isStaccato',
                            'isPalmMute', 'isLetRing', 'isHammerPullOrigin', 'isTieDestination', 'isSlurDestination',
                            'slideInType', 'slideOutType', 'harmonicType', 'harmonicValue', 'vibrato',
                            'trillValue', 'trillSpeed', 'leftHandFinger', 'rightHandFinger', 'accentuated', 'bendType']),
                        bendPoints: note.bendPoints?.map(point => pick(point, ['offset', 'value'])) ?? [],
                    })),
                })))),
            })),
        })),
    };
}

function differences(left, right, root = 'score') {
    if (Object.is(left, right)) return [];
    if (!left || !right || typeof left !== 'object' || typeof right !== 'object' ||
        Array.isArray(left) !== Array.isArray(right)) return [root];
    const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
    const result = [];
    if (Array.isArray(left) && left.length !== right.length) result.push(root + '.length');
    for (const key of keys) {
        const next = Array.isArray(left) ? `${root}[${key}]` : `${root}.${key}`;
        if (!Object.hasOwn(left, key) || !Object.hasOwn(right, key)) result.push(next);
        else result.push(...differences(left[key], right[key], next));
    }
    return result;
}

function findEdit(score) {
    for (const track of score.tracks) for (const staff of track.staves) {
        if (staff.isPercussion) continue;
        for (const bar of staff.bars) for (const voice of bar.voices) {
            for (let i = 0; i + 1 < voice.beats.length; i++) {
                const [first, second] = voice.beats.slice(i, i + 2);
                const note = first.notes[0];
                if ([1, 2, 4, 8, 16, 32].includes(first.duration) && first.duration === second.duration &&
                    first.dots === 0 && second.dots === 0 &&
                    first.tupletNumerator === -1 && second.tupletNumerator === -1 &&
                    first.notes.length === 1 && second.notes.length === 1 && note &&
                    Number.isInteger(note.fret) && note.fret >= 0 && note.fret < 36 &&
                    !note.isTieDestination && !note.tieDestination && !note.isStaccato) {
                    return { first, second, note };
                }
            }
        }
    }
    return null;
}

function run(input) {
    const settings = new alpha.Settings();
    const original = alpha.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(input), settings);
    const originalView = snapshot(original);
    const roundtrip = score => alpha.importer.ScoreLoader.loadScoreFromBytes(
        new alpha.exporter.Gp7Exporter().export(score, settings), settings);
    const baseline = differences(originalView, snapshot(roundtrip(original)));
    const edit = findEdit(original);
    if (!edit) return { baseline, edited: null, reason: 'No suitable adjacent equal-duration note pair' };
    // Preserve total time: two equal notes become half one plus one dotted note.
    edit.note.fret += 1;
    edit.note.isStaccato = true;
    edit.first.duration *= 2;
    edit.second.dots = 1;
    const expected = snapshot(original);
    const changes = differences(originalView, expected);
    const edited = differences(expected, snapshot(roundtrip(original)));
    return { baseline, changes, edited };
}

if (require.main === module) {
    const input = process.argv[2];
    if (!input) throw new Error('Usage: node probe.cjs input.gp');
    const result = run(path.resolve(input));
    // Paths only, no contents, filename, or source material are emitted.
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
}
module.exports = { differences, run };

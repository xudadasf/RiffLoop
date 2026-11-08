// Independent GP import/export probe; not used by the app or its practice player.
const fs = require('node:fs');
const path = require('node:path');
const alpha = require(path.join(__dirname, '../RiffLoop/Resources/GpWeb/alphaTab.min.js'));

const [input, output] = process.argv.slice(2);
if (!input || !output || path.resolve(input) === path.resolve(output)) {
    throw new Error('Usage: node gp-roundtrip-probe.cjs input.gp temporary-output.gp');
}

const fields = (obj, names) => Object.fromEntries(names.map(name => [name, obj[name] ?? null]));
const masterFields = ['timeSignatureNumerator', 'timeSignatureDenominator', 'isRepeatStart', 'repeatCount', 'alternateEndings', 'tripletFeel', 'isFreeTime'];
const beatFields = ['duration', 'dots', 'tupletNumerator', 'tupletDenominator', 'graceType', 'isLetRing', 'isPalmMute', 'isLegatoOrigin', 'text', 'pickStroke', 'tremoloPicking', 'vibrato', 'dynamics'];
const noteFields = ['string', 'fret', 'octave', 'tone', 'isDead', 'isGhost', 'isStaccato', 'isPalmMute', 'isLetRing', 'isHammerPullOrigin', 'isTieDestination', 'isSlurDestination', 'slideInType', 'slideOutType', 'harmonicType', 'harmonicValue', 'vibrato', 'trillValue', 'trillSpeed', 'leftHandFinger', 'rightHandFinger', 'accentuated', 'bendType'];

function snapshot(score) {
    return {
        metadata: fields(score, ['title', 'artist', 'album']),
        masterBars: score.masterBars.map(bar => ({
            ...fields(bar, masterFields),
            tempoAutomations: bar.tempoAutomations.map(item => fields(item, ['isLinear', 'type', 'value', 'ratioPosition', 'text', 'isVisible'])),
        })),
        tracks: score.tracks.map(track => ({
            name: track.name,
            staves: track.staves.map(staff => ({
                tuning: Array.from(staff.stringTuning.tunings),
                ...fields(staff, ['capo', 'transpositionPitch', 'displayTranspositionPitch', 'isPercussion']),
                bars: staff.bars.map(bar => ({
                    voices: bar.voices.map(voice => ({
                        beats: voice.beats.map(beat => ({
                            ...fields(beat, beatFields),
                            notes: beat.notes.map(note => ({
                                ...fields(note, noteFields),
                                bendPoints: note.bendPoints?.map(point => fields(point, ['offset', 'value'])) ?? [],
                            })),
                        })),
                    })),
                })),
            })),
        })),
    };
}

const settings = new alpha.Settings();
const score = alpha.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(input), settings);
const before = snapshot(score);
const exported = new alpha.exporter.Gp7Exporter().export(score, settings);
// Exclusive creation guarantees that a probe never overwrites an existing file.
fs.writeFileSync(output, Buffer.from(exported), { flag: 'wx' });
const after = snapshot(alpha.importer.ScoreLoader.loadScoreFromBytes(exported, settings));
process.stdout.write(JSON.stringify({ before, after }));

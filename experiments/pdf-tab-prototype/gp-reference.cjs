// Evaluation only. This file is never called by recognize.py or the converter.
const fs = require('fs');
const path = require('path');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const [input, output] = process.argv.slice(2);
let score;
try {
    score = alpha.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(input)), new alpha.Settings());
} catch (error) {
    console.error(JSON.stringify({error: String(error.message || error)}));
    process.exit(1);
}
const tracks = score.tracks.flatMap(t => t.staves.map((s, si) => ({
    name: t.name, track: t.index, staff: si, tuning: s.tuning,
    bars: s.bars.map((bar, i) => ({ number: i+1,
        meter: [score.masterBars[i].timeSignatureNumerator, score.masterBars[i].timeSignatureDenominator],
        beats: bar.voices.flatMap((v, vi) => v.beats.map(b => ({
            voice:vi, duration:b.duration, dots:b.dots, grace:b.graceType !== 0,
            fullBarRest:b.isEmpty, rest:b.isRest, tuplet:[b.tupletNumerator,b.tupletDenominator],
            notes:b.notes.map(n => ({string:s.tuning.length+1-n.string, fret:n.isDead?null:n.fret,
                dead:n.isDead, tie:n.isTieDestination, ghost:n.isGhost, bend:n.hasBend, harmonic:n.harmonicType}))
                .sort((a,b)=>a.string-b.string)
        })))
    }))
})));
fs.writeFileSync(output, JSON.stringify({source:path.resolve(input),tempo:score.tempo,tracks},null,2));

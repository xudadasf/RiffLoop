const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { differences, run } = require('./probe.cjs');

assert.deepEqual(differences({ a: [1, 2] }, { a: [1, 3, 4] }), ['score.a.length', 'score.a[1]', 'score.a[2]']);
const fixture = path.resolve(__dirname, '../../RiffLoopTests/Fixtures/transport.gp');
const hash = () => crypto.createHash('sha256').update(fs.readFileSync(fixture)).digest('hex');
const before = hash();
const result = run(fixture);
assert.deepEqual(result.baseline, []);
assert.deepEqual(result.changes.map(change => change.split('.').pop()).sort(),
    ['dots', 'duration', 'fret', 'isStaccato', 'realValue']);
assert.deepEqual(result.edited, []);
assert.equal(hash(), before);
console.log('GP edit roundtrip synthetic fixture: selected fields passed; source unchanged');

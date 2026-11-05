"""Opt-in: actual screenshot OCR -> GP -> compare frozen printed notes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from desktop_batch import process_file

ROOT = Path(__file__).resolve().parent


class RealPageNoteTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('RIFFLOOP_NOTE_AUDIT_ROOT'), 'set RIFFLOOP_NOTE_AUDIT_ROOT for three real-page checks')
    def test_previously_correct_printed_notes_and_bar_boundaries_survive_gp_export(self):
        samples = Path(os.environ['RIFFLOOP_NOTE_AUDIT_ROOT'])
        fixture = json.loads((ROOT/'fixtures/raster-note-pages-20261105.json').read_text(encoding='utf-8'))
        rhythm = json.loads((ROOT/'fixtures/raster-rhythm-pages-20261105.json').read_text(encoding='utf-8'))
        rhythm_cases = {case['id']:case for case in rhythm['cases']}
        node = shutil.which('node')
        self.assertIsNotNone(node)
        script = '''
const fs=require('fs'), alpha=require(process.argv[1]);
const score=alpha.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(process.argv[2]),new alpha.Settings());
console.log(JSON.stringify(score.tracks[0].staves[0].bars.map(bar=>bar.voices[0].beats.flatMap(beat=>beat.notes.map(n=>({
  note:[7-n.string,n.fret],duration:beat.duration,dots:beat.dots,
  tuplet:beat.hasTuplet?[beat.tupletNumerator,beat.tupletDenominator]:[1,1],text:beat.text
}))))));
'''
        for case in fixture['cases']:
            with self.subTest(case=case['id']), tempfile.TemporaryDirectory() as temp:
                source = samples/(case['id']+'-p1.png')
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), case['source_sha256'])
                outcome = process_file(source, Path(temp), {'tempo':100, 'meter':[4,4]})
                self.assertTrue(outcome.get('draft'), outcome['message'])
                result = subprocess.run([node, '-e', script, str(ROOT/'../../RiffLoop/Resources/GpWeb/alphaTab.min.js'),
                                         outcome['draft']], capture_output=True, text=True, encoding='utf-8', check=True, timeout=60)
                bars = json.loads(result.stdout)
                self.assertEqual(len(bars), case['total_bars'])
                for number, expected in case['accepted_bars'].items():
                    actual = [note['note'] for note in bars[int(number)-1]]
                    self.assertEqual(actual, expected, f'{case["id"]}, bar {number}')
                for number, entries in rhythm_cases[case['id']]['bars'].items():
                    for entry in entries:
                        note = bars[int(number)-1][entry['index']-1]
                        self.assertEqual({k:note[k] for k in ('duration','dots','tuplet')}, entry['expected'],
                                         f'{case["id"]}, bar {number}, note {entry["index"]}')
                        if entry['stem']:
                            self.assertIn('?', note['text'] or '')


if __name__ == '__main__':
    unittest.main()

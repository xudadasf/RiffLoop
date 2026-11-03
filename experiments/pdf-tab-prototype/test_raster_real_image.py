"""Opt-in regression: actual OCR -> desktop export -> GP readback -> manual truth.

Set RIFFLOOP_LIAN_IMAGE to the original image. OCR runtime/model overrides use
the same RIFFLOOP_DIGIT_* variables as the desktop worker. No source image or
third-party model is bundled in Git; missing prerequisites fail when opted in.
"""
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


class RealImageTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('RIFFLOOP_LIAN_IMAGE'), 'set RIFFLOOP_LIAN_IMAGE for real OCR regression')
    def test_all_printed_frets_survive_in_the_correct_bar_and_string(self):
        source = Path(os.environ['RIFFLOOP_LIAN_IMAGE'])
        node = shutil.which('node')
        self.assertIsNotNone(node)
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            outcome = process_file(source, folder, {'tempo': 70, 'meter': [4,4]})
            self.assertIsNotNone(outcome['draft'], outcome['message'])
            recognized = json.loads((folder/'recognized.json').read_text(encoding='utf-8'))
            self.assertEqual([s['region']['expected_bars'] for s in recognized['systems']], [3,3,2])
            self.assertFalse(any(s['unresolved'] or s['discarded_bands'] for s in recognized['systems']))
            readback = subprocess.run([node, '-e', '''
const fs=require('fs'), alpha=require(process.argv[1]);
const score=alpha.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(process.argv[2]),new alpha.Settings());
console.log(JSON.stringify(score.tracks[0].staves[0].bars.map(b=>b.voices[0].beats.flatMap(b=>b.notes.map(n=>[7-n.string,n.fret])))));
''', str(ROOT/'../../RiffLoop/Resources/GpWeb/alphaTab.min.js'), outcome['draft']],
                capture_output=True, text=True, check=True, timeout=60)
            # The recognizer/exporter has no reference-file argument. Load the
            # manually transcribed answer only after producing and reading GP.
            truth = json.loads((ROOT/'fixtures/lian-note-truth.json').read_text(encoding='utf-8'))
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), truth['source_sha256'])
            self.assertEqual(json.loads(readback.stdout), truth['bars'])


if __name__ == '__main__':
    unittest.main()

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class DraftExportTests(unittest.TestCase):
    def test_new_image_draft_accepts_explicit_defaults_but_rejects_overflow(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            data = self.fixture()
            data.update(format='raster-tab-beamed-v1', meter=[4, 4])
            bar = data['systems'][0]['bars'][0]
            bar['beats'] = [{'duration': 16, 'dots': 0, 'tuplet': [1, 1], 'grace': False,
                             'notes': [{'string': 6, 'fret': 5}], 'rhythm_source': 'manual-default',
                             'placeholder': True} for _ in range(16)]
            source = folder / 'image.json'
            source.write_text(json.dumps(data), encoding='utf-8')
            output = folder / 'image.draft.gp'
            run = subprocess.run(['node', str(ROOT/'gp-draft-export.cjs'), str(source), str(output)], capture_output=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            review = json.loads(Path(str(output)+'.review.json').read_text(encoding='utf-8'))
            self.assertEqual(review['bars'][0]['placeholder_beats'], list(range(1, 17)))
            for value in (4, None):
                bar['beats'][0]['duration'] = value
                source.write_text(json.dumps(data), encoding='utf-8')
                bad = folder / f'bad-{value}.draft.gp'
                run = subprocess.run(['node', str(ROOT/'gp-draft-export.cjs'), str(source), str(bad)], capture_output=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertFalse(bad.exists())

    def fixture(self):
        return {'tuning': [64, 59, 55, 50, 45, 40], 'tempo': 100,
                'systems': [{'page': 2, 'bars': [{'number': 1, 'meter': [4, 4],
                    'issues': ['unknown duration'], 'beats': [
                        {'duration': None, 'dots': 0, 'tuplet': [1, 1], 'grace': False,
                         'notes': [{'string': 1, 'fret': 7, 'dead': False}]},
                        {'duration': 8, 'dots': 0, 'tuplet': [3, 2], 'grace': False,
                         'notes': [{'string': 6, 'fret': None, 'dead': True}]}]}]}]}

    def test_draft_preserves_notes_marks_placeholder_and_strict_still_blocks(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); source = folder/'source.json'; output = folder/'score.draft.gp'
            source.write_text(json.dumps(self.fixture()), encoding='utf-8')
            strict = subprocess.run(['node', str(ROOT/'gp-export.cjs'), str(source), str(folder/'strict.gp')], capture_output=True)
            self.assertNotEqual(strict.returncode, 0)
            run = subprocess.run(['node', str(ROOT/'gp-draft-export.cjs'), str(source), str(output)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            report = json.loads(Path(str(output)+'.review.json').read_text(encoding='utf-8'))
            self.assertFalse(report['playback_verified'])
            self.assertEqual(report['bars'][0]['placeholder_beats'], [1])
            self.assertEqual(report['note_count'], 2)
            script = "const a=require(process.argv[1]),fs=require('fs');const s=a.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(process.argv[2]),new a.Settings());console.log(JSON.stringify({title:s.title,beats:s.tracks[0].staves[0].bars[0].voices[0].beats.map(b=>({d:b.duration,text:b.text,notes:b.notes.map(n=>[7-n.string,n.isDead?null:n.fret,n.isDead])}))}));"
            readback = subprocess.run(['node', '-e', script, str(ROOT.parent.parent/'RiffLoop/Resources/GpWeb/alphaTab.min.js'), str(output)], capture_output=True, text=True, check=True)
            data = json.loads(readback.stdout)
            self.assertIn('DRAFT', data['title'])
            self.assertEqual([b['notes'] for b in data['beats']], [[[1, 7, False]], [[6, None, True]]])
            self.assertEqual([b['d'] for b in data['beats']], [4, 8])
            self.assertIn('placeholder', data['beats'][0]['text'])

    def test_unknown_fret_is_never_replaced_by_open_string(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); source = folder/'source.json'; output = folder/'score.draft.gp'
            data = self.fixture(); data['systems'][0]['bars'][0]['beats'][0]['notes'][0]['fret'] = None
            source.write_text(json.dumps(data), encoding='utf-8')
            run = subprocess.run(['node', str(ROOT/'gp-draft-export.cjs'), str(source), str(output)], capture_output=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse(output.exists())

    def test_image_unknown_rhythm_cannot_be_exported_as_quarter_placeholders(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source, output = folder / 'image.json', folder / 'image.draft.gp'
            data = self.fixture()
            data.update(format='raster-tab-draft-v1', meter=[4, 4], model_revision='test-model',
                        model_checkpoint_sha256='test-digest', warnings=['人工设置；音符可能有误'])
            for beat in data['systems'][0]['bars'][0]['beats']:
                beat.update(duration=None, dots=0, tuplet=[1, 1])
            source.write_text(json.dumps(data), encoding='utf-8')
            run = subprocess.run(['node', str(ROOT/'gp-draft-export.cjs'), str(source), str(output)], capture_output=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(b'Image GP export is disabled', run.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()

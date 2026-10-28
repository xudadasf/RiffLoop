import copy
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from desktop_batch import ROOT
from desktop_join import combine_scores, process_join, validate_join


def part(name, fret, tempo=100, meter=None, image=True):
    meter = meter or [4, 4]
    beats = [{'duration': meter[1], 'dots': 0, 'tuplet': [1, 1], 'grace': False,
              'notes': [{'string': 1, 'fret': fret}], 'placeholder': image,
              'rhythm_source': 'manual-default', 'note_review': image} for _ in range(meter[0])]
    return {'name': name, 'source': name, 'report': name + '.html', 'score': {
        'format': 'raster-tab-beamed-v1' if image else 'vector', 'tempo': tempo,
        'tuning': [64, 59, 55, 50, 45, 40], 'structure_issues': [], 'systems': [
            {'page': 1, 'bars': [{'number': 1, 'source_bar': 1, 'meter': meter, 'beats': beats, 'issues': []}]}]}}


class JoinTests(unittest.TestCase):
    def test_mixed_gaps_order_and_inputs_unchanged(self):
        parts = [part('C', 7), part('A', 3), part('B', 5)]
        before = copy.deepcopy(parts)
        data = combine_scores(parts, [2, 0], '合并')
        bars = [b for s in data['systems'] for b in s['bars']]
        self.assertEqual([b['number'] for b in bars], [1, 2, 3, 4, 5])
        self.assertEqual([b['beats'][0]['notes'][0]['fret'] for b in bars if not b.get('separator')], [7, 3, 5])
        self.assertEqual([b['number'] for b in bars if b.get('separator')], [2, 3])
        self.assertEqual([p['start_bar'] for p in data['join_parts']], [1, 4, 5])
        self.assertEqual(parts, before)
        self.assertTrue(bars[0]['beats'][0]['placeholder'])
        self.assertFalse(bars[1]['beats'][0]['placeholder'])

    def test_separator_meter_and_tempo_then_next_segment_changes(self):
        data = combine_scores([part('A', 3, 88, [6, 8]), part('B', 5, 120, [3, 4])], [1], '合并')
        bars = [b for s in data['systems'] for b in s['bars']]
        self.assertEqual([(b['meter'], b['tempo']) for b in bars], [([6, 8], 88), ([6, 8], 88), ([3, 4], 120)])
        self.assertEqual(sum(4 / b['duration'] * (2 - 2 ** -b['dots']) for b in bars[1]['beats']), 3)
        self.assertTrue(all(not b['notes'] for b in bars[1]['beats']))

    def test_invalid_gaps_and_incompatible_tuning_rejected(self):
        for gaps in ([1, 2], [-1], [1.5], [True], [100]):
            with self.subTest(gaps=gaps), self.assertRaises(ValueError):
                validate_join(['a', 'b'], gaps, 'test')
        parts = [part('A', 3), part('B', 5)]
        parts[1]['score']['tuning'][0] = 63
        with self.assertRaisesRegex(ValueError, '定弦不同'):
            combine_scores(parts, [0], '合并')

    def test_actual_gp_roundtrip_preserves_notes_gaps_tempo_and_question_marks(self):
        data = combine_scores([part('A', 3, 88, [6, 8]), part('B', 5, 120, [3, 4], image=False), part('C', 7)], [1, 0], '拼接验证')
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source, target = folder / 'joined.json', folder / 'score.draft.gp'
            source.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
            run = subprocess.run(['node', str(ROOT / 'gp-draft-export.cjs'), str(source), str(target)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            review = json.loads(Path(str(target) + '.review.json').read_text(encoding='utf-8'))
            self.assertEqual(len(review['bars']), 4)
            self.assertEqual(review['note_count'], 13)
            self.assertEqual(review['bars'][0]['placeholder_beats'], [1, 2, 3, 4, 5, 6])
            self.assertEqual(review['bars'][1]['placeholder_beats'], [])
            script = folder / 'inspect.cjs'
            script.write_text("const a=require(process.argv[2]),fs=require('fs');const s=a.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(process.argv[3]));"
                              "console.log(JSON.stringify({title:s.title,bars:s.tracks[0].staves[0].bars.map(b=>b.voices[0].beats.map(v=>({notes:v.notes.map(n=>n.fret),text:v.text}))),"
                              "meters:s.masterBars.map(m=>[m.timeSignatureNumerator,m.timeSignatureDenominator]),tempos:s.masterBars.map(m=>m.tempoAutomations.map(a=>a.value))}));")
            run = subprocess.run(['node', str(script), str(ROOT.parents[1] / 'RiffLoop/Resources/GpWeb/alphaTab.min.js'), str(target)], capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(run.returncode, 0, run.stderr)
            actual = json.loads(run.stdout)
            self.assertEqual(actual['title'], '拼接验证')
            self.assertEqual(actual['meters'], [[6, 8], [6, 8], [3, 4], [4, 4]])
            self.assertEqual(actual['tempos'], [[88], [], [120], [100]])
            self.assertEqual([b[0]['notes'] for b in actual['bars']], [[3], [], [5], [7]])
            self.assertIn('?', actual['bars'][0][0]['text'])
            self.assertIn('空白分隔', actual['bars'][1][0]['text'])

    def test_failed_or_stopped_part_never_creates_partial_join(self):
        for stopped in (False, True):
            with self.subTest(stopped=stopped), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                stop = threading.Event()
                if stopped:
                    stop.set()
                with patch('desktop_join.process_file', return_value={'draft': None, 'message': '无法识别'}) as worker:
                    result = process_join([root/'a.png', root/'b.png'], [1], '合并', root/'out', {}, stop)
                self.assertIsNone(result['draft'])
                self.assertFalse((root/'out/score.draft.gp').exists())
                self.assertTrue((root/'out/review.html').exists())
                self.assertEqual(worker.call_count, 0 if stopped else 1)

    def test_existing_folder_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'score.draft.gp'
            target.write_bytes(b'user correction')
            with self.assertRaisesRegex(ValueError, '必须为空'):
                process_join([root/'a.png', root/'b.png'], [0], '合并', root, {})
            self.assertEqual(target.read_bytes(), b'user correction')

    def test_later_failure_or_stop_keeps_completed_part_without_partial_gp(self):
        for mode in ('failure', 'stop'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                stop = threading.Event()
                def worker(source, folder, settings):
                    folder.mkdir()
                    if source.name == 'b.png':
                        return {'draft': None, 'message': '第二份失败'}
                    (folder/'image-score.json').write_text(json.dumps(part('A', 3)['score']), encoding='utf-8')
                    (folder/'recognized.json').write_text('{"systems":[{}]}', encoding='utf-8')
                    (folder/'score.draft.gp').write_bytes(b'completed part')
                    if mode == 'stop':
                        stop.set()
                    return {'draft': str(folder/'score.draft.gp')}
                with patch('desktop_join.process_file', side_effect=worker):
                    result = process_join([root/'a.png', root/'b.png'], [0], '合并', root/'out', {}, stop)
                self.assertIsNone(result['draft'])
                self.assertFalse((root/'out/score.draft.gp').exists())
                self.assertEqual((root/'out/part-001/score.draft.gp').read_bytes(), b'completed part')
                self.assertIn('part-001/review.html', (root/'out/review.html').read_text(encoding='utf-8'))

    def test_dialog_reorders_sources_and_keeps_independent_gaps(self):
        import tkinter as tk
        from desktop_join_dialog import JoinDialog
        try:
            root = tk.Tk()
        except tk.TclError:
            self.skipTest('Tk display is unavailable')
        root.withdraw()
        self.addCleanup(root.destroy)
        submitted = []
        dialog = JoinDialog(root, [Path('a.png'), Path('b.png'), Path('c.png')],
                            lambda *args: submitted.append(args))
        dialog.gaps['0'].set('2')
        dialog.tree.selection_set('2')
        dialog.move(-1)
        dialog.move(-1)
        dialog.tree.selection_set('1')
        dialog.select()
        self.assertEqual(str(dialog.gap_input['state']), 'disabled')
        dialog.gaps['0'].set('-1')
        with patch('desktop_join_dialog.messagebox.showerror') as error:
            dialog.confirm()
            error.assert_called_once()
        self.assertFalse(submitted)
        dialog.gaps['0'].set('2')
        dialog.confirm()
        self.assertEqual(submitted[0][0], [Path('c.png'), Path('a.png'), Path('b.png')])
        self.assertEqual(submitted[0][1], [0, 2])


if __name__ == '__main__':
    unittest.main()

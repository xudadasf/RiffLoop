import copy
import json
from pathlib import Path
import tempfile
import unittest

from desktop_batch import write_report


class ReviewPageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.source = self.folder / '练习 & 长文件名.png'
        self.source.write_bytes(b'original')
        self.outcome = {'source': str(self.source), 'folder': str(self.folder),
                        'status': '待核对', 'message': 'test', 'draft': None}
        beat = {'duration': 4, 'dots': 0, 'tuplet': [1, 1], 'placeholder': False,
                'notes': [{'string': 6, 'fret': 5}]}
        system = {'id': 'p1-s1', 'page': 1, 'region': {'expected_bars': 1},
                  'notes': [{'bar': 1, 'string': 6, 'fret': 5, 'review': False}],
                  'unresolved': [], 'discarded_bands': [],
                  'rhythm_bars': [{'source_bar': 1, 'beats': [beat], 'issues': []}]}
        self.data = {'format': 'raster-digit-review-v1', 'manual_settings': {'tempo': 88, 'meter': [6, 8]},
                     'systems': [system], 'errors': []}

    def render(self):
        write_report(self.source, self.folder, self.outcome, self.data)
        return (self.folder / 'review.html').read_text(encoding='utf-8')

    def test_direct_gp_workflow_has_no_manual_review_step(self):
        report = self.render()
        self.assertIn('在 Guitar Pro 中打开 GP 草稿', report)
        self.assertNotIn('type="checkbox"', report)
        self.assertNotIn('localStorage', report)
        self.assertNotIn('已核对', report)
        self.assertNotIn('仅未核对', report)

    def test_labels_distinguish_same_bar_on_different_pages(self):
        second = copy.deepcopy(self.data['systems'][0])
        second.update(id='p2-s1', page=2)
        self.data['systems'].append(second)
        report = self.render()
        self.assertIn('第1页 · 第1行 · 小节1', report)
        self.assertIn('第2页 · 第1行 · 小节1', report)

    def test_placeholders_and_uncertain_notes_remain_flagged(self):
        self.assertIn('data-issue="0"', self.render())
        beat = self.data['systems'][0]['rhythm_bars'][0]['beats'][0]
        beat['placeholder'] = True
        self.assertIn('data-issue="1"', self.render())
        self.assertIn('1/4 ?', self.render())
        beat['placeholder'] = False
        self.data['systems'][0]['notes'][0]['review'] = True
        self.assertIn('data-issue="1"', self.render())

    def test_report_escapes_untrusted_messages(self):
        attack = '<script>alert("ocr")</script>'
        self.data['errors'] = [attack]
        self.outcome['message'] = attack
        report = self.render()
        self.assertNotIn(attack, report)
        self.assertIn('&lt;script&gt;', report)
        self.assertIn('练习 &amp; 长文件名.png', report)

    def test_missing_preview_and_missing_draft_have_no_broken_links(self):
        self.outcome['draft'] = str(self.folder / 'score.draft.gp')
        report = self.render()
        self.assertNotIn('href="score.draft.gp"', report)
        self.assertNotIn('data-preview="', report)
        self.assertIn('尚未生成 GP', report)

    def test_report_never_changes_source_gp_or_recognition(self):
        gp = self.folder / 'score.draft.gp'
        gp.write_bytes(b'manually edited GP')
        recognized = self.folder / 'recognized.json'
        recognized.write_text(json.dumps(self.data), encoding='utf-8')
        before = recognized.read_bytes()
        original_data = copy.deepcopy(self.data)
        self.outcome['draft'] = str(gp)
        self.assertIn('href="score.draft.gp"', self.render())
        self.assertEqual(gp.read_bytes(), b'manually edited GP')
        self.assertEqual(self.source.read_bytes(), b'original')
        self.assertEqual(recognized.read_bytes(), before)
        self.assertEqual(self.data, original_data)

    def test_vector_tuplets_and_grouped_notes_remain_visible(self):
        self.data = {'systems': [{'page': 1, 'bars': [{'number': 2, 'issues': ['待检查'],
                     'beats': [{'duration': 8, 'dots': 1, 'tuplet': [3, 2],
                                'notes': [{'string': 2, 'fret': 5}, {'string': 1, 'fret': 7}]}]}]}]}
        report = self.render()
        self.assertIn('2弦/5品 + 1弦/7品', report)
        self.assertIn('1/8.（3连音）', report)
        self.assertIn('data-issue="1"', report)
        self.assertIn('第1页 · 第1行 · 小节2', report)


if __name__ == '__main__':
    unittest.main()

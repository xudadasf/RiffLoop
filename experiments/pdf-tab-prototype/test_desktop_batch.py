import json
from pathlib import Path
import tempfile
import unittest

import fitz
from desktop_batch import create_output, process_file


class DesktopBatchTests(unittest.TestCase):
    def test_same_name_and_repeated_runs_keep_separate_results(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = create_output(root, 'a/同名谱.pdf')
            second = create_output(root, 'b/同名谱.pdf')
            third = create_output(root, 'a/同名谱.pdf')
            self.assertEqual(len({first, second, third}), 3)
            self.assertTrue(all(p.parent == root for p in (first, second, third)))

    def test_blank_image_is_not_reported_as_conversion_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / '截图.png'
            pixmap = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 200, 200))
            pixmap.clear_with(255)
            pixmap.save(source)
            result = process_file(source, root / 'out')
            self.assertEqual(result['status'], '未生成草稿')
            self.assertIn('没有可靠定位到六条谱线', result['message'])
            self.assertIsNone(result['draft'])
            self.assertTrue((root / 'out/review.html').exists())

    def test_mixed_scan_document_is_not_partially_exported(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'mixed.pdf'
            with fitz.open() as doc:
                doc.new_page().draw_line((10, 10), (400, 10))
                pixmap = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 20, 20))
                pixmap.clear_with(255)
                doc.new_page().insert_image(fitz.Rect(0, 0, 300, 300), pixmap=pixmap)
                doc.save(source)
            result = process_file(source, root / 'out')
            self.assertEqual(result['status'], '未生成草稿')
            self.assertIn('第 2 页', result['message'])
            self.assertFalse((root / 'out/score.draft.gp').exists())

    def test_failed_file_does_not_prevent_next_file_report(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bad = root / 'broken.pdf'
            bad.write_text('not a PDF')
            plain = root / '普通 & PDF.pdf'
            with fitz.open() as doc:
                doc.new_page().insert_text((30, 30), 'No music on this page')
                doc.save(plain)
            first = process_file(bad, root / 'bad')
            second = process_file(plain, root / 'plain')
            self.assertEqual(first['status'], '处理失败')
            self.assertEqual(second['status'], '未生成草稿')
            self.assertIn('没有识别到', second['message'])
            self.assertIn('&amp;', (root / 'plain/review.html').read_text(encoding='utf-8'))
            self.assertEqual(json.loads((root / 'bad/result.json').read_text(encoding='utf-8'))['draft'], None)

    def test_existing_results_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            previous = root / 'score.draft.gp'
            previous.write_bytes(b'previous result')
            with self.assertRaisesRegex(ValueError, '必须为空'):
                process_file(root / 'missing.pdf', root)
            self.assertEqual(previous.read_bytes(), b'previous result')


if __name__ == '__main__':
    unittest.main()

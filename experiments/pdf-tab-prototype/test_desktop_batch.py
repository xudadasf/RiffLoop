import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fitz
from desktop_batch import create_output, process_file


class DesktopBatchTests(unittest.TestCase):
    def test_missing_digit_runtime_does_not_fall_back_to_old_model(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'image.png'
            Image.new('L', (200, 200), 255).save(source)
            with patch('desktop_image_review.locate_systems', return_value=[{}]), \
                 patch.dict(os.environ, RIFFLOOP_DIGIT_PYTHON=str(root / 'missing.exe')), \
                 patch('raster_tab.recognize_raster') as old_model, patch('subprocess.run') as run:
                result = process_file(source, root / 'out')
            self.assertEqual(result['status'], '处理失败')
            self.assertIn('未回退到旧模型', result['message'])
            self.assertIsNone(result['draft'])
            old_model.assert_not_called()
            run.assert_not_called()
            self.assertFalse((root / 'out/score.draft.gp').exists())

    def test_image_entry_uses_digit_review_and_never_calls_gp_export(self):
        from PIL import Image
        import cv2
        import numpy as np
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'exercise.png'
            image = np.full((360, 1000), 255, np.uint8)
            for y in range(120, 201, 16):
                cv2.line(image, (50, y), (950, y), 0, 1)
            for x in (50, 350, 650, 950):
                cv2.line(image, (x, 120), (x, 200), 0, 1)
            Image.fromarray(image).save(source)
            def worker(command, **kwargs):
                self.assertEqual(Path(command[1]).name, 'raster_digit_probe.py')
                output = Path(command[command.index('--output') + 1])
                output.mkdir()
                (output / 'prediction.json').write_text(json.dumps({
                    'errors': [], 'systems': [{'id': 'p1-s1', 'page': 1,
                                               'notes': [{'bar': 1, 'string': 6, 'fret': 5, 'review': False}],
                                               'unresolved': [], 'region': {'expected_bars': 4}}]
                }), encoding='utf-8')
                (output / 'review.html').write_text('digit review', encoding='utf-8')
                return __import__('subprocess').CompletedProcess(command, 0, 'ok', '')
            for name in ('python.exe', 'PP-OCRv6_det_small.onnx', 'PP-OCRv6_rec_small.onnx'):
                (root / name).touch()
            with patch.dict(os.environ, RIFFLOOP_DIGIT_PYTHON=str(root / 'python.exe'), RIFFLOOP_DIGIT_MODELS=str(root)), patch('subprocess.run', side_effect=worker) as run:
                result = process_file(source, root / 'out', {'tempo': 88, 'meter': [6, 8]})
            self.assertEqual(run.call_count, 1)
            self.assertEqual(result['status'], '图片音符对照 · 未生成 GP')
            self.assertIsNone(result['draft'])
            self.assertFalse((root / 'out/score.draft.gp').exists())
            report = (root / 'out/review.html').read_text(encoding='utf-8')
            self.assertIn('digit-ocr/review.html', report)
            self.assertIn('节奏尚未识别', report)
            self.assertIn('BPM 88 · 拍号 6/8', report)
            saved = json.loads((root / 'out/recognized.json').read_text(encoding='utf-8'))
            self.assertEqual(saved['manual_settings']['tempo'], 88)
            self.assertEqual(saved['manual_settings']['meter'], [6, 8])

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
            report = (root / 'out/review.html').read_text(encoding='utf-8')
            self.assertIn('BPM 100 · 拍号 4/4', report)

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

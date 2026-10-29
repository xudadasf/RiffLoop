import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import cv2
import fitz
import numpy as np

from textbook_regions import extract_regions, locate_regions
from desktop_cleanup import clean_intermediates


def draw_pair(gray, top, left=60, right=940):
    for first, count, gap in [(top, 5, 8), (top+100, 6, 10)]:
        for i in range(count):
            cv2.line(gray, (left, first+i*gap), (right, first+i*gap), 0, 1)
        for x in (left, (left+right)//2, right):
            cv2.line(gray, (x, first), (x, first+(count-1)*gap), 0, 1)


class RegionTests(unittest.TestCase):
    def test_music_bounds_include_notation_and_tab(self):
        gray = np.full((600, 1000), 255, np.uint8)
        draw_pair(gray, 130)
        regions = [r for r in locate_regions(gray)['regions'] if r['accepted']]
        self.assertEqual(len(regions), 1)
        x0,y0,x1,y1 = regions[0]['box']
        self.assertLessEqual(y0, 100)
        self.assertGreaterEqual(y1, 300)
        self.assertLessEqual(x0, 60)
        self.assertGreaterEqual(x1, 940)

    def test_fretboard_is_candidate_not_auto_recognized(self):
        gray = np.full((400, 1000), 255, np.uint8)
        for y in range(120, 201, 16):
            cv2.line(gray, (50,y), (950,y), 0, 1)
        for x in range(50, 951, 100):
            cv2.line(gray, (x,120), (x,200), 0, 1)
        result = locate_regions(gray)
        self.assertTrue(result['regions'])
        self.assertFalse(any(r['accepted'] for r in result['regions']))

    def test_continuous_lines_merge_but_heading_separates_exercises(self):
        for heading, expected in [(False, 1), (True, 2)]:
            gray = np.full((750, 1000), 255, np.uint8)
            draw_pair(gray, 100)
            draw_pair(gray, 420)
            if heading:
                cv2.putText(gray, 'NEXT EXERCISE', (70, 330), cv2.FONT_HERSHEY_SIMPLEX, 1.5, 0, 3)
            regions = [r for r in locate_regions(gray)['regions'] if r['accepted']]
            self.assertEqual(len(regions), expected)
            self.assertEqual(sum(r['systems'] for r in regions), 2)

    def test_two_stacked_fretboards_are_not_a_notation_tab_pair(self):
        gray = np.full((600, 1000), 255, np.uint8)
        for top in (100, 240):
            for y in range(top, top+51, 10):
                cv2.line(gray, (60,y), (940,y), 0, 1)
            for x in range(60,941,110):
                cv2.line(gray, (x,top), (x,top+50), 0, 1)
        self.assertFalse(any(r['accepted'] for r in locate_regions(gray)['regions']))

    def test_dark_illustration_is_not_auto_adopted(self):
        gray = np.full((600, 1000), 255, np.uint8)
        draw_pair(gray, 130)
        gray[70:400,40:960] = 255-gray[70:400,40:960]
        self.assertFalse(any(r['accepted'] for r in locate_regions(gray)['regions']))

    def test_partial_width_detection_cannot_enter_recognition(self):
        gray = np.full((600, 1000), 255, np.uint8)
        draw_pair(gray, 130)
        partial = {'ys': [230,240,250,260,270,280], 'left': 60, 'right': 700}
        with patch('textbook_regions.locate_systems', side_effect=[[partial]] + [[]]*100):
            regions = locate_regions(gray)['regions']
        self.assertEqual(len(regions), 1)
        self.assertFalse(regions[0]['accepted'])
        self.assertIn('截断', regions[0]['reason'])

    def test_columns_are_separate_and_read_left_to_right(self):
        gray = np.full((600, 1400), 255, np.uint8)
        draw_pair(gray, 130, 50, 650)
        draw_pair(gray, 130, 780, 1370)
        regions = [r for r in locate_regions(gray)['regions'] if r['accepted']]
        self.assertEqual(len(regions), 2)
        self.assertLess(regions[0]['box'][2], regions[1]['box'][0])

    def test_long_pdf_all_pages_recorded_and_source_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root/'mixed.pdf'
            with fitz.open() as doc:
                for _ in range(41):
                    doc.new_page(width=150, height=150)
                doc.save(source)
            before = source.read_bytes()
            result = extract_regions(source, root/'out')
            manifest = json.loads((root/'out/regions.json').read_text(encoding='utf-8'))
            self.assertTrue(manifest['complete'])
            self.assertEqual(len(manifest['pages']), 41)
            self.assertEqual(manifest['default_gap'], 1)
            self.assertEqual(result['region_sources'], [])
            self.assertEqual(source.read_bytes(), before)
            self.assertIn('PDF 第 41 页', (root/'out/review.html').read_text(encoding='utf-8'))
            with self.assertRaisesRegex(ValueError, '输入文件'):
                clean_intermediates(root/'out')

    def test_cancel_does_not_enqueue_partial_book_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with fitz.open() as doc:
                doc.new_page()
                doc.save(root/'a.pdf')
            stop = threading.Event()
            stop.set()
            result = extract_regions(root/'a.pdf', root/'out', stop)
            self.assertEqual(result['region_sources'], [])
            self.assertEqual(result['status'], '分区未完成')
            with self.assertRaisesRegex(ValueError, '必须为空'):
                extract_regions(root/'a.pdf', root/'out')


if __name__ == '__main__':
    unittest.main()

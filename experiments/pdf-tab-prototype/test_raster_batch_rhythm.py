"""Opt-in rhythm regression against frozen OCR outputs and annotated images."""
import hashlib
import json
import os
from pathlib import Path
import unittest

from raster_beam_rhythm import read_beamed_notes
from raster_image_quality import condition_page
from raster_tab import deskew, raster_pages


ROOT = Path(__file__).resolve().parent
TRUTH = {
    '1': [[16]*16 for _ in range(4)],
    '1.1': [[8]*8 for _ in range(4)],
    # The final dotted quarter cannot be represented by this beam-only reader.
    '1.2': [[8]*8 for _ in range(3)] + [[8, 8, 8, 8, 8, None]],
    '1.3': [[16]*16 for _ in range(4)],
}


class RasterBatchRhythmTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('RIFFLOOP_RASTER_CORPUS'), 'set RIFFLOOP_RASTER_CORPUS to run frozen image regression')
    def test_all_confirmed_rhythms_remain_correct(self):
        root = Path(os.environ['RIFFLOOP_RASTER_CORPUS'])
        fixture = json.loads((ROOT/'fixtures/raster-rhythm-20261105.json').read_text(encoding='utf-8'))
        for case in fixture['cases']:
            with self.subTest(case=case['id']):
                name = case['id']
                image = root/'inputs'/(name+'.png')
                prediction = root/(name+'.prediction.json')
                self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(), case['image_sha256'])
                self.assertEqual(hashlib.sha256(prediction.read_bytes()).hexdigest(), case['prediction_sha256'])
                data = json.loads(prediction.read_text(encoding='utf-8'))
                self.assertEqual(len(data['systems']), 1)
                system = data['systems'][0]
                page = next(raster_pages(image))
                page, _ = condition_page(page)
                page, _ = deskew(page)
                region = system['region']
                x0, y0, x1, y1 = region['crop']
                readings = read_beamed_notes(page[y0:y1, x0:x1], system['notes'], region)
                self.assertEqual(len(readings), len(case['accepted']))
                counts = {}
                expected_bars = TRUTH[name.split('-')[0]]
                for note, reading, accepted in zip(system['notes'], readings, case['accepted']):
                    bar = note['bar']
                    counts[bar] = counts.get(bar, 0) + 1
                    expected = expected_bars[bar-1][counts[bar]-1]
                    actual = reading['duration']
                    if actual is not None:
                        self.assertEqual(actual, expected, f'{name} bar {bar} note {counts[bar]}')
                    if accepted is not None:
                        self.assertEqual(actual, accepted, f'{name} lost accepted bar {bar} note {counts[bar]}')
                self.assertEqual([counts.get(i, 0) for i in range(1, 5)], list(map(len, expected_bars)))


if __name__ == '__main__':
    unittest.main()

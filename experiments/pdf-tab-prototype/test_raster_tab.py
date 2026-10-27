import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import cv2
import numpy as np
from PIL import Image

from raster_tab import decode_proposal, deskew, gray_image, locate_systems, recognize_raster, validate_settings


def staff(count=6):
    gray = np.full((360, 1000), 255, np.uint8)
    for i in range(count):
        cv2.line(gray, (50, 120 + i * 16), (950, 120 + i * 16), 0, 1)
    for x in (50, 350, 650, 950):
        cv2.line(gray, (x, 120), (x, 120 + (count - 1) * 16), 0, 1)
    for x in (150, 450, 750):
        cv2.rectangle(gray, (x - 7, 142), (x + 8, 163), 255, -1)
        cv2.putText(gray, '7', (x - 6, 159), cv2.FONT_HERSHEY_SIMPLEX, .6, 0, 1)
    return gray


class RasterTabTests(unittest.TestCase):
    def test_detects_six_lines_and_measures_without_pdf_geometry(self):
        systems = locate_systems(staff())
        self.assertEqual(len(systems), 1)
        self.assertEqual(systems[0]['ys'], [120, 136, 152, 168, 184, 200])
        self.assertEqual(systems[0]['expected_bars'], 3)

    def test_five_line_staff_and_seven_line_grid_are_not_six_string_tab(self):
        for count in (5, 7):
            with self.subTest(count=count):
                self.assertEqual(locate_systems(staff(count)), [])

    def test_rotation_is_corrected_and_lines_are_recovered(self):
        original = staff()
        for angle in (-3, 2.5):
            transform = cv2.getRotationMatrix2D((500, 180), angle, 1)
            tilted = cv2.warpAffine(original, transform, (1000, 360), borderValue=255)
            corrected, correction = deskew(tilted)
            self.assertAlmostEqual(abs(correction), abs(angle), delta=.25)
            systems = locate_systems(corrected)
            self.assertEqual(len(systems), 1)
            self.assertEqual(systems[0]['expected_bars'], 3)

    def test_dark_background_and_transparency_are_normalized(self):
        gray = gray_image(Image.fromarray(255 - staff()))
        self.assertEqual(len(locate_systems(gray)), 1)
        transparent = Image.new('RGBA', (200, 200), (0, 0, 0, 0))
        self.assertEqual(int(gray_image(transparent).min()), 255)

    def test_parallel_columns_are_not_joined(self):
        gray = staff()
        gray[:, 450:600] = 255
        with self.assertRaisesRegex(ValueError, '并排谱区'):
            locate_systems(gray)

    def test_double_barline_is_one_boundary(self):
        gray = staff()
        cv2.line(gray, (356, 120), (356, 200), 0, 1)
        self.assertEqual(locate_systems(gray)[0]['expected_bars'], 3)

    def test_final_double_barline_does_not_create_tiny_extra_measure(self):
        gray = staff()
        cv2.line(gray, (941, 120), (941, 200), 0, 1)
        self.assertEqual(locate_systems(gray)[0]['expected_bars'], 3)

    def test_full_height_note_stems_are_not_bar_boundaries(self):
        gray = staff()
        cv2.line(gray, (250, 120), (250, 230), 0, 1)
        cv2.line(gray, (550, 126), (550, 230), 0, 1)
        self.assertEqual(locate_systems(gray)[0]['expected_bars'], 3)

    def test_model_notes_preserved_but_rhythm_never_accepted(self):
        prediction = {'eos': True, 'upstream_structure_valid': True,
                      'tokens': 'BAR BEAT DUR_8 DOTS_1 N_S6_F12 NTECH_TIE_DEST N_S2_FX BEAT DUR_2 REST END_BAR'.split()}
        bars = decode_proposal(prediction)
        self.assertEqual([(n['string'], n['fret']) for n in bars[0][0]['notes']], [(1, 12), (5, None)])
        self.assertTrue(bars[0][0]['notes'][1]['dead'])
        self.assertTrue(all(b['duration'] is None for b in bars[0]))
        self.assertEqual(bars[0][0]['dots'], 0)
        self.assertFalse(bars[0][0]['notes'][0]['tie'])
        for invalid in (dict(prediction, eos=False), dict(prediction, upstream_structure_valid=False),
                        dict(prediction, tokens='BAR BEAT DUR_4 N_S1_F80 END_BAR'.split())):
            with self.assertRaises(ValueError):
                decode_proposal(invalid)

    def test_legacy_probe_preserves_actual_proposal_with_geometry_warning(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'three-measure-image.png'
            Image.fromarray(staff()).save(source)
            model = root / 'model'
            (model / '.venv/Scripts').mkdir(parents=True)
            (model / '.venv/Scripts/python.exe').touch()
            (model / 'best.pt').touch()
            original_run = subprocess.run

            def fake_model_only(command, **kwargs):
                if str(command[0]) != str(model / '.venv/Scripts/python.exe'):
                    return original_run(command, **kwargs)
                manifest = json.loads(Path(command[command.index('--manifest') + 1]).read_text())
                prediction = {'id': manifest[0]['id'], 'eos': True, 'upstream_structure_valid': True,
                              'tokens': ('BAR BEAT DUR_8 N_S6_F7 END_BAR BAR BEAT DUR_4 N_S5_F9 END_BAR').split()}
                Path(command[command.index('--output') + 1]).write_text(json.dumps({
                    'model_revision': 'test', 'checkpoint_sha256': 'test', 'predictions': [prediction]}))
                return subprocess.CompletedProcess(command, 0)

            with patch.dict('os.environ', {'RIFFLOOP_OMR_MODEL_DIR': str(model)}), patch('raster_tab.subprocess.run', side_effect=fake_model_only):
                (root / 'out').mkdir()
                data = recognize_raster(source, root / 'out')
            self.assertEqual(len(data['systems'][0]['bars']), 2)
            self.assertEqual(data['structure_issues'], [])
            self.assertTrue(any('数量' in w for w in data['warnings']))
            self.assertTrue(all(any('数量' in w for w in b['issues']) for b in data['systems'][0]['bars']))
            self.assertFalse((root / 'out/score.draft.gp').exists())

    def test_missing_model_retains_crops_and_does_not_guess_notes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source.png'
            Image.fromarray(staff()).save(source)
            out = root / 'out'
            out.mkdir()
            with patch.dict('os.environ', {'RIFFLOOP_OMR_MODEL_DIR': str(root / 'absent')}):
                result = recognize_raster(source, out)
            self.assertEqual(result['systems'], [])
            self.assertTrue(result['structure_issues'])
            self.assertEqual(len(result['raster_regions']), 1)
            self.assertTrue((out / result['raster_regions'][0]['image']).is_file())
            self.assertEqual(set(json.loads((out / 'image-manifest.json').read_text())[0]), {'id', 'image'})

    def test_settings_are_explicit_and_validated(self):
        result = validate_settings({'tempo': 88, 'meter': [6, 8], 'tuning': [64, 59, 55, 50, 45, 38]})
        self.assertEqual(result['tempo'], 88)
        for key, invalid in [('tempo', 0), ('tempo', True), ('meter', [4, 3]), ('meter', [0, 4]),
                             ('tuning', [64] * 5), ('tuning', [128] * 6)]:
            with self.subTest(key=key, invalid=invalid), self.assertRaises(ValueError):
                validate_settings(dict(result, **{key: invalid}))


if __name__ == '__main__':
    unittest.main()

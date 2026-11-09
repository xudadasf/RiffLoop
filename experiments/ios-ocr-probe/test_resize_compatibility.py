import hashlib
import json
import unittest
from pathlib import Path

import cv2
import numpy as np

from compare_band_resize import approximate_tensor, resize_gray
from image_reference import generated_band


class ResizeCompatibilityTests(unittest.TestCase):
    def test_fixed_point_resize_matches_opencv_on_generated_pixels(self):
        random = np.random.default_rng(20261109)
        sizes = [(1, 1, 1, 1), (1, 8, 17, 31), (8, 1, 31, 17), (64, 128, 32, 64)]
        sizes += [tuple(int(value) for value in (
            random.integers(1, 80), random.integers(1, 220),
            random.integers(1, 90), random.integers(1, 260))) for _ in range(128)]
        for height, width, target_height, target_width in sizes:
            with self.subTest(size=(height, width, target_height, target_width)):
                source = random.integers(0, 256, size=(height, width), dtype=np.uint8)
                expected = cv2.resize(cv2.cvtColor(source, cv2.COLOR_GRAY2BGR),
                                      (target_width, target_height), interpolation=cv2.INTER_LINEAR)[:, :, 0]
                actual = resize_gray(source, target_width, target_height, "opencv_scalar")
                np.testing.assert_array_equal(actual, expected)

    def test_complete_synthetic_tensors_match_the_desktop_fixture(self):
        path = Path(__file__).with_name("image_reference_expected.json")
        cases = json.loads(path.read_text(encoding="utf-8"))["cases"]
        for case in cases:
            with self.subTest(width=case["source_width"], height=case["source_height"]):
                source = generated_band(case["source_width"], case["source_height"])
                tensor = approximate_tensor(source, "opencv_scalar")
                self.assertEqual(list(tensor.shape), case["tensor_shape"])
                actual_hash = hashlib.sha256(tensor.astype("<f4", copy=False).tobytes()).hexdigest()
                self.assertEqual(actual_hash, case["tensor_sha256"])


if __name__ == "__main__":
    unittest.main()

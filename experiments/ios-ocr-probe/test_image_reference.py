import base64
import hashlib
import json
import unittest
from pathlib import Path

from image_reference import generated_band


class ImageReferenceTests(unittest.TestCase):
    def test_frozen_samples_have_expected_source_and_shapes(self):
        path = Path(__file__).with_name("image_reference_expected.json")
        data = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(data["rapidocr_version"], "3.10.0")
        self.assertEqual([case["source_width"] for case in data["cases"]], [200, 560])
        for case in data["cases"]:
            source = generated_band(case["source_width"])
            self.assertEqual(source.shape, (case["source_height"], case["source_width"]))
            self.assertEqual(hashlib.sha256(source.tobytes()).hexdigest(), case["source_sha256"])
            gray = base64.b64decode(case["resized_gray_base64"], validate=True)
            self.assertEqual(len(gray), 48 * case["effective_width"])
            self.assertEqual(case["tensor_shape"][:3], [1, 3, 48])
            self.assertGreaterEqual(case["tensor_shape"][3], case["effective_width"])
            self.assertEqual(case["output_shape"][0], 1)
            self.assertEqual(case["output_shape"][2], 18710)
            self.assertEqual(len(case["argmax"]), case["output_shape"][1])
            self.assertEqual(len(case["argmax_scores"]), case["output_shape"][1])

    def test_unfrozen_source_width_is_rejected(self):
        with self.assertRaises(ValueError):
            generated_band(201)


if __name__ == "__main__":
    unittest.main()

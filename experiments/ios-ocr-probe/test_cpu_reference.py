import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

import cpu_reference
from cpu_reference import GLYPH_SHA256, INPUT_SHA256, INPUT_SHAPE, ctc_runs, file_sha256, glyph_input, synthetic_input


class CpuReferenceTests(unittest.TestCase):
    def test_input_is_exact_and_has_frozen_bytes(self):
        result = synthetic_input()
        self.assertEqual(result.shape, INPUT_SHAPE)
        self.assertEqual(result.dtype, np.float32)
        np.testing.assert_array_equal(result.ravel()[:8], [-0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, -0.75])
        self.assertEqual(hashlib.sha256(result.astype("<f4", copy=False).tobytes()).hexdigest(), INPUT_SHA256)

    def test_glyph_input_is_frozen_and_identical_across_channels(self):
        result = glyph_input()
        self.assertEqual(result.shape, INPUT_SHAPE)
        self.assertEqual(result.dtype, np.float32)
        np.testing.assert_array_equal(result[0, 0], result[0, 1])
        np.testing.assert_array_equal(result[0, 0], result[0, 2])
        self.assertEqual(set(np.unique(result)), {-1.0, 1.0})
        self.assertEqual(hashlib.sha256(result.astype("<f4", copy=False).tobytes()).hexdigest(), GLYPH_SHA256)

    def test_ctc_keeps_repeated_digit_if_blank_separates_it(self):
        self.assertEqual(ctc_runs([0, 34, 34, 0, 34, 35, 35, 0]), [
            {"class": 34, "start": 1, "end": 2},
            {"class": 34, "start": 4, "end": 4},
            {"class": 35, "start": 5, "end": 6},
        ])
        self.assertEqual(ctc_runs([0, 0, 0]), [])

    def test_file_hash_reads_the_file_without_writing_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            source.write_bytes(b"synthetic")
            self.assertEqual(file_sha256(source), hashlib.sha256(b"synthetic").hexdigest())
            self.assertEqual(source.read_bytes(), b"synthetic")

    def test_output_paths_never_overwrite_model_existing_files_or_each_other(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "model.onnx"
            source.write_bytes(b"model")
            output = Path(temporary) / "existing.json"
            output.write_bytes(b"existing")
            fresh = Path(temporary) / "fresh.json"
            cases = [
                ["--output", str(source)],
                ["--output", str(output), "--alphabet-output", str(fresh)],
                ["--output", str(fresh), "--alphabet-output", str(fresh)],
            ]
            for arguments in cases:
                with self.subTest(arguments=arguments), patch("sys.argv", ["cpu_reference.py", "--model", str(source), *arguments]), \
                        patch.object(cpu_reference, "measure") as measure:
                    with self.assertRaises((ValueError, FileExistsError)):
                        cpu_reference.main()
                    measure.assert_not_called()
            self.assertEqual(source.read_bytes(), b"model")
            self.assertEqual(output.read_bytes(), b"existing")
            self.assertFalse(fresh.exists())


if __name__ == "__main__":
    unittest.main()

"""Freeze RapidOCR preprocessing of generated string bands; no user image is read."""

import base64
import hashlib
import importlib.metadata
import json
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from rapidocr import RapidOCR

from cpu_reference import GLYPHS, MODEL_SHA256, file_sha256


def generated_band(width, height=40):
    if (width, height) not in ((200, 40), (560, 40), (200, 20), (531, 20)):
        raise ValueError("Only the frozen synthetic cases are supported")
    image = np.full((height, width), 255, dtype=np.uint8)
    image[height // 2, :] = 140
    step = 19 if width == 200 else (55 if width == 560 else 52)
    scale = 3 if height == 40 else 2
    top = 9 if height == 40 else 3
    for number, glyph in enumerate(GLYPHS):
        for row, line in enumerate(glyph.split("/")):
            for column, bit in enumerate(line):
                if bit == "1":
                    x, y = 4 + number * step + column * scale, top + row * scale
                    image[y:y + scale, x:x + scale] = 0
    return image


def measure(model_path):
    model = Path(model_path).resolve(strict=True)
    if file_sha256(model) != MODEL_SHA256:
        raise ValueError("Model does not match the frozen reference")
    engine = RapidOCR(params={"Global.model_root_dir": str(model.parent),
                              "Global.log_level": "warning",
                              "EngineConfig.onnxruntime.intra_op_num_threads": 1,
                              "EngineConfig.onnxruntime.inter_op_num_threads": 1})
    recognizer = engine._load_rec_model()
    session = ort.InferenceSession(str(model), providers=["CPUExecutionProvider"])
    results = []
    for width, source_height in ((200, 40), (560, 40), (200, 20), (531, 20)):
        gray = generated_band(width, source_height)
        # Exact desktop path: LoadImage -> RapidOCR.preprocess_img -> recognizer.
        loaded = engine.load_img(gray)
        image, transforms = engine.preprocess_img(loaded)
        height, image_width = image.shape[:2]
        ratio = max(320 / 48, image_width / height)
        tensor = recognizer.resize_norm_img(image, ratio)[np.newaxis, :]
        output = session.run(None, {"x": tensor})[0]
        argmax = np.argmax(output[0], axis=-1).tolist()
        # All three channels are identical for a gray input; store one full
        # channel as uint8 rather than an unnecessarily large float fixture.
        effective_width = min(tensor.shape[3], int(np.ceil(48 * image_width / height)))
        gray_resized = np.rint((tensor[0, 0, :, :effective_width] + 1) * np.float32(127.5)).astype(np.uint8)
        if not (np.array_equal(tensor[0, 0], tensor[0, 1]) and
                np.array_equal(tensor[0, 0], tensor[0, 2]) and
                np.all(tensor[0, :, :, effective_width:] == 0)):
            raise RuntimeError("Unexpected channel or padding behavior")
        reconstructed = (gray_resized.astype(np.float32) / np.float32(255) - np.float32(0.5)) / np.float32(0.5)
        if not np.array_equal(reconstructed, tensor[0, 0, :, :effective_width]):
            raise RuntimeError("Stored grayscale would not reconstruct the desktop tensor")
        results.append({
            "source_width": width,
            "source_height": source_height,
            "source_sha256": hashlib.sha256(gray.tobytes()).hexdigest(),
            "post_bounds_shape": list(image.shape),
            "preprocess_ratios": transforms["preprocess"],
            "tensor_shape": list(tensor.shape),
            "effective_width": effective_width,
            "tensor_sha256": hashlib.sha256(tensor.astype("<f4", copy=False).tobytes()).hexdigest(),
            "resized_gray_base64": base64.b64encode(gray_resized.tobytes()).decode("ascii"),
            "output_shape": list(output.shape),
            "argmax": argmax,
            "argmax_scores": [float(output[0, t, c]) for t, c in enumerate(argmax)],
        })
    return {"scope": "Generated images only; desktop production preprocessing, not real-score accuracy",
            "model_sha256": MODEL_SHA256,
            "rapidocr_version": importlib.metadata.version("rapidocr"),
            "onnxruntime_version": ort.__version__, "cases": results}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: image_reference.py /path/to/PP-OCRv6_rec_small.onnx")
    print(json.dumps(measure(sys.argv[1]), ensure_ascii=False, separators=(",", ":")))

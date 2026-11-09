"""Compare desktop OpenCV with an experimental resize, locally and read-only.

Inputs are existing desktop digit-ocr result folders. Only aggregate counts are
printed; user score images and recognized text are not copied or uploaded.
"""

import argparse
import collections
import json
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
from rapidocr import RapidOCR

from cpu_reference import MODEL_SHA256, ctc_runs, file_sha256


def resize_gray(image, width, height, method="bilinear"):
    if method in ("opencv_linear", "opencv_exact", "opencv_noipp", "opencv_noopt"):
        interpolation = cv2.INTER_LINEAR if method == "opencv_linear" else cv2.INTER_LINEAR_EXACT
        if method in ("opencv_noipp", "opencv_noopt"):
            interpolation = cv2.INTER_LINEAR
        # The desktop recognizer first expands gray to three BGR channels.
        color = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
        if method == "opencv_noipp":
            previous = cv2.ipp.useIPP()
            try:
                cv2.ipp.setUseIPP(False)
                return cv2.resize(color, (width, height), interpolation=interpolation)[:, :, 0]
            finally:
                cv2.ipp.setUseIPP(previous)
        if method == "opencv_noopt":
            previous = cv2.useOptimized()
            try:
                cv2.setUseOptimized(False)
                return cv2.resize(color, (width, height), interpolation=interpolation)[:, :, 0]
            finally:
                cv2.setUseOptimized(previous)
        return cv2.resize(color, (width, height), interpolation=interpolation)[:, :, 0]
    if method == "opencv_scalar":
        # Experimental transcription of OpenCV 4.13's 8-bit INTER_LINEAR
        # fixed-point path; terms in OPENCV_RESIZE_LICENSE.txt.
        sh, sw = image.shape
        fx = ((np.arange(width, dtype=np.float64) + 0.5) * (sw / width) - 0.5).astype(np.float32)
        fy = ((np.arange(height, dtype=np.float64) + 0.5) * (sh / height) - 0.5).astype(np.float32)
        sx, sy = np.floor(fx).astype(int), np.floor(fy).astype(int)
        fx -= sx.astype(np.float32)
        fy -= sy.astype(np.float32)
        fx[(sx < 0) | (sx >= sw - 1)] = 0
        sx1 = np.clip(sx + 1, 0, sw - 1)
        sy1 = np.clip(sy + 1, 0, sh - 1)
        sx, sy = np.clip(sx, 0, sw - 1), np.clip(sy, 0, sh - 1)
        scale = np.float32(2048)
        a0 = np.rint((np.float32(1) - fx) * scale).astype(np.int64)
        a1 = np.rint(fx * scale).astype(np.int64)
        b0 = np.rint((np.float32(1) - fy) * scale).astype(np.int64)
        b1 = np.rint(fy * scale).astype(np.int64)
        a = image[sy[:, None], sx[None, :]].astype(np.int64)
        b = image[sy[:, None], sx1[None, :]].astype(np.int64)
        c = image[sy1[:, None], sx[None, :]].astype(np.int64)
        d = image[sy1[:, None], sx1[None, :]].astype(np.int64)
        upper, lower = a * a0 + b * a1, c * a0 + d * a1
        return ((((b0[:, None] * (upper >> 4)) >> 16) +
                 ((b1[:, None] * (lower >> 4)) >> 16) + 2) >> 2).clip(0, 255).astype(np.uint8)
    source_height, source_width = image.shape
    x = (np.arange(width) + 0.5) * source_width / width - 0.5
    y = (np.arange(height) + 0.5) * source_height / height - 0.5
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    dx, dy = x - x0, y - y0
    x1 = np.clip(x0 + 1, 0, source_width - 1)
    y1 = np.clip(y0 + 1, 0, source_height - 1)
    x0, y0 = np.clip(x0, 0, source_width - 1), np.clip(y0, 0, source_height - 1)
    a = image[y0[:, None], x0[None, :]].astype(float)
    b = image[y0[:, None], x1[None, :]].astype(float)
    c = image[y1[:, None], x0[None, :]].astype(float)
    d = image[y1[:, None], x1[None, :]].astype(float)
    values = (a * (1 - dx) + b * dx) * (1 - dy[:, None]) + (c * (1 - dx) + d * dx) * dy[:, None]
    return np.rint(values).clip(0, 255).astype(np.uint8)


def approximate_tensor(gray, method="bilinear"):
    # Mirrors the experimental Swift sampler; the bounds-resize stage is a
    # simulation only and is not yet implemented in the iPad experiment.
    h, w = gray.shape
    if max(h, w) > 2000:
        ratio = 2000 / max(h, w)
        h2 = round(int(h * ratio) / 32) * 32
        w2 = round(int(w * ratio) / 32) * 32
        if h2 <= 0 or w2 <= 0:
            raise ValueError("Invalid maximum-bound dimensions")
        gray = resize_gray(gray, w2, h2, method)
    h, w = gray.shape
    if min(h, w) < 30:
        ratio = 30 / min(h, w)
        h2 = round(int(h * ratio) / 32) * 32
        w2 = round(int(w * ratio) / 32) * 32
        if h2 <= 0 or w2 <= 0:
            raise ValueError("Invalid minimum-bound dimensions")
        gray = resize_gray(gray, w2, h2, method)
    h, w = gray.shape
    target = int(48 * max(320 / 48, w / h))
    effective = min(target, int(np.ceil(48 * w / h)))
    image = resize_gray(gray, effective, 48, method)
    tensor = np.zeros((1, 3, 48, target), dtype=np.float32)
    tensor[:, :, :, :effective] = (image.astype(np.float32) / 255 - 0.5) / 0.5
    return tensor


def run(model, roots, per_folder, method="bilinear"):
    model = Path(model).resolve(strict=True)
    if file_sha256(model) != MODEL_SHA256:
        raise ValueError("Model does not match the fixed desktop reference")
    engine = RapidOCR(params={"Global.model_root_dir": str(model.parent), "Global.log_level": "warning",
                              "EngineConfig.onnxruntime.intra_op_num_threads": 1,
                              "EngineConfig.onnxruntime.inter_op_num_threads": 1})
    recognizer = engine._load_rec_model()
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(model), sess_options=options, providers=["CPUExecutionProvider"])
    counts = collections.Counter()
    max_tensor_delta = 0.0
    max_top_score_delta = 0.0
    for root_value in roots:
        root = Path(root_value).resolve(strict=True)
        page = cv2.imread(str(root / "page-1.png"), cv2.IMREAD_GRAYSCALE)
        if page is None:
            raise ValueError("An input folder has no readable page-1.png")
        rows = []
        for path in sorted(root.glob("*-bands.json")):
            rows.extend(row for row in json.loads(path.read_text(encoding="utf-8"))
                        if any(c in "0123456789" for c in row.get("text", "")))
        for row in rows[:per_folder]:
            x0, y0, x1, y1 = row["box"]
            if not (0 <= x0 < x1 <= page.shape[1] and 0 <= y0 < y1 <= page.shape[0]):
                raise ValueError("Band coordinates are outside the source image")
            gray = page[y0:y1, x0:x1]
            image, _ = engine.preprocess_img(engine.load_img(gray))
            h, w = image.shape[:2]
            desktop = recognizer.resize_norm_img(image, max(320 / 48, w / h))[None, :]
            approximate = approximate_tensor(gray, method)
            counts["bands"] += 1
            if desktop.shape != approximate.shape:
                counts["shape_mismatches"] += 1
                continue
            max_tensor_delta = max(max_tensor_delta, float(np.max(np.abs(desktop - approximate))))
            desktop_output = session.run(None, {"x": desktop})[0][0]
            approximate_output = session.run(None, {"x": approximate})[0][0]
            first = desktop_output.argmax(axis=1)
            second = approximate_output.argmax(axis=1)
            counts["bands_with_changed_frames"] += int(np.any(first != second))
            counts["changed_frames"] += int(np.count_nonzero(first != second))
            first_runs, second_runs = ctc_runs(first), ctc_runs(second)
            counts["bands_with_changed_ctc_classes"] += int(
                [item["class"] for item in first_runs] != [item["class"] for item in second_runs])
            counts["bands_with_changed_ctc_positions"] += int(first_runs != second_runs)
            max_top_score_delta = max(max_top_score_delta, float(np.max(
                np.abs(desktop_output.max(axis=1) - approximate_output.max(axis=1)))))
    return {"scope": "Local real-band resize simulation; not iPad runtime or note accuracy", "method": method,
            "counts": dict(counts), "max_tensor_abs_difference": max_tensor_delta,
            "max_top_score_difference": max_top_score_delta}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--root", action="append", required=True, help="Existing digit-ocr output folder")
    parser.add_argument("--per-folder", type=int, default=8)
    parser.add_argument("--method", choices=("bilinear", "opencv_linear", "opencv_exact", "opencv_noipp", "opencv_noopt", "opencv_scalar"), default="bilinear")
    args = parser.parse_args()
    if args.per_folder < 1:
        parser.error("--per-folder must be positive")
    print(json.dumps(run(args.model, args.root, args.per_folder, args.method), indent=2))

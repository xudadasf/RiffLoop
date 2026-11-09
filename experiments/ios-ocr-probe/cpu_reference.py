"""CPU reference for the isolated iPad ONNX experiment.

The input is a fixed synthetic float tensor, not an image or a user score.
This measures model execution parity only; it does not measure OCR accuracy.
The model is supplied externally and is never copied into the repository.
"""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort


MODEL_SHA256 = "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884"
INPUT_SHAPE = (1, 3, 48, 320)
INPUT_SHA256 = "49afe1d7d68e25e5a49d0cff47d15d54f1c37cb939a72c17b4daf031c421f9c4"
GLYPH_SHA256 = "c799e3dae03b67589e41846970041504c13d2d04e9a9b6cdbc9baa9dee8b58cf"
GLYPHS = (
    "01110/10001/10011/10101/11001/10001/01110",
    "00100/01100/00100/00100/00100/00100/01110",
    "01110/10001/00001/00010/00100/01000/11111",
    "11110/00001/00001/01110/00001/00001/11110",
    "00010/00110/01010/10010/11111/00010/00010",
    "11111/10000/10000/11110/00001/00001/11110",
    "01110/10000/10000/11110/10001/10001/01110",
    "11111/00001/00010/00100/01000/01000/01000",
    "01110/10001/10001/01110/10001/10001/01110",
    "01110/10001/10001/01111/00001/00001/01110",
)
SAMPLE_TIMES = (0, 1, 5, 10, 20, 30, 39)
SAMPLE_CLASSES = (0, 33, 34, 35, 42, 18709)


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def synthetic_input():
    # Each value is exactly representable as float32, including on Swift/ARM.
    values = np.arange(np.prod(INPUT_SHAPE), dtype=np.int32)
    values = ((values % 7) - 3).astype(np.float32) * np.float32(0.25)
    return values.reshape(INPUT_SHAPE)


def glyph_input():
    # Fixed synthetic 5x7 glyphs only; this is not a realistic music score.
    values = np.ones(INPUT_SHAPE, dtype=np.float32)
    for number, glyph in enumerate(GLYPHS):
        for row, line in enumerate(glyph.split("/")):
            for column, bit in enumerate(line):
                if bit == "1":
                    x, y = 4 + number * 31 + column * 4, 10 + row * 4
                    values[0, :, y:y + 4, x:x + 4] = -1
    return values


def ctc_runs(indices, blank=0):
    """Collapse adjacent repeats before discarding blanks, preserving positions."""
    runs = []
    previous = None
    for time_index, raw_index in enumerate(indices):
        index = int(raw_index)
        if index == previous:
            if index != blank:
                runs[-1]["end"] = time_index
        elif index != blank:
            runs.append({"class": index, "start": time_index, "end": time_index})
        previous = index
    return runs


def measure(model):
    path = Path(model).resolve(strict=True)
    model_hash = file_sha256(path)
    if model_hash != MODEL_SHA256:
        raise ValueError("The model hash differs from the frozen desktop model")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
    metadata = session.get_modelmeta().custom_metadata_map
    alphabet = [""] + metadata["character"].splitlines() + [" "]
    if len(alphabet) != 18710:
        raise RuntimeError("Model alphabet does not match the output dimension")
    alphabet_bytes = json.dumps(alphabet, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    cases = []
    for name, inputs, expected_hash in (("pattern", synthetic_input(), INPUT_SHA256),
                                        ("glyphs", glyph_input(), GLYPH_SHA256)):
        input_hash = hashlib.sha256(inputs.astype("<f4", copy=False).tobytes()).hexdigest()
        if input_hash != expected_hash:
            raise RuntimeError("Synthetic input bytes differ from the frozen reference")
        output = session.run(None, {"x": inputs})[0]
        if output.shape != (1, 40, 18710) or output.dtype != np.float32 or not np.isfinite(output).all():
            raise RuntimeError("Unexpected output shape, dtype or non-finite values")
        sequence = np.argmax(output[0], axis=-1).tolist()
        runs = ctc_runs(sequence)
        for run in runs:
            run["character"] = alphabet[run["class"]]
        sample = [[float(output[0, time, class_id]) for class_id in SAMPLE_CLASSES] for time in SAMPLE_TIMES]
        cases.append({"name": name, "input_sha256_little_endian": input_hash,
                      "output_shape": list(output.shape), "output_dtype": str(output.dtype),
                      "argmax": sequence, "argmax_scores": [float(output[0, t, c]) for t, c in enumerate(sequence)],
                      "ctc_runs": runs, "ctc_text": "".join(run["character"] for run in runs),
                      "sample_times": list(SAMPLE_TIMES), "sample_classes": list(SAMPLE_CLASSES),
                      "sample_values": sample})
    return {
        "scope": "Synthetic tensor model-execution parity only; not note-recognition accuracy",
        "model_sha256": model_hash,
        "runtime": ort.__version__,
        "provider": session.get_providers()[0],
        "input_shape": list(INPUT_SHAPE),
        "alphabet_sha256_utf8_json": hashlib.sha256(alphabet_bytes).hexdigest(),
        "cases": cases,
    }, alphabet_bytes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="Path to the existing ONNX model (read-only)")
    parser.add_argument("--output", help="Optional new JSON report path; existing files are never overwritten")
    parser.add_argument("--alphabet-output", help="Optional new canonical UTF-8 JSON alphabet path")
    args = parser.parse_args()
    requested = [Path(item).resolve() for item in (args.output, args.alphabet_output) if item]
    if len(set(requested)) != len(requested) or Path(args.model).resolve() in requested:
        raise ValueError("Model, report and alphabet must use distinct paths")
    if any(path.exists() for path in requested):
        raise FileExistsError("A requested output already exists")
    result, alphabet = measure(args.model)
    report = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.alphabet_output:
        output = Path(args.alphabet_output)
        with output.open("xb") as destination:
            destination.write(alphabet)
    if args.output:
        output = Path(args.output)
        with output.open("x", encoding="utf-8", newline="\n") as destination:
            destination.write(report)
    else:
        print(report, end="")


if __name__ == "__main__":
    main()

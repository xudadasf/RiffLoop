"""Check the built app contains the exact offline OCR and editor resources."""
import argparse
import hashlib
from pathlib import Path


def verify(app: Path):
    repo = Path(__file__).resolve().parents[1]
    model = app / "PP-OCRv6_rec_small.onnx"
    if hashlib.sha256(model.read_bytes()).hexdigest() != "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884":
        raise ValueError("Packaged OCR model is not the verified offline weight")
    source = repo / "RiffLoop/Resources/ScoreEditor"
    for path in source.iterdir():
        if path.is_file() and (app / "ScoreEditor" / path.name).read_bytes() != path.read_bytes():
            raise ValueError(f"Packaged editor resource differs: {path.name}")
    for relative in ["GpWeb/alphaTab.min.js", "ScoreDraft.html", "draft-core.js", "draft-v2.cjs"]:
        if not (app / relative).is_file():
            raise ValueError(f"Missing existing score resource: {relative}")
    print("Verified packaged offline recognition and score editor resources")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    verify(parser.parse_args().app)

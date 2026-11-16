"""Fetch a fixed public OCR weight for packaging; never reads score material."""
import argparse
import hashlib
import pathlib
import shutil
import urllib.request

SHA = "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884"
URL = "https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=pathlib.Path)
    args = parser.parse_args()
    folder = pathlib.Path(__file__).resolve().parents[1] / ".cache" / "score-ocr"
    folder.mkdir(parents=True, exist_ok=True)
    destination = folder / "PP-OCRv6_rec_small.onnx"
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == SHA:
        print("OCR model verified")
        return
    staging = folder / "download.pending"
    if args.model:
        shutil.copyfile(args.model, staging)
    else:
        with urllib.request.urlopen(URL, timeout=120) as response, staging.open("wb") as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(staging.read_bytes()).hexdigest() != SHA:
        raise ValueError("OCR model checksum mismatch; refusing to package")
    staging.replace(destination)
    print("OCR model verified")

if __name__ == "__main__":
    main()

"""Prepare the pinned public recognition model and iOS runtime for offline use."""
import argparse
import base64
import hashlib
import json
import pathlib
import shutil
import tempfile
import urllib.request
import zipfile

SHA = "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884"
URL = "https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx"


def prepare_runtime(vendor):
    pins = json.loads((vendor / "provenance.json").read_text(encoding="utf-8"))
    cache = vendor / ".cache"
    cache.mkdir(exist_ok=True)
    destination = cache / f"onnxruntime-{pins['version']}.zip"
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == pins["framework_sha256"]:
        return
    # The signed NuGet contains the iOS device and simulator XCFramework in one ZIP.
    # Verify the package against the NuGet catalogue and its embedded artifact before use.
    with tempfile.TemporaryDirectory(dir=cache) as tmp:
        package = pathlib.Path(tmp) / "runtime.nupkg"
        digest = hashlib.sha512()
        with urllib.request.urlopen(pins["nuget_url"], timeout=120) as response, package.open("wb") as output:
            while block := response.read(1024 * 1024):
                digest.update(block)
                output.write(block)
        if base64.b64encode(digest.digest()).decode("ascii") != pins["nuget_sha512"]:
            raise ValueError("ONNX NuGet package checksum mismatch")
        with zipfile.ZipFile(package) as archive:
            framework = archive.read(pins["framework_member"])
        if hashlib.sha256(framework).hexdigest() != pins["framework_sha256"]:
            raise ValueError("iOS XCFramework checksum mismatch")
        staging = pathlib.Path(tmp) / destination.name
        staging.write_bytes(framework)
        staging.replace(destination)
    print("iOS recognition runtime verified")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=pathlib.Path)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    prepare_runtime(root / "Vendor" / "ONNXRuntime")
    folder = root / ".cache" / "score-ocr"
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

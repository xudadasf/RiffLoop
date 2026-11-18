"""Verify the pinned official ONNX source wrapper and binary configuration."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def verify(root, archive=None):
    metadata = json.loads((root / 'provenance.json').read_text(encoding='utf-8'))
    files = metadata['files']
    actual = {p.relative_to(root).as_posix() for p in (root / 'objectivec').rglob('*') if p.is_file()}
    if actual | {'LICENSE'} != set(files):
        raise ValueError('Unexpected or missing ONNX binding source')
    for name, expected in files.items():
        source = root / name
        if not source.resolve().is_relative_to(root.resolve()) or source.is_symlink():
            raise ValueError('Invalid ONNX source path')
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError(f'ONNX source checksum mismatch: {name}')
    package = (root / 'Package.swift').read_text(encoding='utf-8')
    if metadata['binary_url'] not in package or metadata['binary_sha256'] not in package:
        raise ValueError('ONNX binary is not pinned to the verified release')
    if archive:
        if hashlib.sha256(archive.read_bytes()).hexdigest() != metadata['source_sha256']:
            raise ValueError('Official ONNX archive checksum mismatch')
        with zipfile.ZipFile(archive) as z:
            for name in files:
                if (root / name).read_bytes() != z.read(name):
                    raise ValueError(f'ONNX source differs from official archive: {name}')
    print(f'ONNX Runtime {metadata["version"]}: {len(files)} official source/license files verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    verify(Path(__file__).resolve().parents[1] / 'Vendor' / 'ONNXRuntime', args.archive)

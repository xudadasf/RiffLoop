"""Release guard regressions for the offline ONNX source wrapper."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('onnx_package', ROOT / 'scripts/verify-onnx-package.py')
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)
PACKAGE = ROOT / 'Vendor/ONNXRuntime'


class PackageGuardTests(unittest.TestCase):
    def test_official_sources_are_unchanged(self):
        GUARD.verify(PACKAGE)

    def test_changed_source_is_rejected(self):
        original = Path.read_bytes
        def read(path):
            value = original(path)
            return value + b'changed' if path.name == 'ort_session.mm' else value
        with patch.object(Path, 'read_bytes', read), self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            GUARD.verify(PACKAGE)

    def test_changed_binary_is_rejected(self):
        original = Path.read_text
        def read(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value.replace('1.24.2.zip', '1.24.1.zip') if path.name == 'Package.swift' else value
        with patch.object(Path, 'read_text', read), self.assertRaisesRegex(ValueError, 'not pinned'):
            GUARD.verify(PACKAGE)


if __name__ == '__main__':
    unittest.main()

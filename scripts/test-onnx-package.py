"""Release guard regressions for the offline ONNX source wrapper."""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('onnx_package', ROOT / 'scripts/verify-onnx-package.py')
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)
PREP_SPEC = importlib.util.spec_from_file_location('prepare_ocr', ROOT / 'scripts/prepare-score-ocr.py')
PREP = importlib.util.module_from_spec(PREP_SPEC)
PREP_SPEC.loader.exec_module(PREP)
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


class RuntimePreparationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.vendor = Path(directory.name)
        package = io.BytesIO()
        self.framework = b'xcframework fixture'
        with zipfile.ZipFile(package, 'w') as archive:
            archive.writestr('ios/framework.zip', self.framework)
        self.package = package.getvalue()
        self.pins = dict(version='1.24.2', nuget_url='https://example.invalid/runtime',
                         nuget_sha512=base64.b64encode(hashlib.sha512(self.package).digest()).decode(),
                         framework_member='ios/framework.zip', framework_sha256=hashlib.sha256(self.framework).hexdigest())
        self.output = self.vendor / '.cache/onnxruntime-1.24.2.zip'

    def prepare(self, package):
        (self.vendor / 'provenance.json').write_text(json.dumps(self.pins), encoding='utf-8')
        with patch.object(PREP.urllib.request, 'urlopen', return_value=io.BytesIO(package)) as download:
            PREP.prepare_runtime(self.vendor)
        return download.call_count

    def test_verified_cache_can_be_used_offline(self):
        self.assertEqual(self.prepare(self.package), 1)
        self.assertEqual(self.output.read_bytes(), self.framework)
        self.assertEqual(self.prepare(b''), 0)

    def test_failed_download_leaves_prior_cache_intact(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b'prior cache')
        with self.assertRaisesRegex(ValueError, 'NuGet package checksum mismatch'):
            self.prepare(b'incomplete download')
        self.pins['framework_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'XCFramework checksum mismatch'):
            self.prepare(self.package)
        self.assertEqual(self.output.read_bytes(), b'prior cache')
        self.assertEqual(list(self.output.parent.iterdir()), [self.output])


if __name__ == '__main__':
    unittest.main()

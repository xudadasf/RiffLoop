import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("verify_ipa", Path(__file__).with_name("verify-ipa.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "test.ipa"
        self.info = {"CFBundleIdentifier": "com.riffloop.prototype",
                     "CFBundleShortVersionString": "0.25.51", "CFBundleVersion": "95",
                     "CFBundleSupportedPlatforms": ["iPhoneOS"]}
        self.write_package()

    def write_package(self, extra_app=False):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/RiffLoop.app/Info.plist", plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))
            if extra_app:
                archive.writestr("Payload/Other.app/Info.plist", plistlib.dumps(self.info))
        self.metadata = {"head_sha": "a" * 40, "ipa_file": self.ipa.name,
                         "sha256": hashlib.sha256(self.ipa.read_bytes()).hexdigest()}

    def verify(self):
        return verifier.verify_package(self.ipa, self.metadata, "a" * 40, "0.25.51", "95")

    def test_matching_binary_plist_passes(self):
        self.assertEqual(self.verify(), self.metadata["sha256"])

    def test_wrong_commit_rejected(self):
        self.metadata["head_sha"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "commit"): self.verify()

    def test_wrong_filename_rejected(self):
        self.metadata["ipa_file"] = "other.ipa"
        with self.assertRaisesRegex(ValueError, "filename"): self.verify()

    def test_modified_bytes_rejected(self):
        with self.ipa.open("ab") as stream: stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "SHA256"): self.verify()

    def test_actual_metadata_must_match_even_if_hash_is_valid(self):
        for key, value in [("CFBundleIdentifier", "com.other.app"),
                           ("CFBundleShortVersionString", "0.25.50"),
                           ("CFBundleVersion", "94"),
                           ("CFBundleSupportedPlatforms", ["iPhoneSimulator"])]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_package()
                with self.assertRaisesRegex(ValueError, key): self.verify()
                self.info[key] = original

    def test_extra_app_rejected(self):
        self.write_package(extra_app=True)
        with self.assertRaisesRegex(ValueError, "exactly one"): self.verify()


if __name__ == "__main__":
    unittest.main()

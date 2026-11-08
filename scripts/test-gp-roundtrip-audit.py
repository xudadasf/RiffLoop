import importlib.util
from pathlib import Path
import tempfile
import unittest
import warnings
import zipfile


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gp_roundtrip_audit", HERE / "gp-roundtrip-audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class GpRoundtripAuditTests(unittest.TestCase):
    def test_reports_removed_added_and_changed_resources(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / "old.gp", Path(tmp) / "new.gp"
            with zipfile.ZipFile(old, "w") as archive:
                archive.writestr(audit.SCORE_ENTRY, "old score")
                archive.writestr("audio", b"old audio")
                archive.writestr("removed", b"a")
                archive.writestr("old-name", b"renamed audio")
                archive.writestr("same", b"same")
            with zipfile.ZipFile(new, "w") as archive:
                archive.writestr(audit.SCORE_ENTRY, "changed score is checked separately")
                archive.writestr("audio", b"new audio")
                archive.writestr("added", b"b")
                archive.writestr("new-name", b"renamed audio")
                archive.writestr("same", b"same")
            result = audit.compare_resources(audit.zip_entry_hashes(old), audit.zip_entry_hashes(new))
            self.assertEqual(result["missing"], ["old-name", "removed"])
            self.assertEqual(result["added"], ["added", "new-name"])
            self.assertEqual(result["changed"], ["audio"])
            self.assertEqual(result["unchanged_count"], 1)
            self.assertEqual(result["same_content_different_name"], [{"original": "old-name", "matching_content_at": "new-name"}])
            self.assertEqual({entry["name"] for entry in result["entries"]}, {"audio", "removed", "same", "added", "old-name", "new-name"})

    def test_duplicate_or_non_gp_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            invalid = Path(tmp) / "invalid.gp"
            invalid.write_bytes(b"not a zip")
            with self.assertRaises(zipfile.BadZipFile):
                audit.zip_entry_hashes(invalid)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(invalid, "w") as archive:
                    archive.writestr(audit.SCORE_ENTRY, "first")
                    archive.writestr(audit.SCORE_ENTRY, "second")
            with self.assertRaises(ValueError):
                audit.zip_entry_hashes(invalid)

    def test_semantic_changes_include_locations_and_list_lengths(self):
        before = {"tracks": [{"notes": [{"fret": 3, "duration": 4}]}]}
        after = {"tracks": [{"notes": [{"fret": 5, "duration": 4}, {"fret": 0}]}]}
        result = audit.compare_semantics(before, after)
        self.assertEqual(result["difference_count"], 2)
        self.assertEqual({item["path"] for item in result["examples"]}, {"score.tracks[0].notes.length", "score.tracks[0].notes[0].fret"})

    def test_real_fixture_roundtrip_and_exclusive_output(self):
        fixture = HERE.parent / "RiffLoopTests" / "Fixtures" / "transport.gp"
        original = fixture.read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            result = audit.audit(fixture, output_dir=tmp)
            self.assertEqual(result["semantics"]["difference_count"], 0)
            self.assertEqual(result["resources"]["missing"], [])
            output = Path(tmp) / (fixture.name + ".roundtrip.gp")
            output_before = output.read_bytes()
            with self.assertRaises(FileExistsError):
                audit.audit(fixture, output_dir=tmp)
            self.assertEqual(output.read_bytes(), output_before)
        self.assertEqual(fixture.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()

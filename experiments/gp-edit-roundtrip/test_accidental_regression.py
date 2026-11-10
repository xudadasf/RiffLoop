"""Reproduce the known alphaTab accidental issue without writing GP files.

The expected failure records a known defect, not a passing safety gate. Once a
real fix lands, its unexpected success is a reminder to remove that annotation.
"""

import base64
import hashlib
import io
import json
from pathlib import Path
import subprocess
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "RiffLoopTests" / "Fixtures" / "transport.gp"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gpif_note(case):
    with ZipFile(io.BytesIO(base64.b64decode(case["gp"], validate=True))) as archive:
        root = ET.fromstring(archive.read("Content/score.gpif"))
    bar_id = root.findtext("./MasterBars/MasterBar/Bars").split()[0]
    voice_id = root.find(f"./Bars/Bar[@id='{bar_id}']").findtext("Voices").split()[0]
    beat_id = root.find(f"./Voices/Voice[@id='{voice_id}']").findtext("Beats").split()[case["beatIndex"]]
    note_id = root.find(f"./Beats/Beat[@id='{beat_id}']").findtext("Notes").split()[0]
    return root.find(f"./Notes/Note[@id='{note_id}']")


def pitch(note, name):
    parent = note.find(f"./Properties/Property[@name='{name}']/Pitch")
    return (parent.findtext("Step"), parent.findtext("Accidental") or "", parent.findtext("Octave"))


class AccidentalReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_hash_before = sha(FIXTURE)
        result = subprocess.run(["node", "experiments/gp-edit-roundtrip/accidental_reference.cjs"],
                                cwd=ROOT, check=True, capture_output=True, text=True, timeout=30)
        cls.cases = json.loads(result.stdout)
        cls.fixture_hash_after = sha(FIXTURE)
        cls.notes = {name: gpif_note(case) for name, case in cls.cases.items()}

    def test_identical_fret_and_real_value_from_fresh_and_edited_notes(self):
        self.assertEqual(self.fixture_hash_before, self.fixture_hash_after)
        for name, case in self.cases.items():
            with self.subTest(case=name):
                self.assertEqual(case["edited"]["fret"], 4)
                self.assertEqual(case["edited"]["realValue"], 59)
                self.assertEqual(case["reread"]["realValue"], 59)
                self.assertEqual(self.notes[name].findtext("./Properties/Property[@name='Midi']/Number"), "59")

    def test_previously_sharp_note_retains_forced_mode_after_reload(self):
        case = self.cases["fromSharp"]
        self.assertEqual(case["before"]["accidentalMode"], 3)
        self.assertEqual(case["edited"]["accidentalMode"], 3)
        self.assertEqual(case["reread"]["accidentalMode"], 3)
        self.assertEqual(pitch(self.notes["fromSharp"], "ConcertPitch"), ("B", "#", "4"))
        self.assertEqual(pitch(self.notes["fromSharp"], "TransposedPitch"), ("B", "#", "5"))

    def test_fresh_and_previously_natural_notes_have_same_notation(self):
        for key in ("ConcertPitch", "TransposedPitch"):
            self.assertEqual(pitch(self.notes["fromNatural"], key), pitch(self.notes["fresh"], key))
        self.assertEqual(pitch(self.notes["fresh"], "ConcertPitch"), ("B", "", "4"))
        self.assertEqual(pitch(self.notes["fresh"], "TransposedPitch"), ("B", "", "5"))

    @unittest.expectedFailure
    def test_fret_edit_should_not_retain_old_sharp(self):
        # Known failure: a prior ForceSharp remains after fret changes A# to B,
        # yielding B# in GPIF despite the same fret and MIDI as the fresh note.
        for key in ("ConcertPitch", "TransposedPitch"):
            self.assertEqual(pitch(self.notes["fromSharp"], key), pitch(self.notes["fresh"], key))


if __name__ == "__main__":
    unittest.main()

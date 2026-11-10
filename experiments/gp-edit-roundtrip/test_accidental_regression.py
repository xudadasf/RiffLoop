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
        cls.observations = cls.cases.pop("observations")
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

    def test_resetting_flat_preserves_midi_but_changes_enharmonic_spelling(self):
        cases = self.observations["flatReset"]
        before, after = cases["before"], cases["after"]
        self.assertEqual((before["mode"], after["mode"]), (5, 0))
        self.assertEqual((before["realValue"], after["realValue"]), (58, 58))
        old, new = gpif_note(before), gpif_note(after)
        self.assertEqual(old.findtext("./Properties/Property[@name='Midi']/Number"), "58")
        self.assertEqual(new.findtext("./Properties/Property[@name='Midi']/Number"), "58")
        self.assertEqual(pitch(old, "ConcertPitch"), ("B", "b", "4"))
        self.assertEqual(pitch(new, "ConcertPitch"), ("A", "#", "4"))
        self.assertEqual(pitch(old, "TransposedPitch"), ("B", "b", "5"))
        self.assertEqual(pitch(new, "TransposedPitch"), ("A", "#", "5"))
        self.assertEqual((before["reread"]["realValue"], after["reread"]["realValue"]), (58, 58))

    def test_display_transposition_changes_written_pitch(self):
        for name, expected_octave in (("transposeMinus", "5"), ("transposeZero", "4"),
                                      ("transposePlus", "3")):
            with self.subTest(name=name):
                case = self.observations[name]
                note = gpif_note(case)
                self.assertEqual(case["edited"]["realValue"], 58)
                self.assertEqual(case["reread"]["realValue"], 58)
                self.assertEqual(note.findtext("./Properties/Property[@name='Midi']/Number"), "58")
                self.assertEqual(pitch(note, "ConcertPitch"), ("A", "#", "4"))
                self.assertEqual(pitch(note, "TransposedPitch"), ("A", "#", expected_octave))

    @unittest.expectedFailure
    def test_fret_edit_should_not_retain_old_sharp(self):
        # Known failure: a prior ForceSharp remains after fret changes A# to B,
        # yielding B# in GPIF despite the same fret and MIDI as the fresh note.
        for key in ("ConcertPitch", "TransposedPitch"):
            self.assertEqual(pitch(self.notes["fromSharp"], key), pitch(self.notes["fresh"], key))


if __name__ == "__main__":
    unittest.main()

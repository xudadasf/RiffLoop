import unittest
from xml.etree import ElementTree as ET

from probe import UnsupportedScore, edit_fret, occurrences, synthetic_score


class CopyOnWriteTests(unittest.TestCase):
    def setUp(self):
        self.score = synthetic_score()
        self.bases = {0: 40}
        self.target = (0, 0, 0, 0, 0)

    def assert_rejected_without_modification(self, *, bases=None, target=None, fret=5):
        before = ET.tostring(self.score)
        with self.assertRaises(UnsupportedScore):
            edit_fret(self.score, target or self.target, fret, self.bases if bases is None else bases)
        self.assertEqual(ET.tostring(self.score), before)

    def test_one_occurrence_changes_and_shared_rhythm_stays_identical(self):
        original_bytes = ET.tostring(self.score)
        original_values = occurrences(self.score, self.bases)
        original_rhythms = ET.tostring(self.score.find("Rhythms"))
        edited, cloned = edit_fret(self.score, self.target, 5, self.bases)
        edited_values = occurrences(edited, self.bases)

        self.assertEqual(len(original_values), 6)
        self.assertEqual(cloned, ["Bar", "Voice", "Beat", "Note"])
        self.assertEqual(ET.tostring(self.score), original_bytes)
        self.assertEqual(ET.tostring(edited.find("Rhythms")), original_rhythms)
        self.assertEqual(edited_values[self.target], {"String": 0, "Fret": 5, "Midi": 45})
        for position in original_values.keys() - {self.target}:
            self.assertEqual(edited_values[position], original_values[position])
        self.assertEqual(edited.find("./Beats/Beat[@id='2']/Rhythm").get("ref"), "0")

    def test_second_edit_does_not_leak_into_other_occurrences(self):
        first, _ = edit_fret(self.score, self.target, 5, self.bases)
        second_target = (1, 0, 0, 1, 0)
        second, _ = edit_fret(first, second_target, 7, self.bases)
        first_values = occurrences(first, self.bases)
        second_values = occurrences(second, self.bases)
        self.assertEqual(second_values[second_target]["Fret"], 7)
        for position in first_values.keys() - {second_target}:
            self.assertEqual(second_values[position], first_values[position])

    def test_unique_path_needs_no_extra_objects(self):
        masters = self.score.find("MasterBars")
        for master in list(masters)[1:]:
            masters.remove(master)
        self.score.find("Bars").remove(self.score.find("./Bars/Bar[@id='1']"))
        self.score.find("./Voices/Voice/Beats").text = "0"
        self.score.find("Beats").remove(self.score.find("./Beats/Beat[@id='1']"))
        edited, cloned = edit_fret(self.score, self.target, 5, self.bases)
        self.assertEqual(cloned, [])
        self.assertEqual(occurrences(self.score, self.bases)[self.target]["Fret"], 3)
        self.assertEqual(occurrences(edited, self.bases)[self.target]["Fret"], 5)

    def test_unknown_and_inconsistent_pitch_are_refused(self):
        self.assert_rejected_without_modification(bases={})
        self.assert_rejected_without_modification(bases={0: 39})
        note = self.score.find("./Notes/Note")
        ET.SubElement(note.find("Properties"), "Property", {"name": "ConcertPitch"})
        self.assert_rejected_without_modification()

    def test_ties_and_beat_techniques_are_refused(self):
        ET.SubElement(self.score.find("./Notes/Note"), "Tie", {"origin": "true"})
        self.assert_rejected_without_modification()
        self.score = synthetic_score()
        ET.SubElement(self.score.find("./Beats/Beat"), "GraceNotes").text = "BeforeBeat"
        self.assert_rejected_without_modification()

    def test_invalid_references_ids_and_targets_are_refused(self):
        self.assert_rejected_without_modification(target=(3, 0, 0, 0, 0))
        self.assert_rejected_without_modification(target=(0, 0, 0, 0, -1))
        self.assert_rejected_without_modification(fret=25)
        self.score.find("./Voices/Voice/Beats").text = "0 999"
        self.assert_rejected_without_modification()
        self.score = synthetic_score()
        self.score.find("./Beats/Beat[@id='1']").set("id", "0")
        self.assert_rejected_without_modification()

    def test_real_or_unidentified_format_is_refused(self):
        del self.score.attrib["experiment"]
        self.assert_rejected_without_modification()


if __name__ == "__main__":
    unittest.main()

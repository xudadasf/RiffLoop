import hashlib
from dataclasses import replace
from xml.etree import ElementTree as ET
import unittest

from note_patch import Unsupported, candidates, patch_synthetic
from semantic import ImportedNote
from test_semantic import observed, synthetic


class SyntheticNotePatchTests(unittest.TestCase):
    def setUp(self):
        self.source = ET.tostring(synthetic())
        self.observation = observed()
        self.checked = candidates(self.source, self.observation)

    def test_change_only_selected_values_and_preserve_other_bytes(self):
        selected = self.checked[0]
        result = patch_synthetic(self.source, self.observation, selected, 7)
        # Independent expected bytes: replace only these four exact XML values.
        start, end = selected.byte_span
        original_note = self.source[start:end]
        expected_note = original_note.replace(b'<Fret>5</Fret>', b'<Fret>7</Fret>', 1)
        expected_note = expected_note.replace(b'<Number>60</Number>', b'<Number>62</Number>', 1)
        expected_note = expected_note.replace(b'<Step>C</Step>', b'<Step>D</Step>', 2)
        self.assertEqual(result, self.source[:start] + expected_note + self.source[end:])
        self.assertEqual(self.source, ET.tostring(synthetic()))

        # Independently reparse the changed XML, including the untouched note.
        root = ET.fromstring(result)
        first = root.find("./Notes/Note[@id='0']/Properties")
        second = root.find("./Notes/Note[@id='1']/Properties")
        self.assertEqual(first.findtext("./Property[@name='Fret']/Fret"), '7')
        self.assertEqual(first.findtext("./Property[@name='Midi']/Number"), '62')
        for name, octave in (('ConcertPitch', '5'), ('TransposedPitch', '6')):
            pitch = first.find(f"./Property[@name='{name}']/Pitch")
            self.assertEqual((pitch.findtext('Step'), pitch.findtext('Accidental') or '', pitch.findtext('Octave')),
                             ('D', '', octave))
        self.assertEqual(second.findtext("./Property[@name='Fret']/Fret"), '7')

        # Simulated importer evidence on changed bytes must also pass the
        # independent candidate checker; this is not a real playback test.
        beats = dict(self.observation.beats)
        beats[selected.position] = (ImportedNote(4, 7, 62),)
        updated_observation = replace(self.observation, beats=beats,
                                      gpif_sha256=hashlib.sha256(result).hexdigest())
        self.assertEqual(candidates(result, updated_observation)[0].midi, 62)

    def test_reverse_transition_uses_selected_second_note(self):
        result = patch_synthetic(self.source, self.observation, self.checked[1], 5)
        root = ET.fromstring(result)
        first = root.find("./Notes/Note[@id='0']/Properties")
        second = root.find("./Notes/Note[@id='1']/Properties")
        self.assertEqual(first.findtext("./Property[@name='Midi']/Number"), '60')
        self.assertEqual(second.findtext("./Property[@name='Midi']/Number"), '60')
        self.assertEqual(second.findtext("./Property[@name='ConcertPitch']/Pitch/Step"), 'C')

    def test_unchecked_input_and_unsupported_transition_are_refused(self):
        with self.assertRaises(Unsupported):
            patch_synthetic(self.source + b' ', self.observation, self.checked[0], 7)
        with self.assertRaises(Unsupported):
            patch_synthetic(self.source, replace(self.observation, gpif_sha256='0' * 64), self.checked[0], 7)
        with self.assertRaises(Unsupported):
            patch_synthetic(self.source, self.observation, replace(self.checked[0], byte_span=(0, 1)), 7)
        for value in (5, 6, 8, True, '7'):
            with self.subTest(value=value), self.assertRaises(Unsupported):
                patch_synthetic(self.source, self.observation, self.checked[0], value)


if __name__ == '__main__':
    unittest.main()

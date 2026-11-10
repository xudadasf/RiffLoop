"""Narrow initial-sound checks against generated data and the bundled importer."""

from dataclasses import replace
import hashlib
from io import BytesIO
from pathlib import Path
import sys
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile

import semantic
from semantic import ImportedPlayback, Unsupported, _track_sound, candidates
from test_semantic import observed, synthetic


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/gp-memory-surgery'))
from observation import observe_semantic
sys.path.pop(0)


def sound_on(track, *, lsb='1', msb='2', program='25'):
    sounds = ET.SubElement(track, 'Sounds')
    sound = ET.SubElement(sounds, 'Sound')
    for tag, value in (('Name', 'synthetic'), ('Label', 'synthetic'),
                       ('Path', 'Midi/synthetic'), ('Role', 'Factory')):
        ET.SubElement(sound, tag).text = value
    midi = ET.SubElement(sound, 'MIDI')
    for tag, value in (('LSB', lsb), ('MSB', msb), ('Program', program)):
        ET.SubElement(midi, tag).text = value
    return sounds, sound, midi


class InitialSoundTests(unittest.TestCase):
    def setUp(self):
        self.root = synthetic()
        self.track = self.root.find('./Tracks/Track')
        self.sounds, self.sound, self.midi = sound_on(self.track)

    def check(self, playback=ImportedPlayback(25, 257)):
        xml = ET.tostring(self.root)
        evidence = replace(observed(), gpif_sha256=hashlib.sha256(xml).hexdigest(), playback=playback)
        return candidates(xml, evidence)

    def test_one_initial_sound_requires_matching_program_and_bank(self):
        self.assertEqual(len(self.check()), 2)
        for playback in (None, ImportedPlayback(25, 0), ImportedPlayback(24, 257),
                         ImportedPlayback(True, 257)):
            with self.subTest(playback=playback), self.assertRaises(Unsupported):
                self.check(playback)

    def test_unknown_dynamic_and_ambiguous_sounds_are_rejected(self):
        mutations = (
            lambda: ET.SubElement(self.sound, 'Effect'),
            lambda: ET.SubElement(self.sounds, 'Sound'),
            lambda: ET.SubElement(self.track, 'Sounds'),
            lambda: ET.SubElement(self.track, 'Automations'),
            lambda: self.midi.find('MSB').__setattr__('text', '128'),
            lambda: self.midi.find('Program').set('unknown', '1'),
            lambda: self.sound.set('unknown', '1'),
            lambda: ET.SubElement(self.sound.find('Path'), 'Unknown'),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp()
                mutate()
                with self.assertRaises(Unsupported):
                    self.check()

    def test_fixture_sound_matches_actual_bundled_importer(self):
        source = (ROOT / 'RiffLoopTests/Fixtures/transport.gp').read_bytes()
        with ZipFile(BytesIO(source)) as archive:
            gpif = archive.read('Content/score.gpif')
        root = ET.fromstring(gpif)
        _, evidence = observe_semantic(source, semantic)
        self.assertEqual(evidence.playback, ImportedPlayback(25, 0))
        # This targets only the sound component. The full fixture contains
        # other structures which the candidate experiment still rejects.
        _track_sound(root.find('./Tracks/Track'), evidence)
        with self.assertRaises(Unsupported):
            _track_sound(root.find('./Tracks/Track'), replace(evidence, playback=ImportedPlayback(25, 1)))


if __name__ == '__main__':
    unittest.main()

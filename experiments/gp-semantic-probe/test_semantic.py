import hashlib
import unittest
from dataclasses import replace
from xml.etree import ElementTree as ET

from semantic import Candidate, ImportedNote, ImporterObservation, Unsupported, candidates


def synthetic():
    return ET.fromstring('''<GPIF>
      <MasterTrack><Tracks>0</Tracks></MasterTrack>
      <Tracks><Track id="0"><Transpose><Chromatic>0</Chromatic><Octave>-1</Octave></Transpose>
        <Staves><Staff><Properties>
          <Property name="Tuning"><Pitches>40 45 50 55 59 64</Pitches></Property>
          <Property name="CapoFret"><Fret>0</Fret></Property>
          <Property name="PartialCapoFret"><Fret>0</Fret></Property>
          <Property name="PartialCapoStringFlags"><Bitset>000000</Bitset></Property>
        </Properties></Staff></Staves></Track></Tracks>
      <MasterBars><MasterBar><Key><AccidentalCount>0</AccidentalCount><Mode>Major</Mode></Key>
        <Bars>0</Bars></MasterBar></MasterBars>
      <Bars><Bar id="0"><Voices>0</Voices></Bar></Bars>
      <Voices><Voice id="0"><Beats>0 1</Beats></Voice></Voices>
      <Beats><Beat id="0"><Rhythm ref="0"/><Notes>0</Notes><Properties>
        <Property name="PrimaryPickupVolume"><Float>0.5</Float></Property></Properties></Beat>
        <Beat id="1"><Rhythm ref="0"/><Notes>1</Notes></Beat></Beats>
      <Notes>
        <Note id="0"><Properties>
          <Property name="String"><String>3</String></Property>
          <Property name="Fret"><Fret>5</Fret></Property>
          <Property name="Midi"><Number>60</Number></Property>
          <Property name="ConcertPitch"><Pitch><Step>C</Step><Accidental></Accidental><Octave>5</Octave></Pitch></Property>
          <Property name="TransposedPitch"><Pitch><Step>C</Step><Accidental></Accidental><Octave>6</Octave></Pitch></Property>
        </Properties><InstrumentArticulation>0</InstrumentArticulation></Note>
        <Note id="1"><Properties>
          <Property name="String"><String>3</String></Property>
          <Property name="Fret"><Fret>7</Fret></Property>
          <Property name="Midi"><Number>62</Number></Property>
          <Property name="ConcertPitch"><Pitch><Step>D</Step><Accidental></Accidental><Octave>5</Octave></Pitch></Property>
          <Property name="TransposedPitch"><Pitch><Step>D</Step><Accidental></Accidental><Octave>6</Octave></Pitch></Property>
        </Properties><InstrumentArticulation>0</InstrumentArticulation></Note>
      </Notes><Rhythms><Rhythm id="0"><NoteValue>Quarter</NoteValue></Rhythm></Rhythms>
    </GPIF>''')


def observed():
    return ImporterObservation(1, 1, (64, 59, 55, 50, 45, 40), 0, 0, -12,
                               {(0, 0, 0): (ImportedNote(4, 5, 60),),
                                (0, 0, 1): (ImportedNote(4, 7, 62),)},
                               hashlib.sha256(ET.tostring(synthetic())).hexdigest(), tempos=())


class SemanticTests(unittest.TestCase):
    def setUp(self):
        self.root = synthetic()
        self.observation = observed()

    def run_probe(self):
        xml = ET.tostring(self.root)
        # Tests that mutate the synthetic score simulate producing fresh
        # observations for the exact new input, so other checks are exercised.
        return candidates(xml, replace(self.observation, gpif_sha256=hashlib.sha256(xml).hexdigest()))

    def test_two_plain_unique_notes_and_shared_rhythm(self):
        before = ET.tostring(self.root)
        found = self.run_probe()
        self.assertEqual([(x.position, x.note_id, x.string, x.fret, x.midi) for x in found],
                         [((0, 0, 0), '0', 3, 5, 60), ((0, 0, 1), '1', 3, 7, 62)])
        for x in found:
            self.assertEqual(ET.fromstring(before[slice(*x.byte_span)]).get('id'), x.note_id)
        self.assertEqual(ET.tostring(self.root), before)

    def test_requires_importer_agreement_and_actual_zero_transposition(self):
        for obs in (replace(self.observation, actual_transposition=12),
                    replace(self.observation, capo=2),
                    replace(self.observation, display_transposition=0),
                    replace(self.observation, tuning_high_to_low=(64, 59, 55, 50, 45, 39))):
            with self.subTest(obs=obs), self.assertRaises(Unsupported):
                candidates(ET.tostring(self.root), obs)
        self.observation = replace(self.observation, beats={})
        with self.assertRaises(Unsupported): self.run_probe()

    def test_midi_and_both_pitch_spellings_must_agree(self):
        for path, value in (("./Notes/Note/Properties/Property[@name='Midi']/Number", '61'),
                            ("./Notes/Note/Properties/Property[@name='ConcertPitch']/Pitch/Accidental", '#'),
                            ("./Notes/Note/Properties/Property[@name='TransposedPitch']/Pitch/Octave", '5')):
            with self.subTest(path=path):
                self.root = synthetic()
                self.root.find(path).text = value
                found = self.run_probe()
                self.assertEqual([(x.position, x.note_id, x.fret) for x in found], [((0, 0, 1), '1', 7)])

    def test_rejects_unknown_pitch_and_global_techniques(self):
        mutations = [lambda r: ET.SubElement(r.find('./Notes/Note'), 'Tie', {'origin': 'true'}),
                     lambda r: ET.SubElement(r.find('./Notes/Note/Properties'), 'Property', {'name': 'Slide'}),
                     lambda r: ET.SubElement(r.find('./Beats/Beat'), 'GraceNotes'),
                     lambda r: ET.SubElement(r.find('./Beats/Beat/Properties'), 'Property', {'name': 'PickStroke'})]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.root = synthetic(); mutate(self.root)
                with self.assertRaises(Unsupported): self.run_probe()

    def test_shared_note_and_polyphonic_beat_never_selected(self):
        self.root.find("./Beats/Beat[@id='1']/Notes").text = '0'
        with self.assertRaises(Unsupported): self.run_probe()
        self.root = synthetic()
        self.root.find("./Beats/Beat[@id='0']/Notes").text = '0 1'
        with self.assertRaises(Unsupported): self.run_probe()

    def test_shared_parent_and_dangling_or_duplicate_ids_rejected(self):
        another = ET.SubElement(self.root.find('MasterBars'), 'MasterBar')
        ET.SubElement(another, 'Key').extend([ET.Element('AccidentalCount'), ET.Element('Mode')])
        another.find('./Key/AccidentalCount').text = '0'; another.find('./Key/Mode').text = 'Major'
        ET.SubElement(another, 'Bars').text = '0'
        with self.assertRaises(Unsupported): self.run_probe()
        self.root = synthetic(); self.root.find('./Voices/Voice/Beats').text = '0 999'
        with self.assertRaises(Unsupported): self.run_probe()
        self.root = synthetic(); self.root.find("./Notes/Note[@id='1']").set('id', '0')
        with self.assertRaises(Unsupported): self.run_probe()

    def test_non_neutral_key_must_not_generate_candidate(self):
        self.root.find('./MasterBars/MasterBar/Key/AccidentalCount').text = '1'
        with self.assertRaises(Unsupported): self.run_probe()

    def test_unknown_xml_extensions_and_bad_input_rejected(self):
        for data in (b'', b'not xml', b'<!DOCTYPE x><GPIF/>'):
            with self.subTest(data=data), self.assertRaises(Unsupported):
                candidates(data, replace(self.observation, gpif_sha256=hashlib.sha256(data).hexdigest()))
        self.root.find("./Notes/Note/Properties/Property[@name='Fret']/Fret").set('unknown', '1')
        with self.assertRaises(Unsupported): self.run_probe()

    def test_unknown_articulation_key_and_automation_are_rejected(self):
        mutations = [
            lambda r: r.find('./Notes/Note/InstrumentArticulation').set('unknown', '1'),
            lambda r: ET.SubElement(r.find('./Notes/Note/InstrumentArticulation'), 'Unknown'),
            lambda r: r.find('./MasterBars/MasterBar/Key').set('unknown', '1'),
            lambda r: ET.SubElement(r.find('./MasterBars/MasterBar/Key'), 'Sharps').__setattr__('text', 'unknown'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./Tracks/Track'), 'Automations'), 'UnknownPitchAutomation'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./MasterTrack'), 'Automations'), 'UnknownPitchAutomation'),
            lambda r: r.find('./Beats/Beat/Rhythm').set('unknown', '1'),
            lambda r: r.set('unknown', '1'),
            lambda r: r.find('./Tracks/Track').set('unknown', '1'),
            lambda r: r.find('./Tracks/Track/Transpose').set('unknown', '1'),
            lambda r: ET.SubElement(r.find('./Tracks/Track/Transpose'), 'UnknownTransposition'),
            lambda r: r.find('./Tracks/Track/Staves/Staff').set('unknown', '1'),
            lambda r: r.find('./Bars/Bar').set('unknown', '1'),
            lambda r: r.find('./Voices/Voice').set('unknown', '1'),
            lambda r: r.find('./Rhythms/Rhythm').set('unknown', '1'),
            lambda r: r.find('./Rhythms/Rhythm/NoteValue').set('unknown', '1'),
            lambda r: r.find('./MasterTrack').set('unknown', '1'),
            lambda r: r.find("./Tracks/Track/Staves/Staff/Properties/Property[@name='Tuning']").set('unknown', '1'),
            lambda r: ET.SubElement(r.find("./Tracks/Track/Staves/Staff/Properties/Property[@name='Tuning']"), 'UnknownPitch'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./Tracks/Track'), 'Sounds'), 'UnknownSoundPitchChange'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./Tracks/Track/Staves/Staff/Properties'), 'Property',
                                                {'name': 'ChordCollection'}), 'UnknownPlaybackEffect'),
            lambda r: ET.SubElement(r.find('./MasterBars/MasterBar'), 'Time', {'unknown': '1'}).__setattr__('text', '4/4'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./MasterBars/MasterBar'), 'Time'), 'Unknown').__setattr__('text', '4/4'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./MasterTrack'), 'RSE'), 'Unknown'),
            lambda r: ET.SubElement(ET.SubElement(r.find('./Beats/Beat'), 'Dynamic'), 'Unknown'),
            lambda r: ET.SubElement(r.find('./Beats/Beat'), 'XProperties', {'unknown': '1'}),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.root = synthetic()
                mutate(self.root)
                with self.assertRaises(Unsupported):
                    self.run_probe()

    def test_unknown_elements_and_attributes_inside_reference_lists_are_rejected(self):
        paths = ('./MasterBars/MasterBar/Bars', './Bars/Bar/Voices',
                 './Voices/Voice/Beats', './Beats/Beat/Notes', './MasterTrack/Tracks')
        for path in paths:
            for add_child in (True, False):
                with self.subTest(path=path, add_child=add_child):
                    self.root = synthetic()
                    node = self.root.find(path)
                    if add_child:
                        ET.SubElement(node, 'UnknownReference').text = '0'
                    else:
                        node.set('unknown', '0')
                    with self.assertRaises(Unsupported):
                        self.run_probe()

    def test_observation_must_match_exact_gpif_bytes(self):
        xml = ET.tostring(self.root)
        self.assertTrue(candidates(xml, self.observation))
        with self.assertRaises(Unsupported):
            candidates(xml + b' ', self.observation)
        with self.assertRaises(Unsupported):
            candidates(xml, replace(self.observation, gpif_sha256='0' * 64))


if __name__ == '__main__':
    unittest.main()

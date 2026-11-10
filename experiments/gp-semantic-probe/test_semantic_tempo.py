"""Compare the narrow tempo subset with the bundled importer on a fixture."""

from dataclasses import replace
import hashlib
from io import BytesIO
from pathlib import Path
import sys
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile

import semantic
from semantic import ImportedTempo, Unsupported, _master_tempos, candidates
from test_semantic import observed, synthetic


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/gp-memory-surgery'))
from archive_edit import SCORE, replace_score
from observation import observe, semantic_observation
sys.path.pop(0)


def append_tempo(owner, *, bar='0', position='0', bpm='120', visible='true'):
    container = owner.find('Automations')
    if container is None:
        container = ET.SubElement(owner, 'Automations')
    node = ET.SubElement(container, 'Automation')
    for key, value in (('Type', 'Tempo'), ('Linear', 'false'), ('Bar', bar),
                       ('Position', position), ('Visible', visible), ('Value', bpm + ' 2')):
        ET.SubElement(node, key).text = value
    return node


def evidence_from_fixture():
    """Inject a second event into a public fixture and read it with alphaTab."""
    source = (ROOT / 'RiffLoopTests/Fixtures/transport.gp').read_bytes()
    with ZipFile(BytesIO(source)) as archive:
        gpif = archive.read(SCORE)
    marker = b'</Automations></MasterTrack>'
    assert gpif.count(marker) == 1
    extra = (b'<Automation><Type>Tempo</Type><Linear>false</Linear><Bar>1</Bar>'
             b'<Position>0.25</Position><Visible>false</Visible><Value>90 2</Value></Automation>')
    modified_gpif = gpif.replace(marker, extra + marker, 1)
    modified = replace_score(source, modified_gpif)
    view, = observe(modified)
    result = []
    for bar, item in enumerate(view['bars']):
        for tempo in item['tempo']:
            assert tempo['type'] == 0 and tempo['syncPointValue'] is None
            result.append(ImportedTempo(bar, tempo['value'], tempo['ratioPosition'],
                                        tempo['isLinear'], tempo['isVisible'], tempo['text'],
                                        tempo['type'], tempo['syncPointValue']))
    bridged = semantic_observation(view, semantic, hashlib.sha256(modified_gpif).hexdigest())
    assert bridged.tempos == tuple(result)
    return tuple(result)


class TempoObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.importer_tempos = evidence_from_fixture()

    def setUp(self):
        self.root = synthetic()
        self.master = self.root.find('MasterTrack')
        self.first = append_tempo(self.master)

    def check(self, tempos):
        xml = ET.tostring(self.root)
        observation = replace(observed(), gpif_sha256=hashlib.sha256(xml).hexdigest(), tempos=tempos)
        return candidates(xml, observation)

    def test_one_tempo_matches_bundled_importer(self):
        first = self.importer_tempos[0]
        self.assertEqual(first, ImportedTempo(0, 120, 0, False, True, '', 0, None))
        self.assertEqual(len(self.check((first,))), 2)
        with self.assertRaisesRegex(Unsupported, 'evidence'):
            self.check(None)
        for altered in (replace(first, bpm=121), replace(first, ratio_position=.25),
                        replace(first, is_visible=False), replace(first, text='changed'),
                        replace(first, type_id=4), replace(first, sync_point_value={'offset': 0})):
            with self.subTest(altered=altered), self.assertRaises(Unsupported):
                self.check((altered,))

    def test_missing_observation_is_rejected_even_without_a_tempo_node(self):
        self.master.remove(self.master.find('Automations'))
        with self.assertRaisesRegex(Unsupported, 'evidence'):
            self.check(None)
        self.assertEqual(len(self.check(())), 2)
        with self.assertRaisesRegex(Unsupported, 'unexpected observed tempo'):
            self.check((self.importer_tempos[0],))

    def test_second_bar_position_and_bpm_match_bundled_importer(self):
        self.assertEqual(self.importer_tempos, (ImportedTempo(0, 120, 0, False, True, '', 0, None),
                                                ImportedTempo(1, 90, .25, False, False, '', 0, None)))
        append_tempo(self.master, bar='1', position='0.25', bpm='90', visible='false')
        _master_tempos(self.master, replace(observed(), tempos=self.importer_tempos), 2)
        bad = (self.importer_tempos[0], replace(self.importer_tempos[1], bpm=91))
        with self.assertRaises(Unsupported):
            _master_tempos(self.master, replace(observed(), tempos=bad), 2)

    def test_unknown_fields_missing_evidence_and_implicit_default_are_rejected(self):
        first = self.importer_tempos[0]
        mutations = [
            lambda node: node.find('Type').__setattr__('text', 'Sound'),
            lambda node: node.find('Linear').__setattr__('text', 'true'),
            lambda node: node.find('Bar').__setattr__('text', '1'),
            lambda node: node.find('Position').__setattr__('text', '0.25'),
            lambda node: node.find('Position').__setattr__('text', '1.0'),
            lambda node: node.find('Position').__setattr__('text', 'NaN'),
            lambda node: node.find('Position').__setattr__('text', '1e-3'),
            lambda node: node.find('Visible').__setattr__('text', 'unknown'),
            lambda node: node.find('Value').__setattr__('text', '120 3'),
            lambda node: node.find('Value').__setattr__('text', '0 2'),
            lambda node: ET.SubElement(node, 'Text').__setattr__('text', 'unverified'),
            lambda node: node.set('unknown', '1'),
            lambda node: node.find('Value').set('unknown', '1'),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp()
                mutate(self.first)
                with self.assertRaises(Unsupported):
                    self.check((first,))
        self.setUp()
        append_tempo(self.master)
        with self.assertRaises(Unsupported):
            self.check((first,))
        self.setUp()
        with self.assertRaises(Unsupported):
            self.check((first, first))
        self.setUp()
        ET.SubElement(self.master, 'Automations')
        with self.assertRaises(Unsupported):
            self.check((first,))
        self.setUp()
        self.master.find('Automations').tail = 'unknown'
        with self.assertRaises(Unsupported):
            self.check((first,))
        self.setUp()
        with self.assertRaises(Unsupported):
            self.check((first, replace(first, bar_index=2)))


if __name__ == '__main__':
    unittest.main()

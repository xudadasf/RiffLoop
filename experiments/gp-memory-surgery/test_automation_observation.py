"""Synthetic automation checks for the local importer snapshot only."""

from io import BytesIO
import json
from pathlib import Path
import subprocess
import unittest
from zipfile import ZipFile

from archive_edit import SCORE, replace_score
from observation import observe


FIXTURE = Path(__file__).resolve().parents[2] / 'RiffLoopTests/Fixtures/transport.gp'


def with_automations(*, frame_offset, bank_msb, program, tempo_label=None):
    """Create a synthetic variation in memory; never read or write user files."""
    source = FIXTURE.read_bytes()
    with ZipFile(BytesIO(source)) as archive:
        score = archive.read(SCORE)
    if tempo_label is not None:
        original = b'<Visible>true</Visible><Value>120 2</Value>'
        changed = (b'<Visible>false</Visible><Value>120 2</Value><Text>' +
                   tempo_label.encode('ascii') + b'</Text>')
        assert score.count(original) == 1
        score = score.replace(original, changed, 1)
    master_end = b'</Automations></MasterTrack>'
    sync = (b'<Automation><Type>SyncPoint</Type><Linear>false</Linear><Bar>1</Bar>'
            b'<Position>0.25</Position><Visible>true</Visible><Value>'
            b'<BarIndex>1</BarIndex><BarOccurrence>1</BarOccurrence><FrameOffset>' +
            str(frame_offset).encode('ascii') + b'</FrameOffset></Value></Automation>')
    assert score.count(master_end) == 1
    score = score.replace(master_end, sync + master_end, 1)

    extra_sound = (b'<Sound><Name><![CDATA[Synthetic]]></Name><Path><![CDATA[Midi/Synthetic]]></Path>'
                   b'<Role><![CDATA[Factory]]></Role><MIDI><LSB>1</LSB><MSB>' +
                   str(bank_msb).encode('ascii') + b'</MSB><Program>' +
                   str(program).encode('ascii') + b'</Program></MIDI></Sound>')
    assert score.count(b'</Sounds>') == 1
    score = score.replace(b'</Sounds>', extra_sound + b'</Sounds>', 1)
    sound = (b'<Automation><Type>Sound</Type><Linear>false</Linear><Bar>1</Bar>'
             b'<Position>0</Position><Visible>true</Visible>'
             b'<Value><![CDATA[Midi/Synthetic;Synthetic;Factory]]></Value></Automation>')
    track_end = b'</Automations></Track>'
    assert score.count(track_end) == 1
    score = score.replace(track_end, sound + track_end, 1)
    return replace_score(source, score)


class AutomationObservationTests(unittest.TestCase):
    def test_sync_point_and_bank_changes_are_observed_in_separate_contexts(self):
        original = with_automations(frame_offset=44100, bank_msb=2, program=41)
        changed_sync = with_automations(frame_offset=88200, bank_msb=2, program=41)
        changed_bank = with_automations(frame_offset=44100, bank_msb=3, program=41)
        a, b, c = observe(original, changed_sync, changed_bank)

        # SyncPoint and Bank both have type 4 in this alphaTab release; their
        # containing objects, not that shared numeric code, identify context.
        sync = a['bars'][1]['syncPoints']
        self.assertIsNone(a['bars'][2]['syncPoints'])
        self.assertEqual(len(sync), 1)
        self.assertEqual(sync[0]['type'], 4)
        self.assertEqual(sync[0]['ratioPosition'], 0.25)
        self.assertEqual(sync[0]['syncPointValue'], {'barOccurence': 1, 'millisecondOffset': 1000})
        self.assertEqual(b['bars'][1]['syncPoints'][0]['syncPointValue']['millisecondOffset'], 2000)
        self.assertEqual(a['bars'][1]['syncPoints'], c['bars'][1]['syncPoints'])

        beat = a['tracks'][0]['staves'][0]['bars'][1][0][0]['automations']
        self.assertEqual([(item['type'], item['value']) for item in beat], [(4, 257), (2, 41)])
        self.assertIsNone(beat[0]['syncPointValue'])
        self.assertEqual(beat, b['tracks'][0]['staves'][0]['bars'][1][0][0]['automations'])
        self.assertEqual(c['tracks'][0]['staves'][0]['bars'][1][0][0]['automations'][0]['value'], 385)

    def test_missing_and_empty_sync_point_lists_remain_distinct(self):
        root = FIXTURE.parents[2]
        script = r'''
const alpha = require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const { snapshot } = require('./experiments/gp-memory-surgery/observe.cjs');
const score = new alpha.model.Score();
score.addMasterBar(new alpha.model.MasterBar());
score.addMasterBar(new alpha.model.MasterBar());
score.masterBars[1].syncPoints = [];
process.stdout.write(JSON.stringify(snapshot(score).bars.map(bar => bar.syncPoints)));
'''
        output = subprocess.run(['node', '-e', script], cwd=root, check=True,
                                capture_output=True, encoding='utf-8', timeout=30).stdout
        self.assertEqual(json.loads(output), [None, []])

    def test_tempo_visibility_and_text_are_not_silently_ignored(self):
        original = with_automations(frame_offset=44100, bank_msb=2, program=41)
        changed = with_automations(frame_offset=44100, bank_msb=2, program=41, tempo_label='Practice')
        before, after = observe(original, changed)
        self.assertEqual(before['bars'][0]['tempo'][0]['value'], after['bars'][0]['tempo'][0]['value'])
        self.assertEqual(before['bars'][0]['tempo'][0]['isVisible'], True)
        self.assertEqual(before['bars'][0]['tempo'][0]['text'], '')
        self.assertEqual(after['bars'][0]['tempo'][0]['isVisible'], False)
        self.assertEqual(after['bars'][0]['tempo'][0]['text'], 'Practice')


if __name__ == '__main__':
    unittest.main()

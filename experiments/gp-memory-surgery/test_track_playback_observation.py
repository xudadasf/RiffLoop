"""Check initial track playback settings using only a synthetic fixture."""

from io import BytesIO
from pathlib import Path
import unittest
from zipfile import ZipFile

from archive_edit import SCORE, replace_score
from observation import observe


FIXTURE = Path(__file__).resolve().parents[2] / 'RiffLoopTests/Fixtures/transport.gp'


def changed_profile(*, bank=False, channels=False):
    source = FIXTURE.read_bytes()
    with ZipFile(BytesIO(source)) as archive:
        score = archive.read(SCORE)
    # Remove the fixture's explicit Sound event so the initial track setting
    # is tested independently of the already-observed beat automations.
    old_events = (b'<Automations><Automation><Type>Sound</Type><Linear>false</Linear><Bar>0</Bar>'
                  b'<Position>0</Position><Visible>true</Visible><Value><![CDATA['
                  b'Midi/25;Track_0_Initial;Factory]]></Value></Automation></Automations></Track>')
    assert score.count(old_events) == 1
    score = score.replace(old_events, b'<Automations></Automations></Track>', 1)
    if bank:
        old = b'<MIDI><LSB>0</LSB><MSB>0</MSB><Program>25</Program></MIDI>'
        new = b'<MIDI><LSB>1</LSB><MSB>2</MSB><Program>25</Program></MIDI>'
        assert score.count(old) == 1
        score = score.replace(old, new, 1)
    if channels:
        old = b'<Port>1</Port><PrimaryChannel>0</PrimaryChannel><SecondaryChannel>1</SecondaryChannel>'
        new = b'<Port>2</Port><PrimaryChannel>2</PrimaryChannel><SecondaryChannel>3</SecondaryChannel>'
        assert score.count(old) == 1
        score = score.replace(old, new, 1)
    return replace_score(source, score)


class TrackPlaybackObservationTests(unittest.TestCase):
    def test_initial_bank_change_is_visible_even_when_program_is_unchanged(self):
        before, after = observe(changed_profile(), changed_profile(bank=True))
        old, new = before['tracks'][0]['playback'], after['tracks'][0]['playback']
        self.assertEqual((old['program'], new['program']), (25, 25))
        self.assertEqual((old['bank'], new['bank']), (0, 257))
        self.assertEqual({k: v for k, v in old.items() if k != 'bank'},
                         {k: v for k, v in new.items() if k != 'bank'})
        self.assertEqual(before['tracks'][0]['staves'], after['tracks'][0]['staves'])

    def test_port_and_channels_are_visible_without_affecting_notes(self):
        before, after = observe(changed_profile(), changed_profile(channels=True))
        old, new = before['tracks'][0]['playback'], after['tracks'][0]['playback']
        self.assertEqual((old['port'], old['primaryChannel'], old['secondaryChannel']), (1, 0, 1))
        self.assertEqual((new['port'], new['primaryChannel'], new['secondaryChannel']), (2, 2, 3))
        self.assertEqual(before['tracks'][0]['staves'], after['tracks'][0]['staves'])


if __name__ == '__main__':
    unittest.main()

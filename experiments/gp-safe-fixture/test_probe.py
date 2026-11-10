import base64
from collections import Counter
import hashlib
from io import BytesIO
import json
import struct
import subprocess
import sys
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile

from probe import FIXTURE, FIXTURE_HASH, OLD_NOTE, NEW_NOTE, SCORE, edit_known_fixture

sys.path.insert(0, str(FIXTURE.parents[2] / 'experiments/gp-archive-safety'))
from archive_guard import verify_resources
sys.path.pop(0)


def central_entries(data):
    end = data.rfind(b'PK\x05\x06')
    size, position = struct.unpack_from('<II', data, end + 12)
    stop = position + size
    result = {}
    while position < stop:
        if data[position:position + 4] != b'PK\x01\x02':
            raise ValueError('Bad central header')
        name_len, extra_len, comment_len = struct.unpack_from('<HHH', data, position + 28)
        end_entry = position + 46 + name_len + extra_len + comment_len
        name = data[position + 46:position + 46 + name_len].decode('utf-8')
        result[name] = data[position:end_entry]
        position = end_entry
    return result


class FixtureCandidateTests(unittest.TestCase):
    def setUp(self):
        self.original = FIXTURE.read_bytes()
        self.before_hash = hashlib.sha256(self.original).hexdigest()
        self.candidate = edit_known_fixture(self.original)

    def test_fixture_hash_gate_and_original_unchanged(self):
        self.assertEqual(self.before_hash, FIXTURE_HASH)
        self.assertEqual(hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), FIXTURE_HASH)
        with self.assertRaises(ValueError):
            edit_known_fixture(self.original + b'changed')
        with self.assertRaises(ValueError):
            edit_known_fixture(b'')

    def test_unique_occurrence_and_both_pitch_representations(self):
        with ZipFile(BytesIO(self.original)) as old, ZipFile(BytesIO(self.candidate)) as new:
            before = old.read(SCORE)
            after = new.read(SCORE)
        self.assertEqual(before.count(OLD_NOTE), 1)
        self.assertEqual(after, before.replace(OLD_NOTE, NEW_NOTE, 1))
        root = ET.fromstring(after)
        old_root = ET.fromstring(before)
        before_rhythms = [(beat.get('id'), beat.find('Rhythm').get('ref'))
                          for beat in old_root.findall('./Beats/Beat')]
        after_rhythms = [(beat.get('id'), beat.find('Rhythm').get('ref'))
                         for beat in root.findall('./Beats/Beat')]
        self.assertEqual(after_rhythms, before_rhythms)
        self.assertEqual(Counter(ref for _, ref in before_rhythms), {'0': 16})
        self.assertEqual(ET.tostring(root.find('Rhythms')), ET.tostring(old_root.find('Rhythms')))
        # All four links in the chosen position are unique in this exact fixture.
        for parent, field in [('MasterBars', 'Bars'), ('Bars', 'Voices'),
                              ('Voices', 'Beats'), ('Beats', 'Notes')]:
            counts = Counter(ref for node in root.find(parent) for ref in (node.findtext(field) or '').split())
            self.assertEqual(counts['0'], 1, parent)
        note = root.find("./Notes/Note[@id='0']")
        properties = note.find('Properties')
        self.assertEqual(properties.findtext("./Property[@name='Fret']/Fret"), '4')
        self.assertEqual(properties.findtext("./Property[@name='Midi']/Number"), '59')
        self.assertEqual(properties.findtext("./Property[@name='String']/String"), '3')
        for name, octave in [('ConcertPitch', '4'), ('TransposedPitch', '5')]:
            pitch = properties.find(f"./Property[@name='{name}']/Pitch")
            self.assertEqual((pitch.findtext('Step'), pitch.findtext('Accidental') or '',
                              pitch.findtext('Octave')), ('B', '', octave))
        track = root.find('./Tracks/Track')
        self.assertEqual(track.findtext('./Transpose/Chromatic'), '0')
        self.assertEqual(track.findtext('./Transpose/Octave'), '-1')
        self.assertEqual(track.findtext("./Staves/Staff/Properties/Property[@name='Tuning']/Pitches"),
                         '40 45 50 55 59 64')
        self.assertEqual(track.findtext("./Staves/Staff/Properties/Property[@name='CapoFret']/Fret"), '0')

    def test_other_zip_entries_and_metadata_are_preserved(self):
        verify_resources(self.original, self.candidate)
        with ZipFile(BytesIO(self.original)) as old, ZipFile(BytesIO(self.candidate)) as new:
            self.assertEqual(new.testzip(), None)
            self.assertEqual(old.namelist(), new.namelist())
            self.assertEqual(old.comment, new.comment)
            for info in old.infolist():
                updated = new.getinfo(info.filename)
                for key in ('filename', 'compress_type', 'flag_bits', 'date_time', 'create_system',
                            'create_version', 'extract_version', 'external_attr', 'internal_attr',
                            'extra', 'comment', 'header_offset'):
                    self.assertEqual(getattr(info, key), getattr(updated, key), (info.filename, key))
                if info.filename != SCORE:
                    self.assertEqual(old.read(info), new.read(updated))
                    self.assertEqual((info.CRC, info.compress_size, info.file_size),
                                     (updated.CRC, updated.compress_size, updated.file_size))
            score_info = old.getinfo(SCORE)
            # Every previous local header and compressed member is byte-identical.
            self.assertEqual(self.original[:score_info.header_offset], self.candidate[:score_info.header_offset])
            self.assertTrue(score_info.flag_bits & 0x800)
            self.assertEqual(new.getinfo(SCORE).flag_bits, score_info.flag_bits)
            old_headers, new_headers = central_entries(self.original), central_entries(self.candidate)
            for name in old_headers.keys() - {SCORE}:
                self.assertEqual(old_headers[name], new_headers[name], name)
            # In the score directory header, only CRC and sizes may change.
            self.assertEqual(old_headers[SCORE][:16], new_headers[SCORE][:16])
            self.assertEqual(old_headers[SCORE][28:], new_headers[SCORE][28:])

    def test_bundled_importer_reads_only_intended_selected_changes(self):
        payload = json.dumps([base64.b64encode(item).decode('ascii')
                              for item in (self.original, self.candidate)])
        run = subprocess.run(['node', str(FIXTURE.parents[2] / 'experiments/gp-safe-fixture/inspect.cjs')],
                             input=payload, text=True, capture_output=True, check=True, timeout=30)
        before, after = json.loads(run.stdout)
        self.assertEqual(before['masterBarTicks'], [[0, 3840], [3840, 7680], [7680, 11520], [11520, 15360]])
        for bar in before['tracks'][0][0]['bars']:
            self.assertEqual(len(bar), 1)
            self.assertEqual([beat['playbackTicks'] for beat in bar[0]],
                             [[0, 960], [960, 960], [1920, 960], [2880, 960]])
            self.assertEqual([beat['displayTicks'] for beat in bar[0]],
                             [[0, 960], [960, 960], [1920, 960], [2880, 960]])
            self.assertEqual([beat['tuplets'] for beat in bar[0]], [[-1, -1]] * 4)
        first = before['tracks'][0][0]['bars'][0][0][0]['notes'][0]
        self.assertEqual(first, {'string': 4, 'fret': 3, 'realValue': 58, 'accidentalMode': 3})
        changed = after['tracks'][0][0]['bars'][0][0][0]['notes'][0]
        self.assertEqual(changed, {'string': 4, 'fret': 4, 'realValue': 59, 'accidentalMode': 2})
        # The imported selected values and all observed note/timing fields match.
        after['tracks'][0][0]['bars'][0][0][0]['notes'][0] = first
        self.assertEqual(after, before)


if __name__ == '__main__':
    unittest.main()

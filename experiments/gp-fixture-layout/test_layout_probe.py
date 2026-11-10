import base64
from io import BytesIO
import json
import struct
import subprocess
import unittest
from zipfile import ZipFile

from layout_probe import (FIXTURE, OLD_NOTE, NEW_NOTE, ROOT, SCORE, SCENARIOS,
                          edit_synthetic, synthetic_archive, verify_resources)
from archive_guard import UnsafeArchive


def local_records(data):
    with ZipFile(BytesIO(data)) as archive:
        entries = sorted(archive.infolist(), key=lambda item: item.header_offset)
        ends = [item.header_offset for item in entries[1:]] + [archive.start_dir]
        return {item.filename: data[item.header_offset:end] for item, end in zip(entries, ends)}


def central_records(data):
    end = data.rfind(b'PK\x05\x06')
    size, position = struct.unpack_from('<II', data, end + 12)
    stop = position + size
    records = {}
    while position < stop:
        if data[position:position + 4] != b'PK\x01\x02':
            raise ValueError('Bad central header')
        name_len, extra_len, comment_len = struct.unpack_from('<HHH', data, position + 28)
        finish = position + 46 + name_len + extra_len + comment_len
        name = data[position + 46:position + 46 + name_len].decode('utf-8')
        records[name] = data[position:finish]
        position = finish
    return records


class SyntheticLayoutTests(unittest.TestCase):
    def test_all_layouts_preserve_resources_and_gpif_outside_target(self):
        for scenario in SCENARIOS:
            with self.subTest(scenario=scenario):
                source = synthetic_archive(*scenario)
                result = edit_synthetic(source, scenario)
                verify_resources(source, result, allow_reversed_descriptor=scenario[0] == 'reversed')
                before_records, after_records = local_records(source), local_records(result)
                self.assertEqual(before_records.keys(), after_records.keys())
                for name in before_records.keys() - {SCORE}:
                    self.assertEqual(before_records[name], after_records[name], name)
                old_central, new_central = central_records(source), central_records(result)
                self.assertEqual(old_central.keys(), new_central.keys())
                for name in old_central:
                    if name == SCORE:
                        # Only CRC and compressed/uncompressed sizes may differ.
                        self.assertEqual(old_central[name][:16], new_central[name][:16])
                        self.assertEqual(old_central[name][28:], new_central[name][28:])
                    else:
                        # Relative local offset may shift; all other bytes are retained.
                        self.assertEqual(old_central[name][:42], new_central[name][:42])
                        self.assertEqual(old_central[name][46:], new_central[name][46:])
                with ZipFile(BytesIO(source)) as before, ZipFile(BytesIO(result)) as after:
                    self.assertEqual(after.testzip(), None)
                    self.assertEqual(before.namelist(), after.namelist())
                    self.assertEqual(after.read(SCORE), before.read(SCORE).replace(OLD_NOTE, NEW_NOTE, 1))
                    self.assertLess(before.getinfo(SCORE).header_offset,
                                    before.getinfo('Content/tail.bin').header_offset)
                    self.assertLess(after.getinfo(SCORE).header_offset,
                                    after.getinfo('Content/tail.bin').header_offset)
                    for name in before.namelist():
                        self.assertEqual(before.getinfo(name).flag_bits, after.getinfo(name).flag_bits)
                        if name != SCORE:
                            self.assertEqual(before.read(name), after.read(name))

    def test_reverse_descriptor_needs_explicit_opt_in(self):
        for scenario in SCENARIOS:
            if scenario[0] != 'reversed':
                continue
            source = synthetic_archive(*scenario)
            result = edit_synthetic(source, scenario)
            with self.assertRaises(UnsafeArchive):
                verify_resources(source, result)
            verify_resources(source, result, allow_reversed_descriptor=True)

    def test_bundled_importer_compares_notes_and_timeline(self):
        archive_pairs = []
        for scenario in SCENARIOS:
            source = synthetic_archive(*scenario)
            result = edit_synthetic(source, scenario)
            archive_pairs.append((source, result))
        payload = [base64.b64encode(item).decode('ascii') for pair in archive_pairs for item in pair]
        process = subprocess.run(['node', str(ROOT / 'experiments/gp-safe-fixture/inspect.cjs')],
                                 input=json.dumps(payload), capture_output=True, text=True,
                                 timeout=30, check=True)
        views = json.loads(process.stdout)
        self.assertEqual(len(views), 2 * len(SCENARIOS))
        for index, scenario in enumerate(SCENARIOS):
            with self.subTest(scenario=scenario):
                before, after = views[2 * index:2 * index + 2]
                old_note = before['tracks'][0][0]['bars'][0][0][0]['notes'][0]
                new_note = after['tracks'][0][0]['bars'][0][0][0]['notes'][0]
                self.assertEqual(old_note, {'string': 4, 'fret': 3, 'realValue': 58, 'accidentalMode': 3})
                self.assertEqual(new_note, {'string': 4, 'fret': 4, 'realValue': 59, 'accidentalMode': 2})
                after['tracks'][0][0]['bars'][0][0][0]['notes'][0] = old_note
                self.assertEqual(before, after)

    def test_only_exact_generated_bytes_and_known_scenario_are_accepted(self):
        for scenario in SCENARIOS:
            source = synthetic_archive(*scenario)
            with self.assertRaises(ValueError):
                edit_synthetic(source + b'?', scenario)
        with self.assertRaises(ValueError):
            edit_synthetic(FIXTURE.read_bytes(), SCENARIOS[0])
        with self.assertRaises(ValueError):
            synthetic_archive('normal', False, True)
        with self.assertRaises(ValueError):
            edit_synthetic(synthetic_archive(*SCENARIOS[0]), SCENARIOS[1])


if __name__ == '__main__':
    unittest.main()

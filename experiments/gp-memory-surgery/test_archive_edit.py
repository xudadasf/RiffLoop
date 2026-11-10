from io import BytesIO, UnsupportedOperation
from pathlib import Path
import struct
import sys
import unittest
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from archive_edit import ROOT, SCORE, Limits, UnsafeArchive, replace_score, verify_resources

sys.path.insert(0, str(ROOT / 'experiments/gp-fixture-layout'))
from layout_probe import FIXTURE, SCENARIOS, OLD_NOTE, NEW_NOTE, synthetic_archive


def local_records(data):
    with ZipFile(BytesIO(data)) as archive:
        entries = sorted(archive.infolist(), key=lambda item: item.header_offset)
        ends = [item.header_offset for item in entries[1:]] + [archive.start_dir]
        return {item.filename: data[item.header_offset:end] for item, end in zip(entries, ends)}


class ArchiveEditTests(unittest.TestCase):
    def test_five_synthetic_layouts_preserve_resources(self):
        for scenario in SCENARIOS:
            with self.subTest(scenario=scenario):
                source = synthetic_archive(*scenario)
                with ZipFile(BytesIO(source)) as archive:
                    score = archive.read(SCORE)
                replacement = score.replace(OLD_NOTE, NEW_NOTE, 1)
                reverse = scenario[0] == 'reversed'
                result = replace_score(source, replacement, allow_reversed_descriptor=reverse)
                verify_resources(source, result, allow_reversed_descriptor=reverse)
                with ZipFile(BytesIO(result)) as archive:
                    self.assertEqual(archive.read(SCORE), replacement)
                before, after = local_records(source), local_records(result)
                self.assertEqual(before.keys(), after.keys())
                for name in before.keys() - {SCORE}:
                    self.assertEqual(before[name], after[name])

    def test_reversed_descriptors_require_explicit_choice(self):
        for scenario in SCENARIOS:
            if scenario[0] != 'reversed':
                continue
            source = synthetic_archive(*scenario)
            with ZipFile(BytesIO(source)) as archive:
                replacement = archive.read(SCORE).replace(OLD_NOTE, NEW_NOTE, 1)
            with self.assertRaises(UnsafeArchive):
                replace_score(source, replacement)

    def test_invalid_input_and_limits_rejected(self):
        source = synthetic_archive(*SCENARIOS[0])
        with self.assertRaises((UnsafeArchive, ValueError)):
            replace_score(source + b'extra', b'changed')
        with self.assertRaises(UnsafeArchive):
            replace_score(source, b'a' * 100, limits=Limits(max_member_bytes=99))
        with self.assertRaises(TypeError):
            replace_score(source, 'not bytes')

    def test_unknown_extra_field_is_rejected(self):
        output = BytesIO()
        with ZipFile(output, 'w') as archive:
            info = ZipInfo(SCORE)
            info.compress_type = ZIP_DEFLATED
            info.extra = b'\x34\x12\x00\x00'
            archive.writestr(info, b'score')
        with self.assertRaisesRegex(UnsafeArchive, 'extra fields'):
            replace_score(output.getvalue(), b'changed')

    def test_common_signature_or_manifest_indicators_are_rejected(self):
        indicators = ('META-INF/signature.p7s', 'meta-inf/MANIFEST.MF', 'META-INF/Signer.SF',
                      'META-INF/Signer.RSA', 'Content/DigitalSignature.xml', 'Content/file.sig')
        for indicator in indicators:
            with self.subTest(indicator=indicator):
                output = BytesIO()
                with ZipFile(output, 'w', compression=ZIP_DEFLATED) as archive:
                    archive.writestr(SCORE, b'score')
                    archive.writestr(indicator, b'signature data')
                with self.assertRaisesRegex(UnsafeArchive, 'signature or signed manifest'):
                    replace_score(output.getvalue(), b'changed')

    def test_ambiguous_descriptor_order_is_not_guessed(self):
        class Unseekable(BytesIO):
            def seekable(self):
                return False

            def seek(self, *args):
                raise UnsupportedOperation('not seekable')

        # This fixed sequence has identical uncompressed/deflate lengths.
        score = bytes([1, 1, 2, 1, 0, 0, 1, 2, 2, 3, 0, 3, 2, 3, 2, 3, 3, 0, 0])
        output = Unseekable()
        with ZipFile(output, 'w', compression=ZIP_DEFLATED) as archive:
            archive.writestr(SCORE, score)
        with ZipFile(BytesIO(output.getvalue())) as archive:
            info = archive.getinfo(SCORE)
            self.assertEqual(info.file_size, info.compress_size)
            self.assertTrue(info.flag_bits & 8)
        with self.assertRaisesRegex(UnsafeArchive, 'ambiguous'):
            replace_score(output.getvalue(), b'Z' * 100, allow_reversed_descriptor=True)

    def test_descriptor_populated_local_fields_are_updated_without_changing_zero_fields(self):
        for scenario in SCENARIOS:
            if scenario[0] is None:
                continue
            with self.subTest(scenario=scenario):
                source = bytearray(synthetic_archive(*scenario))
                with ZipFile(BytesIO(source)) as archive:
                    info = archive.getinfo(SCORE)
                    replacement = archive.read(SCORE).replace(OLD_NOTE, NEW_NOTE, 1)
                # Bit 3 permits each local field to be populated or zero. The
                # replacement should preserve this choice, not stale values.
                struct.pack_into('<III', source, info.header_offset + 14,
                                 info.CRC, info.compress_size, 0)
                reverse = scenario[0] == 'reversed'
                verify_resources(bytes(source), bytes(source), allow_reversed_descriptor=reverse)
                candidate = replace_score(bytes(source), replacement, allow_reversed_descriptor=reverse)
                with ZipFile(BytesIO(candidate)) as archive:
                    updated = archive.getinfo(SCORE)
                    self.assertEqual(archive.read(SCORE), replacement)
                    self.assertEqual(struct.unpack_from('<III', candidate, updated.header_offset + 14),
                                     (updated.CRC, updated.compress_size, 0))

    def test_invalid_baseline_never_produces_a_candidate(self):
        source = bytearray(synthetic_archive(*SCENARIOS[0]))
        with ZipFile(BytesIO(source)) as archive:
            info = archive.getinfo(SCORE)
        # Local method conflicts with the central directory. Even an unchanged
        # score must not make a structurally inconsistent source acceptable.
        struct.pack_into('<H', source, info.header_offset + 8, 0)
        with self.assertRaises(UnsafeArchive):
            replace_score(bytes(source), b'score')

    def test_repository_fixture_source_remains_unmodified(self):
        original = FIXTURE.read_bytes()
        with ZipFile(BytesIO(original)) as archive:
            score = archive.read(SCORE)
        candidate = replace_score(original, score.replace(OLD_NOTE, NEW_NOTE, 1))
        verify_resources(original, candidate)
        self.assertEqual(FIXTURE.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()

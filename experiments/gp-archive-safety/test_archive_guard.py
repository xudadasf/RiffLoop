import io
from pathlib import Path
import struct
import unittest
import warnings
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo

from archive_guard import Limits, SCORE, UnsafeArchive, verify_resources


FIXTURE = Path(__file__).resolve().parents[2] / "RiffLoopTests/Fixtures/transport.gp"


def archive(entries, *, comment=b"", level=6):
    output = io.BytesIO()
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as zipped:
        zipped.comment = comment
        for name, content in entries:
            info = name if isinstance(name, ZipInfo) else ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            zipped.writestr(info, content, compress_type=ZIP_DEFLATED, compresslevel=level)
    return output.getvalue()


class ArchiveGuardTests(unittest.TestCase):
    def setUp(self):
        self.entries = [("VERSION", b"7"), (SCORE, b"<score/>"), ("Content/style", b"original")]
        self.original = archive(self.entries, comment=b"comment")

    def test_fixture_and_only_score_change_are_accepted(self):
        data = FIXTURE.read_bytes()
        verify_resources(data, data)
        changed = archive([(name, b"<updated/>" if name == SCORE else value)
                           for name, value in self.entries], comment=b"comment")
        verify_resources(self.original, changed)

    def test_resource_change_removal_reorder_and_archive_comment_are_rejected(self):
        cases = [
            archive(self.entries[:-1], comment=b"comment"),
            archive(self.entries[::-1], comment=b"comment"),
            archive(self.entries, comment=b"changed"),
            archive(self.entries[:-1] + [("Content/style", b"different")], comment=b"comment"),
        ]
        for candidate in cases:
            with self.subTest():
                with self.assertRaises(UnsafeArchive):
                    verify_resources(self.original, candidate)

    def test_duplicate_score_and_unsafe_paths_are_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            duplicate = archive(self.entries + [(SCORE, b"other")], comment=b"comment")
        for data in (duplicate, archive([(SCORE, b"x"), ("../other", b"x")]),
                     archive([(SCORE, b"x"), ("Content//other", b"x")]),
                     archive([(SCORE, b"x"), ("Content/./other", b"x")]),
                     archive([(SCORE, b"x"), ("CONTENT/SCORE.GPIF", b"x")]),
                     archive([(SCORE, b"x"), ("C:/other", b"x")])):
            with self.subTest():
                with self.assertRaises(UnsafeArchive):
                    verify_resources(data, data)

    def test_metadata_and_recompressed_resources_are_rejected(self):
        changed = ZipInfo("Content/style", (2021, 1, 1, 0, 0, 0))
        candidate = archive(self.entries[:-1] + [(changed, b"original")], comment=b"comment")
        with self.assertRaises(UnsafeArchive):
            verify_resources(self.original, candidate)
        long_entries = [("VERSION", b"7"), (SCORE, b"<score/>"),
                        ("Content/style", b"repeated style data" * 10000)]
        first = archive(long_entries, level=1)
        second = archive(long_entries, level=9)
        # Decompressed resources and metadata match, but compressed bytes differ.
        with self.assertRaises(UnsafeArchive):
            verify_resources(first, second)

    def test_unreadable_data_and_resource_limits_are_rejected(self):
        with self.assertRaises(UnsafeArchive):
            verify_resources(b"not a zip", b"not a zip")
        with self.assertRaises(UnsafeArchive):
            verify_resources(self.original, self.original, limits=Limits(max_entries=2))
        with self.assertRaises(UnsafeArchive):
            verify_resources(self.original, self.original, limits=Limits(max_member_bytes=2))
        with self.assertRaises(ValueError):
            verify_resources(self.original, self.original, limits=Limits(max_entries=0))

    def test_corrupted_score_is_rejected_even_when_both_inputs_match(self):
        output = io.BytesIO()
        with ZipFile(output, "w", compression=ZIP_STORED) as zipped:
            zipped.writestr(SCORE, b"SCORE_BODY")
        corrupted = output.getvalue().replace(b"SCORE_BODY", b"BROKENBODY", 1)
        with self.assertRaises(UnsafeArchive):
            verify_resources(corrupted, corrupted)

    def test_local_header_and_container_inconsistencies_are_rejected(self):
        cases = []
        for offset, value in ((6, 8), (8, 0), (14, 0)):
            candidate = bytearray(self.original)
            with ZipFile(io.BytesIO(candidate)) as zipped:
                start = zipped.getinfo(SCORE).header_offset
            struct.pack_into("<I" if offset == 14 else "<H", candidate, start + offset, value)
            cases.append(bytes(candidate))
        cases.extend([b"prefix" + self.original, self.original + b"trailing"])
        for candidate in cases:
            with self.subTest():
                with self.assertRaises(UnsafeArchive):
                    verify_resources(self.original, candidate)

    def test_descriptor_crc_and_central_volume_are_checked(self):
        class Stream(io.BytesIO):
            def seekable(self):
                return False

            def seek(self, *args):
                raise io.UnsupportedOperation("stream is not seekable")

        output = Stream()
        with ZipFile(output, "w", compression=ZIP_DEFLATED) as zipped:
            zipped.writestr(SCORE, b"<score/>")
        original = output.getvalue()
        verify_resources(original, original)
        with ZipFile(io.BytesIO(original)) as zipped:
            info = zipped.getinfo(SCORE)
            name_len, extra_len = struct.unpack_from("<HH", original, info.header_offset + 26)
            descriptor = info.header_offset + 30 + name_len + extra_len + info.compress_size
        self.assertEqual(original[descriptor:descriptor + 4], b"PK\x07\x08")
        # ZIP permits omitting the optional descriptor signature; the user's
        # local development samples include this form too.
        unsigned = bytearray(original[:descriptor] + original[descriptor + 4:])
        eocd = len(unsigned) - 22
        directory_offset = struct.unpack_from("<I", unsigned, eocd + 16)[0]
        struct.pack_into("<I", unsigned, eocd + 16, directory_offset - 4)
        verify_resources(bytes(unsigned), bytes(unsigned))
        with self.assertRaises(UnsafeArchive):
            verify_resources(original, bytes(unsigned))
        broken_unsigned = bytearray(unsigned)
        broken_unsigned[descriptor] ^= 1
        with self.assertRaises(UnsafeArchive):
            verify_resources(bytes(unsigned), bytes(broken_unsigned))
        broken = bytearray(original)
        broken[descriptor + 4] ^= 1
        with self.assertRaises(UnsafeArchive):
            verify_resources(original, bytes(broken))
        reversed_descriptor = bytearray(unsigned)
        crc, compressed, uncompressed = struct.unpack_from("<III", reversed_descriptor, descriptor)
        self.assertNotEqual(compressed, uncompressed)
        struct.pack_into("<III", reversed_descriptor, descriptor, crc, uncompressed, compressed)
        with self.assertRaises(UnsafeArchive):
            verify_resources(bytes(reversed_descriptor), bytes(reversed_descriptor))
        verify_resources(bytes(reversed_descriptor), bytes(reversed_descriptor), allow_reversed_descriptor=True)
        with self.assertRaises(UnsafeArchive):
            verify_resources(bytes(unsigned), bytes(reversed_descriptor), allow_reversed_descriptor=True)
        central = original.index(b"PK\x01\x02")
        broken = bytearray(original)
        struct.pack_into("<H", broken, central + 34, 1)
        with self.assertRaises(UnsafeArchive):
            verify_resources(original, bytes(broken))

    def test_unconsumed_compressed_bytes_are_rejected(self):
        for method in (ZIP_STORED, ZIP_DEFLATED):
            output = io.BytesIO()
            with ZipFile(output, "w", compression=method) as zipped:
                zipped.writestr(SCORE, b"<score/>")
            original = output.getvalue()
            with ZipFile(io.BytesIO(original)) as zipped:
                info = zipped.getinfo(SCORE)
                name_len, extra_len = struct.unpack_from("<HH", original, info.header_offset + 26)
                payload_end = info.header_offset + 30 + name_len + extra_len + info.compress_size
            candidate = bytearray(original[:payload_end] + b"XYZ" + original[payload_end:])
            central = candidate.index(b"PK\x01\x02")
            eocd = len(candidate) - 22
            struct.pack_into("<I", candidate, info.header_offset + 18, info.compress_size + 3)
            struct.pack_into("<I", candidate, central + 20, info.compress_size + 3)
            struct.pack_into("<I", candidate, eocd + 16, central)
            # The standard reader may ignore trailing compressed bytes.
            with ZipFile(io.BytesIO(candidate)) as zipped:
                self.assertEqual(zipped.read(SCORE), b"<score/>")
            with self.subTest(method=method), self.assertRaises(UnsafeArchive):
                verify_resources(original, bytes(candidate))

    def test_unsigned_descriptor_crc_matching_signature_is_unambiguous(self):
        import zlib

        class Stream(io.BytesIO):
            def seek(self, *args):
                raise io.UnsupportedOperation("stream is not seekable")

        data = bytes.fromhex("ac0a7ad5")
        self.assertEqual(zlib.crc32(data), 0x08074b50)
        output = Stream()
        with ZipFile(output, "w", compression=ZIP_STORED) as zipped:
            zipped.writestr(SCORE, data)
        signed = output.getvalue()
        with ZipFile(io.BytesIO(signed)) as zipped:
            info = zipped.getinfo(SCORE)
            n, x = struct.unpack_from("<HH", signed, info.header_offset + 26)
            descriptor = info.header_offset + 30 + n + x + info.compress_size
        unsigned = bytearray(signed[:descriptor] + signed[descriptor + 4:])
        eocd = len(unsigned) - 22
        directory_offset = struct.unpack_from("<I", unsigned, eocd + 16)[0]
        struct.pack_into("<I", unsigned, eocd + 16, directory_offset - 4)
        self.assertEqual(unsigned[descriptor:descriptor + 4], b"PK\x07\x08")
        verify_resources(bytes(unsigned), bytes(unsigned))


if __name__ == "__main__":
    unittest.main()

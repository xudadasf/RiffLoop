"""Experimental in-memory ZIP update. Never writes or overwrites a GP file.

This checks resource preservation only, not GPIF semantics or GP compatibility.
It is not a production editor and must not be used to save a user's score.
"""

from io import BytesIO
from pathlib import Path
import struct
import sys
import zlib
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/gp-archive-safety'))
from archive_guard import Limits, SCORE, UnsafeArchive, _contents, _local_members, verify_resources


def _descriptor(crc, compressed, size, order, signed):
    sizes = (compressed, size) if order == 'normal' else (size, compressed)
    return (b'PK\x07\x08' if signed else b'') + struct.pack('<III', crc, *sizes)


def _has_signature_indicator(name):
    """Recognize common signature/digest artifacts, not all possible signatures."""
    parts = name.casefold().split('/')
    base = parts[-1]
    return (base.startswith(('signature', 'digitalsignature')) or
            base.endswith(('.p7s', '.p7m', '.sig', '.signature')) or
            (parts[0] == 'meta-inf' and
             (base == 'manifest.mf' or base.endswith(('.sf', '.rsa', '.dsa', '.ec')))))


def replace_score(original, new_score, *, allow_reversed_descriptor=False, limits=Limits()):
    """Return modified archive bytes after strict in-memory checks, no IO.

    Extra fields, ZIP64, encryption and compressed score option bits are
    rejected because their effect on a score edit has not been established.
    Even success does not validate score semantics, signatures or playback.
    """
    if not isinstance(original, bytes) or not isinstance(new_score, bytes):
        raise TypeError('Expected bytes')
    if len(new_score) > limits.max_member_bytes:
        raise UnsafeArchive('replacement score too large')
    verify_resources(original, original, limits=limits,
                     allow_reversed_descriptor=allow_reversed_descriptor)
    with ZipFile(BytesIO(original)) as source:
        entries = _contents(source, limits)
        if any(_has_signature_indicator(item.filename) for item in entries):
            raise UnsafeArchive('possible signature or signed manifest')
        _, _, descriptors = _local_members(original, source, entries, allow_reversed_descriptor)
        info = source.getinfo(SCORE)
        if info.compress_type != 8 or info.flag_bits & 0x6:
            raise UnsafeArchive('unsupported score compression')
        if any(item.extra for item in entries):
            raise UnsafeArchive('unverified central extra fields')
        for item in entries:
            name_len, extra_len = struct.unpack_from('<HH', original, item.header_offset + 26)
            if extra_len:
                raise UnsafeArchive('unverified local extra fields')
        local = info.header_offset
        name_len, extra_len = struct.unpack_from('<HH', original, local + 26)
        data_start = local + 30 + name_len + extra_len
        ordered = sorted(entries, key=lambda entry: entry.header_offset)
        index = ordered.index(info)
        member_end = ordered[index + 1].header_offset if index + 1 < len(ordered) else source.start_dir
        order, signed = descriptors[SCORE]
        compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
        compressed = compressor.compress(new_score) + compressor.flush()
        crc = zlib.crc32(new_score)
        if order == 'either':
            if len(compressed) != len(new_score):
                raise UnsafeArchive('ambiguous descriptor order')
            order = 'normal'
        prefix = bytearray(original[:data_start])
        if order == 'none':
            struct.pack_into('<III', prefix, local + 14, crc, len(compressed), len(new_score))
            descriptor = b''
        else:
            # Bit 3 permits each local value to be zero or the actual value.
            # Keep each zero-vs-populated choice rather than silently changing it.
            old_header = struct.unpack_from('<III', prefix, local + 14)
            new_header = (crc, len(compressed), len(new_score))
            struct.pack_into('<III', prefix, local + 14,
                             *(new if old else 0 for old, new in zip(old_header, new_header)))
            descriptor = _descriptor(crc, len(compressed), len(new_score), order, signed)
        delta = len(compressed) - info.compress_size
        middle = original[member_end:source.start_dir]
        end_pos = len(original) - len(source.comment) - 22
        directory = bytearray(original[source.start_dir:end_pos])
        cursor = 0
        found = False
        for entry in entries:
            if directory[cursor:cursor + 4] != b'PK\x01\x02':
                raise UnsafeArchive('invalid central directory')
            name_len, extra_len, comment_len = struct.unpack_from('<HHH', directory, cursor + 28)
            end = cursor + 46 + name_len + extra_len + comment_len
            if end > len(directory):
                raise UnsafeArchive('truncated central directory')
            encoding = 'utf-8' if entry.flag_bits & 0x800 else 'cp437'
            name = bytes(directory[cursor + 46:cursor + 46 + name_len]).decode(encoding)
            old_offset = struct.unpack_from('<I', directory, cursor + 42)[0]
            if name != entry.orig_filename or old_offset != entry.header_offset:
                raise UnsafeArchive('central directory mismatch')
            if old_offset == 0xffffffff or entry.file_size >= 0xffffffff or entry.compress_size >= 0xffffffff:
                raise UnsafeArchive('ZIP64 not supported')
            if name == SCORE:
                struct.pack_into('<III', directory, cursor + 16, crc, len(compressed), len(new_score))
                found = True
            elif old_offset > local:
                if not 0 <= old_offset + delta < 0xffffffff:
                    raise UnsafeArchive('local offset overflow')
                struct.pack_into('<I', directory, cursor + 42, old_offset + delta)
            cursor = end
        if not found or cursor != len(directory):
            raise UnsafeArchive('incomplete central directory')
        end = bytearray(original[end_pos:])
        if not 0 <= source.start_dir + delta < 0xffffffff:
            raise UnsafeArchive('central directory offset overflow')
        struct.pack_into('<I', end, 16, source.start_dir + delta)
        candidate = bytes(prefix) + compressed + descriptor + middle + bytes(directory) + bytes(end)
    verify_resources(original, candidate, limits=limits,
                     allow_reversed_descriptor=allow_reversed_descriptor)
    return candidate

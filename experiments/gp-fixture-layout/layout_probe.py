"""Synthetic ZIP layout experiment, not a GP editor and not for user files."""

from io import BytesIO
import hashlib
from pathlib import Path
import struct
import sys
import zlib
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/gp-safe-fixture'))
sys.path.insert(0, str(ROOT / 'experiments/gp-archive-safety'))
from probe import FIXTURE, FIXTURE_HASH, OLD_NOTE, NEW_NOTE, SCORE
from archive_guard import verify_resources

# Score is deliberately in the middle, and at least one member follows it.
# Last tuple item reverses directory order independently of local order.
SCENARIOS = ((None, False, False), ('normal', False, False), ('normal', True, True),
             ('reversed', False, True), ('reversed', True, False))


def _deflate(data):
    encoder = zlib.compressobj(6, zlib.DEFLATED, -15)
    return encoder.compress(data) + encoder.flush()


def _descriptor(crc, compressed, size, order, signed):
    lengths = (compressed, size) if order == 'normal' else (size, compressed)
    return (b'PK\x07\x08' if signed else b'') + struct.pack('<III', crc, *lengths)


def synthetic_archive(order, signed, reverse_directory):
    """Build only a predetermined, wholly synthetic archive in memory."""
    if (order, signed, reverse_directory) not in SCENARIOS:
        raise ValueError('Unknown synthetic scenario')
    fixture = FIXTURE.read_bytes()
    if hashlib.sha256(fixture).hexdigest() != FIXTURE_HASH:
        raise ValueError('Unexpected repository fixture')
    with ZipFile(BytesIO(fixture)) as archive:
        score = archive.read(SCORE)
    if score.count(OLD_NOTE) != 1:
        raise ValueError('Unexpected synthetic score')
    entries = [('VERSION', b'8.0'), (SCORE, score), ('Content/tail.bin', b'synthetic-resource\x00' * 7)]
    local = bytearray()
    central = []
    # 2024-01-02 00:00:00, constant DOS metadata.
    date = (2024 - 1980) << 9 | 1 << 5 | 2
    for name, data in entries:
        name_bytes = name.encode('utf-8')
        zipped = _deflate(data)
        crc = zlib.crc32(data)
        uses_descriptor = name == SCORE and order is not None
        flags = 0x800 | (8 if uses_descriptor else 0)
        offset = len(local)
        header_values = (0, 0, 0) if uses_descriptor else (crc, len(zipped), len(data))
        local += struct.pack('<4s5H3I2H', b'PK\x03\x04', 20, flags, 8, 0, date,
                             *header_values, len(name_bytes), 0) + name_bytes + zipped
        if uses_descriptor:
            local += _descriptor(crc, len(zipped), len(data), order, signed)
        record = struct.pack('<4s6H3I5H2I', b'PK\x01\x02', 20, 20, flags, 8, 0, date,
                             crc, len(zipped), len(data), len(name_bytes), 0, 0, 0, 0, 0, offset)
        central.append(record + name_bytes)
    if reverse_directory:
        central.reverse()
    directory = b''.join(central)
    end = struct.pack('<4s4H2IH', b'PK\x05\x06', 0, 0, len(entries), len(entries),
                      len(directory), len(local), 0)
    return bytes(local) + directory + end


def edit_synthetic(original, scenario):
    """Return a candidate only if every source byte matches a generated case."""
    order, signed, _ = scenario
    if original != synthetic_archive(*scenario):
        raise ValueError('Only the exact generated archive is supported')
    with ZipFile(BytesIO(original)) as archive:
        info = archive.getinfo(SCORE)
        old_score = archive.read(info)
        if old_score.count(OLD_NOTE) != 1 or info.compress_type != 8:
            raise ValueError('Unexpected score content')
        score = old_score.replace(OLD_NOTE, NEW_NOTE, 1)
        local_start = info.header_offset
        if original[local_start:local_start + 4] != b'PK\x03\x04':
            raise ValueError('Invalid local header')
        name_size, extra_size = struct.unpack_from('<HH', original, local_start + 26)
        data_start = local_start + 30 + name_size + extra_size
        data_end = data_start + info.compress_size
        descriptor_size = (16 if signed else 12) if order else 0
        member_end = data_end + descriptor_size
        if member_end >= archive.start_dir:
            raise ValueError('Scenario requires a later local member')
        if order and original[data_end:member_end] != _descriptor(info.CRC, info.compress_size,
                                                                  info.file_size, order, signed):
            raise ValueError('Unexpected original descriptor')
        compressed = _deflate(score)
        crc = zlib.crc32(score)
        prefix = bytearray(original[:data_start])
        if order is None:
            struct.pack_into('<III', prefix, local_start + 14, crc, len(compressed), len(score))
        descriptor = _descriptor(crc, len(compressed), len(score), order, signed) if order else b''
        delta = len(compressed) - info.compress_size
        middle = original[member_end:archive.start_dir]
        eocd_start = len(original) - 22
        if original[eocd_start:eocd_start + 4] != b'PK\x05\x06':
            raise ValueError('Unexpected archive end')
        directory = bytearray(original[archive.start_dir:eocd_start])
        position = 0
        found = False
        for entry in archive.infolist():
            if directory[position:position + 4] != b'PK\x01\x02':
                raise ValueError('Invalid central header')
            name_len, extra_len, comment_len = struct.unpack_from('<HHH', directory, position + 28)
            name = bytes(directory[position + 46:position + 46 + name_len]).decode('utf-8')
            old_offset = struct.unpack_from('<I', directory, position + 42)[0]
            if name != entry.filename or old_offset != entry.header_offset:
                raise ValueError('Central directory mismatch')
            if name == SCORE:
                struct.pack_into('<III', directory, position + 16, crc, len(compressed), len(score))
                found = True
            elif old_offset > local_start:
                struct.pack_into('<I', directory, position + 42, old_offset + delta)
            position += 46 + name_len + extra_len + comment_len
        if not found or position != len(directory):
            raise ValueError('Incomplete central directory')
        end = bytearray(original[eocd_start:])
        struct.pack_into('<I', end, 16, archive.start_dir + delta)
        candidate = bytes(prefix) + compressed + descriptor + middle + bytes(directory) + bytes(end)
    # Gate the result through the independently implemented resource check.
    verify_resources(original, candidate, allow_reversed_descriptor=(order == 'reversed'))
    return candidate

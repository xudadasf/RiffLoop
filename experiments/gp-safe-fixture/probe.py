"""Fixture-locked, in-memory GPIF note edit; never a real GP editor."""

import hashlib
from io import BytesIO
from pathlib import Path
import struct
from zipfile import ZipFile
import zlib

FIXTURE = Path(__file__).resolve().parents[2] / 'RiffLoopTests/Fixtures/transport.gp'
FIXTURE_HASH = '40c1dbbc66b44e8dcaa6986379af8dad58725d09fe3b261ed086a440e682dc75'
SCORE = 'Content/score.gpif'
OLD_NOTE = (b'<Note id="0"><Properties><Property name="ConcertPitch"><Pitch>'
            b'<Step>A</Step><Accidental>#</Accidental><Octave>4</Octave></Pitch></Property>'
            b'<Property name="TransposedPitch"><Pitch><Step>A</Step><Accidental>#</Accidental>'
            b'<Octave>5</Octave></Pitch></Property><Property name="String"><String>3</String>'
            b'</Property><Property name="Fret"><Fret>3</Fret></Property><Property name="Midi">'
            b'<Number>58</Number></Property></Properties><InstrumentArticulation>0'
            b'</InstrumentArticulation></Note>')
NEW_NOTE = (b'<Note id="0"><Properties><Property name="ConcertPitch"><Pitch>'
            b'<Step>B</Step><Accidental></Accidental><Octave>4</Octave></Pitch></Property>'
            b'<Property name="TransposedPitch"><Pitch><Step>B</Step><Accidental></Accidental>'
            b'<Octave>5</Octave></Pitch></Property><Property name="String"><String>3</String>'
            b'</Property><Property name="Fret"><Fret>4</Fret></Property><Property name="Midi">'
            b'<Number>59</Number></Property></Properties><InstrumentArticulation>0'
            b'</InstrumentArticulation></Note>')


def edit_known_fixture(original):
    """Accept only exact repository fixture; return bytes, never write to disk.

    This specifically replaces its unique first note. It cannot infer pitches,
    inspect arbitrary scores, handle shared references or save a user's file.
    """
    if hashlib.sha256(original).hexdigest() != FIXTURE_HASH:
        raise ValueError('Only the exact test fixture is supported')
    with ZipFile(BytesIO(original)) as source:
        entries = source.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)) or names.count(SCORE) != 1:
            raise ValueError('Invalid or ambiguous fixture archive')
        info = source.getinfo(SCORE)
        contents = source.read(info)
        if contents.count(OLD_NOTE) != 1:
            raise ValueError('Fixture note is not unique or changed')
        contents = contents.replace(OLD_NOTE, NEW_NOTE, 1)
        if info.compress_type != 8 or info.flag_bits & 8:
            raise ValueError('Unexpected compression or data descriptor')
        local = info.header_offset
        if original[local:local + 4] != b'PK\x03\x04':
            raise ValueError('Invalid local header')
        name_len, extra_len = struct.unpack_from('<HH', original, local + 26)
        data_start = local + 30 + name_len + extra_len
        end_record = original.rfind(b'PK\x05\x06')
        if end_record < 0 or end_record + 22 != len(original):
            raise ValueError('Unsupported end record')
        cd_size, cd_start = struct.unpack_from('<II', original, end_record + 12)
        if data_start + info.compress_size != cd_start or cd_start + cd_size != end_record:
            raise ValueError('Score must be the last local entry')

        # Change only the compressed score payload and its required ZIP sizes
        # and CRC. Other local records and all original flags remain byte-exact.
        compressor = zlib.compressobj(level=6, wbits=-15)
        compressed = compressor.compress(contents) + compressor.flush()
        crc = zlib.crc32(contents)
        prefix = bytearray(original[:data_start])
        struct.pack_into('<III', prefix, local + 14, crc, len(compressed), len(contents))
        directory = bytearray(original[cd_start:end_record])
        cursor = 0
        found = False
        for _ in entries:
            if directory[cursor:cursor + 4] != b'PK\x01\x02':
                raise ValueError('Invalid central directory')
            name_size, extra_size, comment_size = struct.unpack_from('<HHH', directory, cursor + 28)
            entry_name = bytes(directory[cursor + 46:cursor + 46 + name_size]).decode('utf-8')
            if entry_name == SCORE:
                if found or struct.unpack_from('<I', directory, cursor + 42)[0] != local:
                    raise ValueError('Ambiguous score directory entry')
                struct.pack_into('<III', directory, cursor + 16, crc, len(compressed), len(contents))
                found = True
            cursor += 46 + name_size + extra_size + comment_size
        if not found or cursor != len(directory):
            raise ValueError('Unexpected central directory')
        end = bytearray(original[end_record:])
        struct.pack_into('<I', end, 16, len(prefix) + len(compressed))
        result = bytes(prefix) + compressed + bytes(directory) + bytes(end)
    return result

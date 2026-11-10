"""Experimental GP archive comparison; accepts bytes and writes no files.

Passing this check only covers ZIP members and metadata. It does not establish
the correctness of changes inside score.gpif or compatibility with GP apps.
"""

from dataclasses import dataclass
from io import BytesIO
from pathlib import PurePosixPath
from stat import S_ISLNK
import struct
import unicodedata
from zipfile import BadZipFile, ZIP_DEFLATED, ZIP_STORED, ZipFile
from zlib import decompressobj, error as DecompressionError


SCORE = "Content/score.gpif"


class UnsafeArchive(ValueError):
    pass


@dataclass(frozen=True)
class Limits:
    max_entries: int = 2000
    max_member_bytes: int = 64 * 1024 * 1024
    max_total_bytes: int = 128 * 1024 * 1024


def _metadata(info):
    # Preserve observable ZIP member attributes, including original extra data.
    return (info.date_time, info.compress_type, info.create_system,
            info.create_version, info.extract_version, info.reserved, info.volume, info.flag_bits,
            info.internal_attr, info.external_attr, info.extra, info.comment)


def _contents(archive, limits):
    entries = archive.infolist()
    if len(entries) > limits.max_entries:
        raise UnsafeArchive("too many members")
    names = [entry.filename for entry in entries]
    folded = [unicodedata.normalize("NFC", name).casefold() for name in names]
    if len(set(folded)) != len(names) or names.count(SCORE) != 1:
        raise UnsafeArchive("duplicate members or missing score")
    total = 0
    for info in entries:
        name = info.filename
        parts = PurePosixPath(name).parts
        path_components = name.split("/")
        if info.is_dir() and path_components[-1] == "":
            path_components.pop()
        if (not name or name != info.orig_filename or name.startswith("/") or "\\" in name or
                any(part in ("", ".", "..") for part in path_components) or
                (parts and ":" in parts[0])):
            raise UnsafeArchive("unsafe member name")
        # Support only deflate option bits, a data descriptor and UTF-8 names.
        if (info.flag_bits & ~0x080e or info.volume != 0 or
                info.compress_type not in (ZIP_STORED, ZIP_DEFLATED) or
                (info.compress_type == ZIP_STORED and info.flag_bits & 0x6)):
            raise UnsafeArchive("encrypted or unsupported member")
        if info.create_system == 3 and S_ISLNK(info.external_attr >> 16):
            raise UnsafeArchive("symbolic link member")
        if info.file_size > limits.max_member_bytes:
            raise UnsafeArchive("member too large")
        total += info.file_size
        if total > limits.max_total_bytes:
            raise UnsafeArchive("archive too large")
    return entries


def _local_members(data, archive, entries, allow_reversed_descriptor):
    # The next local-header offset (or central directory) bounds the entire
    # original local record, including any optional descriptor or padding.
    ordered = sorted(entries, key=lambda info: info.header_offset)
    offsets = [info.header_offset for info in ordered] + [archive.start_dir]
    if not ordered or offsets[0] != 0 or any(offsets[i] >= offsets[i + 1] for i in range(len(ordered))):
        raise UnsafeArchive("invalid local member offsets")
    eocd = len(data) - len(archive.comment) - 22
    if eocd < archive.start_dir or data[eocd:eocd + 4] != b"PK\x05\x06":
        raise UnsafeArchive("unsupported archive trailer")
    disk, central_disk, disk_count, count = struct.unpack_from("<4H", data, eocd + 4)
    if disk or central_disk or disk_count != count or count != len(entries):
        raise UnsafeArchive("unsupported multi-volume archive")
    directory_size, directory_start = struct.unpack_from("<II", data, eocd + 12)
    if directory_start != archive.start_dir or directory_start + directory_size != eocd:
        raise UnsafeArchive("unsupported central directory structure")
    members = {}
    headers = {}
    descriptors = {}
    for index, info in enumerate(ordered):
        start, end = offsets[index:index + 2]
        if start < 0 or end > len(data) or end - start < 30 or data[start:start + 4] != b"PK\x03\x04":
            raise UnsafeArchive("invalid local member header")
        version, flags, method, tm, dt, crc, compressed, size, name_len, extra_len = struct.unpack_from(
            "<5H3I2H", data, start + 4)
        header_end = start + 30 + name_len + extra_len
        body_end = header_end + info.compress_size
        if (version != info.extract_version or flags != info.flag_bits or method != info.compress_type or
                header_end > end or body_end > end or compressed == 0xffffffff or size == 0xffffffff):
            raise UnsafeArchive("local header conflicts with directory")
        year, month, day, hour, minute, second = info.date_time
        if tm != (hour << 11 | minute << 5 | second // 2) or dt != ((year - 1980) << 9 | month << 5 | day):
            raise UnsafeArchive("local timestamp conflicts with directory")
        encoding = "utf-8" if flags & 0x800 else "cp437"
        if data[start + 30:start + 30 + name_len].decode(encoding) != info.orig_filename:
            raise UnsafeArchive("local filename conflicts with directory")
        if method == ZIP_STORED:
            if info.compress_size != info.file_size:
                raise UnsafeArchive("stored member has inconsistent size")
        else:
            # ZipFile verifies CRC but accepts bytes after the end of a raw
            # deflate stream. Require exactly one complete bounded stream.
            inflater = decompressobj(-15)
            produced = 0
            for position in range(header_end, body_end, 65536):
                chunk = memoryview(data)[position:min(position + 65536, body_end)]
                produced += len(inflater.decompress(chunk, info.file_size - produced + 1))
                if produced > info.file_size or inflater.unconsumed_tail or inflater.unused_data:
                    raise UnsafeArchive("deflate stream exceeds member boundary")
            produced += len(inflater.flush(info.file_size - produced + 1))
            if produced != info.file_size or not inflater.eof or inflater.unused_data:
                raise UnsafeArchive("invalid deflate stream")
        if flags & 8:
            if crc not in (0, info.CRC) or compressed not in (0, info.compress_size) or size not in (0, info.file_size):
                raise UnsafeArchive("local descriptor fields conflict")
            descriptor = body_end
            signed = end - body_end == 16 and data[descriptor:descriptor + 4] == b"PK\x07\x08"
            if signed:
                descriptor += 4
            if descriptor + 12 != end:
                raise UnsafeArchive("invalid data descriptor")
            fields = struct.unpack_from("<III", data, descriptor)
            normal = fields == (info.CRC, info.compress_size, info.file_size)
            reversed_sizes = fields == (info.CRC, info.file_size, info.compress_size)
            if not normal and not (allow_reversed_descriptor and reversed_sizes):
                raise UnsafeArchive("invalid data descriptor")
            order = "either" if normal and reversed_sizes else ("normal" if normal else "reversed")
            descriptors[info.filename] = (order, signed)
        elif (crc, compressed, size) != (info.CRC, info.compress_size, info.file_size) or body_end != end:
            raise UnsafeArchive("local payload fields conflict")
        else:
            descriptors[info.filename] = ("none", False)
        members[info.filename] = memoryview(data)[start:end]
        # Score data and its sizes may change; retain the rest of the local header.
        headers[info.filename] = data[start:start + 14] + data[start + 26:header_end]
    return members, headers, descriptors


def verify_resources(original: bytes, candidate: bytes, *, limits: Limits = Limits(),
                     allow_reversed_descriptor: bool = False):
    """Reject resource or member changes apart from score contents.

    Both archives are inspected without extracting paths. The explicit
    allow_reversed_descriptor option permits a size ordering observed in
    local development samples and still requires its ordering to be preserved.
    This does not verify signatures or GPIF references; callers must not regard
    it as authorization to replace a score.
    """
    if min(limits.max_entries, limits.max_member_bytes, limits.max_total_bytes) < 1:
        raise ValueError("limits must be positive")
    try:
        with ZipFile(BytesIO(original)) as before, ZipFile(BytesIO(candidate)) as after:
            old = _contents(before, limits)
            new = _contents(after, limits)
            if before.comment != after.comment or [i.filename for i in old] != [i.filename for i in new]:
                raise UnsafeArchive("archive comment or member list changed")
            old_raw, old_headers, old_descriptors = _local_members(original, before, old, allow_reversed_descriptor)
            new_raw, new_headers, new_descriptors = _local_members(candidate, after, new, allow_reversed_descriptor)
            for first, second in zip(old, new):
                if _metadata(first) != _metadata(second):
                    raise UnsafeArchive("member metadata changed")
                if old_headers[first.filename] != new_headers[first.filename]:
                    raise UnsafeArchive("local member metadata changed")
                old_descriptor, new_descriptor = old_descriptors[first.filename], new_descriptors[first.filename]
                if old_descriptor != new_descriptor:
                    raise UnsafeArchive("data descriptor ordering changed")
                if first.filename != SCORE:
                    if old_raw[first.filename] != new_raw[first.filename]:
                        raise UnsafeArchive("compressed resource record changed")
                    if first.file_size != second.file_size or first.CRC != second.CRC:
                        raise UnsafeArchive("resource changed")
                    # Read in bounded chunks and compare bytes, including entries
                    # with equal size and CRC; CRC validation happens on read.
                    with before.open(first) as source, after.open(second) as result:
                        while True:
                            a, b = source.read(65536), result.read(65536)
                            if a != b:
                                raise UnsafeArchive("resource changed")
                            if not a:
                                break
                else:
                    # Force score CRC and decompression validation too.
                    for archive, info in ((before, first), (after, second)):
                        with archive.open(info) as stream:
                            while stream.read(65536):
                                pass
    except (BadZipFile, DecompressionError, EOFError, NotImplementedError, RuntimeError, UnicodeError, struct.error) as exc:
        raise UnsafeArchive("unreadable archive") from exc

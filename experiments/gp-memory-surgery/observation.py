"""Read selected score properties via the existing local importer in memory.

The result may contain private information and must never be logged/uploaded.
"""
import base64
import hashlib
from io import BytesIO
import json
import subprocess
from zipfile import ZipFile

from archive_edit import ROOT, SCORE, verify_resources


def observe(*archives):
    payload = json.dumps([base64.b64encode(value).decode('ascii') for value in archives])
    process = subprocess.run(['node', str(ROOT / 'experiments/gp-memory-surgery/observe.cjs')],
                             input=payload, encoding='utf-8', capture_output=True, timeout=30, check=True)
    return json.loads(process.stdout)


def semantic_observation(view, semantic, gpif_sha256):
    # This associates a caller-supplied view with its source GPIF; it is not a
    # cryptographic attestation that the importer produced the observation.
    if (not isinstance(gpif_sha256, str) or len(gpif_sha256) != 64 or
            any(char not in '0123456789abcdef' for char in gpif_sha256)):
        raise ValueError('Expected a lowercase GPIF SHA-256')
    tracks = view['tracks']
    if len(tracks) != 1 or len(tracks[0]['staves']) != 1:
        raise ValueError('Only one track and staff can be checked')
    staff = tracks[0]['staves'][0]
    beats = {}
    for bar_index, bar in enumerate(staff['bars']):
        for voice_index, voice in enumerate(bar):
            for beat_index, beat in enumerate(voice):
                beats[(bar_index, voice_index, beat_index)] = tuple(
                    semantic.ImportedNote(note['string'], note['fret'], note['realValue'])
                    for note in beat['notes'])
    return semantic.ImporterObservation(gpif_sha256=gpif_sha256,
                                        track_count=len(tracks), staff_count=len(tracks[0]['staves']),
                                        tuning_high_to_low=tuple(staff['tuning']), capo=staff['capo'],
                                        actual_transposition=staff['transpositionPitch'],
                                        display_transposition=staff['displayTranspositionPitch'], beats=beats)


def observe_semantic(archive, semantic, *, allow_reversed_descriptor=False):
    """Read and hash GPIF from the same in-memory archive sent to the importer.

    The returned values can contain private data and must not be logged. This
    binds the inputs in this helper, but does not authenticate the importer.
    The archive guard checks structure, not signature, GPIF meaning or audio.
    """
    if not isinstance(archive, bytes):
        raise TypeError('Expected archive bytes')
    verify_resources(archive, archive, allow_reversed_descriptor=allow_reversed_descriptor)
    with ZipFile(BytesIO(archive)) as source:
        if source.namelist().count(SCORE) != 1:
            raise ValueError('Expected exactly one GPIF member')
        info = source.getinfo(SCORE)
        if info.file_size > 16 * 1024 * 1024:
            raise ValueError('GPIF exceeds the semantic experiment limit')
        digest = hashlib.sha256(source.read(info)).hexdigest()
    view, = observe(archive)
    return view, semantic_observation(view, semantic, digest)

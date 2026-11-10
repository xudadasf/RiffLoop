"""Byte-level note change on one fixed synthetic GPIF; not an editor.

No file I/O is provided. The fixed digest prevents this experiment from
accepting a user's score. The caller's importer observation is untrusted; the
digest can bind the claim to the input but cannot authenticate the importer.
"""

import hashlib
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'gp-semantic-probe'))
from semantic import Candidate, Unsupported, candidates


SYNTHETIC_SHA256 = '45bac9368ce6c00b34fa94692d05bb1a1ae4455b23c44ad67393c3685c0a5dd0'
NATURAL_NOTES = {5: (60, b'C'), 7: (62, b'D')}


def _replace_value(note, pattern, expected, replacement):
    matches = list(re.finditer(pattern, note))
    if len(matches) != 1 or matches[0].group(2) != expected:
        raise Unsupported('ambiguous or unsupported synthetic field')
    start, end = matches[0].span(2)
    return note[:start] + replacement + note[end:]


def patch_synthetic(xml, observation, selected, new_fret):
    """Change a checked note only in the fixed generated synthetic score.

    The only supported changes are 5→7 or 7→5 on its fourth string. This is
    intentionally not capable of reading, editing, or saving a real GP file.
    """
    if not isinstance(xml, bytes) or hashlib.sha256(xml).hexdigest() != SYNTHETIC_SHA256:
        raise Unsupported('only the exact synthetic GPIF is supported')
    if not isinstance(selected, Candidate) or selected not in candidates(xml, observation):
        raise Unsupported('candidate does not match checked input')
    if (type(new_fret) is not int or new_fret not in NATURAL_NOTES or
            selected.fret not in NATURAL_NOTES or new_fret == selected.fret or selected.string != 3 or
            selected.midi != NATURAL_NOTES[selected.fret][0] or observation.display_transposition != -12):
        raise Unsupported('only the synthetic natural-note transition is supported')

    start, end = selected.byte_span
    if not (0 <= start < end <= len(xml)):
        raise Unsupported('invalid synthetic byte span')
    note = xml[start:end]
    old_midi, old_step = NATURAL_NOTES[selected.fret]
    new_midi, new_step = NATURAL_NOTES[new_fret]
    note = _replace_value(note, rb'(<Property name="Fret">\s*<Fret>)(\d+)(</Fret>\s*</Property>)',
                          str(selected.fret).encode(), str(new_fret).encode())
    note = _replace_value(note, rb'(<Property name="Midi">\s*<Number>)(\d+)(</Number>\s*</Property>)',
                          str(old_midi).encode(), str(new_midi).encode())
    for name, octave in ((b'ConcertPitch', b'5'), (b'TransposedPitch', b'6')):
        # The remaining spelling, empty accidental and octave must already be
        # exactly the known synthetic natural-note representation.
        pattern = (rb'(<Property name="' + name + rb'">\s*<Pitch>\s*<Step>)([A-G])'
                   rb'(</Step>\s*<Accidental\s*/>\s*<Octave>' + octave +
                   rb'</Octave>\s*</Pitch>\s*</Property>)')
        note = _replace_value(note, pattern, old_step, new_step)
    return xml[:start] + note + xml[end:]

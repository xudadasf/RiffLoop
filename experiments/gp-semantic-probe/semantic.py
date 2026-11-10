"""Conservative, read-only GPIF candidate experiment; not a GP editor.

Only in-memory XML and separately obtained importer observations are accepted.
This module neither opens an archive nor writes a file. A returned candidate
does not imply an edit, its resulting pitch, or its archive is safe.
"""
from collections import Counter
from copy import deepcopy
from dataclasses import dataclass
import hashlib
import math
import re
from typing import Mapping
from xml.etree import ElementTree as ET
from xml.parsers import expat


class Unsupported(ValueError):
    """The input cannot be proven to satisfy this experiment's narrow rules."""


@dataclass(frozen=True)
class ImportedNote:
    string: int  # alphaTab uses 1 for GPIF's 0
    fret: int
    real_value: int


@dataclass(frozen=True)
class ImporterObservation:
    track_count: int
    staff_count: int
    tuning_high_to_low: tuple[int, ...]
    capo: int
    actual_transposition: int
    display_transposition: int
    # (master bar, voice, beat) -> parsed notes in that beat.
    beats: Mapping[tuple[int, int, int], tuple[ImportedNote, ...]]
    # Supplied by the caller from the same GPIF bytes used by its importer.
    # A matching digest does not authenticate that the caller actually did so.
    gpif_sha256: str


@dataclass(frozen=True)
class Candidate:
    position: tuple[int, int, int]
    note_id: str
    string: int  # GPIF low-to-high, 0 based
    fret: int
    midi: int
    byte_span: tuple[int, int]  # exact original <Note> element, end exclusive


NOTE_PROPERTIES = {'String', 'Fret', 'Midi', 'ConcertPitch', 'TransposedPitch'}
BEAT_TAGS = {'Dynamic', 'Rhythm', 'TransposedPitchStemOrientation',
             'ConcertPitchStemOrientation', 'Notes', 'Properties', 'XProperties'}
BEAT_PROPERTIES = {'PrimaryPickupVolume', 'PrimaryPickupTone'}
STEPS = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
ROOT_TAGS = {'GPVersion', 'GPRevision', 'Encoding', 'Score', 'ScoreViews', 'AudioTracks',
             'MasterTrack', 'Tracks', 'MasterBars', 'Bars', 'Voices', 'Beats', 'Notes', 'Rhythms'}
# Uninspected sound, effect and diagram blocks may affect playback or reference
# a note. Exclude them entirely until their semantics are verified.
TRACK_TAGS = {'Name', 'ShortName', 'Transpose', 'Staves'}
STAFF_PROPERTIES = {'Tuning', 'CapoFret', 'PartialCapoFret', 'PartialCapoStringFlags'}


def _one(parent, path):
    found = parent.findall(path)
    if len(found) != 1:
        raise Unsupported('missing or duplicate required field')
    return found[0]


def _text(parent, path):
    node = _one(parent, path)
    if node.attrib or len(node):
        raise Unsupported('unknown scalar field structure')
    value = node.text
    if value is None or not value.strip():
        raise Unsupported('missing required value')
    return value.strip()


def _property(parent, name):
    found = [p for p in parent.findall('./Property') if p.get('name') == name]
    if len(found) != 1:
        raise Unsupported('missing or duplicate property')
    return found[0]


def _integer(text):
    try:
        if not text or text.strip() != text:
            raise ValueError()
        result = int(text)
        if str(result) != text:
            raise ValueError()
        return result
    except (TypeError, ValueError):
        raise Unsupported('invalid integer') from None


def _table(root, section, tag):
    parent = _one(root, section)
    result = {}
    for node in parent:
        identity = node.get('id')
        if (node.tag != tag or set(node.attrib) != {'id'} or identity is None or
                _integer(identity) < 0 or identity in result):
            raise Unsupported('invalid or duplicate object id')
        result[identity] = node
    return result


def _links(parent, field, allow_empty=False):
    found = parent.findall(field)
    if allow_empty and not found:
        return []
    if len(found) != 1:
        raise Unsupported('missing or duplicate reference list')
    if found[0].attrib or len(found[0]):
        raise Unsupported('unknown reference list structure')
    return (found[0].text or '').split()


def _note_pitch(note, name):
    props = _one(note, 'Properties')
    prop = _property(props, name)
    parent = _one(prop, 'Pitch')
    if (len(prop) != 1 or parent.attrib or [node.tag for node in parent] != ['Step', 'Accidental', 'Octave'] or
            any(node.attrib or len(node) for node in parent)):
        raise Unsupported('unknown pitch layout')
    step = _text(parent, 'Step')
    accidental = _one(parent, 'Accidental').text or ''
    if step not in STEPS or accidental not in ('', '#', 'b'):
        raise Unsupported('unsupported pitch spelling')
    return 12 * _integer(_text(parent, 'Octave')) + STEPS[step] + {'': 0, '#': 1, 'b': -1}[accidental]


def _note_spans(xml):
    """Locate actual Note elements with a parser, not a text search.

    Expat's byte positions ignore comments and CDATA, which may themselves
    contain markup-like text. Do not print these offsets or note data.
    """
    spans, stack, starts = {}, [], []
    parser = expat.ParserCreate()
    def start(name, attrs):
        if ':' in name or any(':' in key or key == 'xmlns' for key in attrs):
            raise Unsupported('unsupported namespace')
        stack.append(name)
        if stack == ['GPIF', 'Notes', 'Note']:
            if set(attrs) != {'id'} or attrs['id'] in spans:
                raise Unsupported('ambiguous byte position')
            starts.append((attrs['id'], parser.CurrentByteIndex))
    def end(name):
        if stack == ['GPIF', 'Notes', 'Note']:
            identity, begin = starts.pop()
            end_start = parser.CurrentByteIndex
            # A selected note must have an explicit closing tag and children.
            if not xml[end_start:].startswith(b'</Note'):
                raise Unsupported('unsupported note syntax')
            close = xml.find(b'>', end_start)
            if close < 0:
                raise Unsupported('invalid closing tag')
            spans[identity] = (begin, close + 1)
        if not stack or stack.pop() != name:
            raise Unsupported('invalid XML nesting')
    def reject(*_):
        raise Unsupported('DTD or external entities are unsupported')
    def reject_inside_note(*_):
        if stack[:3] == ['GPIF', 'Notes', 'Note']:
            raise Unsupported('comment or CDATA inside note')
    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.StartDoctypeDeclHandler = reject
    parser.ExternalEntityRefHandler = reject
    parser.CommentHandler = reject_inside_note
    parser.StartCdataSectionHandler = reject_inside_note
    try:
        parser.Parse(xml, True)
    except expat.ExpatError:
        raise Unsupported('invalid XML') from None
    return spans


def candidates(xml: bytes, observation: ImporterObservation) -> tuple[Candidate, ...]:
    """Find a narrow subset of ordinary unshared notes; never edit input.

    The caller must independently load an archive containing these exact GPIF
    bytes with alphaTab and provide its observations and their source digest.
    The digest binds the caller's claim to these bytes but cannot authenticate
    that evidence. This does not compare resources, audio or new note spelling.
    """
    if not isinstance(xml, bytes) or not xml or len(xml) > 16 * 1024 * 1024:
        raise Unsupported('invalid or oversized score')
    if hashlib.sha256(xml).hexdigest() != observation.gpif_sha256:
        raise Unsupported('importer observation does not match GPIF bytes')
    try:
        decoded = xml.decode('utf-8-sig')
    except UnicodeDecodeError:
        raise Unsupported('only UTF-8 XML is supported') from None
    declaration = re.match(r'^\s*<\?xml\s+([^?]*)\?>', decoded, re.IGNORECASE)
    if declaration:
        encoding = re.search(r'\bencoding\s*=\s*([\'"])([^\'"]+)\1', declaration.group(1), re.IGNORECASE)
        if encoding and encoding.group(2).lower() != 'utf-8':
            raise Unsupported('only UTF-8 XML is supported')
    spans = _note_spans(xml)
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        raise Unsupported('invalid XML') from None
    if root.tag != 'GPIF' or root.attrib:
        raise Unsupported('unsupported root')
    if any(child.tag not in ROOT_TAGS for child in root):
        raise Unsupported('unknown root field')
    for element in root.iter():
        if ('note' in element.tag.lower() and 'ref' in element.tag.lower()) or any(
                'ref' in key.lower() and not (element.tag == 'Rhythm' and key == 'ref')
                for key in element.attrib):
            raise Unsupported('unknown reference use')
    # A second Note collection could hold references whose semantics are not
    # known to this restricted graph. Do not infer them from matching IDs.
    if sum(1 for element in root.iter('Note')) != len(root.findall('./Notes/Note')):
        raise Unsupported('note outside the known graph')
    if observation.track_count != 1 or observation.staff_count != 1:
        raise Unsupported('requires one importer track and staff')
    if (len(observation.tuning_high_to_low) != 6 or observation.capo != 0 or
            observation.actual_transposition != 0 or observation.display_transposition not in (0, -12)):
        raise Unsupported('unsupported tuning, capo or transposition')

    tracks = _table(root, 'Tracks', 'Track')
    if len(tracks) != 1:
        raise Unsupported('requires one track')
    track_id, track = next(iter(tracks.items()))
    if any(child.tag not in TRACK_TAGS for child in track):
        raise Unsupported('unknown track field')
    if any(child.attrib or len(child) for child in track if child.tag in ('Name', 'ShortName')):
        raise Unsupported('unknown track name structure')
    master_track = _one(root, 'MasterTrack')
    if master_track.attrib or any(child.tag not in ('Tracks', 'Automations', 'RSE') for child in master_track):
        raise Unsupported('unknown master track field')
    # Automation semantics are not yet understood. An unknown automation can
    # affect pitch even if a note itself looks ordinary.
    for owner in (master_track, track):
        for automation in owner.findall('Automations'):
            if automation.attrib or len(automation) or (automation.text or '').strip():
                raise Unsupported('unsupported automation')
    for rse in master_track.findall('RSE'):
        if rse.attrib or len(rse) or (rse.text or '').strip():
            raise Unsupported('unsupported master audio state')
    if _text(master_track, 'Tracks').split() != [track_id]:
        raise Unsupported('ambiguous track reference')
    staves = _one(track, 'Staves')
    if staves.attrib or len(staves) != 1:
        raise Unsupported('unknown or multiple staff')
    staff = _one(staves, 'Staff')
    if staff.attrib or any(child.tag != 'Properties' for child in staff):
        raise Unsupported('unknown staff field')
    props = _one(staff, 'Properties')
    if props.attrib or any(child.tag not in ('Name', 'Property') or
           (child.tag == 'Property' and (set(child.attrib) != {'name'} or
                                         child.get('name') not in STAFF_PROPERTIES)) for child in props):
        raise Unsupported('unknown staff property')
    if any(child.attrib or len(child) for child in props if child.tag == 'Name'):
        raise Unsupported('unknown staff name structure')
    try:
        for name, tag in (('Tuning', 'Pitches'), ('CapoFret', 'Fret'),
                          ('PartialCapoFret', 'Fret'), ('PartialCapoStringFlags', 'Bitset')):
            if [child.tag for child in _property(props, name)] != [tag]:
                raise Unsupported('unknown tuning or capo property structure')
        tuning = tuple(_integer(x) for x in _text(_property(props, 'Tuning'), 'Pitches').split())
        capo = _integer(_text(_property(props, 'CapoFret'), 'Fret'))
        partial = _integer(_text(_property(props, 'PartialCapoFret'), 'Fret'))
        flags = _text(_property(props, 'PartialCapoStringFlags'), 'Bitset')
        trans = _one(track, 'Transpose')
        if trans.attrib or sorted(child.tag for child in trans) != ['Chromatic', 'Octave']:
            raise Unsupported('unknown transpose structure')
        chromatic, octave = _integer(_text(trans, 'Chromatic')), _integer(_text(trans, 'Octave'))
    except Unsupported:
        raise
    if (len(tuning) != 6 or tuple(reversed(tuning)) != observation.tuning_high_to_low or
            any(p < 0 or p > 127 for p in tuning) or capo != 0 or partial != 0 or flags != '000000' or
            chromatic != 0 or octave not in (0, -1) or octave * 12 != observation.display_transposition):
        raise Unsupported('staff metadata does not match importer')

    bars = _table(root, 'Bars', 'Bar')
    voices = _table(root, 'Voices', 'Voice')
    beats = _table(root, 'Beats', 'Beat')
    notes = _table(root, 'Notes', 'Note')
    rhythms = _table(root, 'Rhythms', 'Rhythm')
    master_bars = list(_one(root, 'MasterBars'))
    if any(m.tag != 'MasterBar' for m in master_bars):
        raise Unsupported('unknown master bar')
    if any(any(child.tag not in ('Key', 'Time', 'Bars') for child in master) for master in master_bars):
        raise Unsupported('unsupported master bar feature')
    if any(master.attrib for master in master_bars):
        raise Unsupported('unknown master bar attribute')
    for master in master_bars:
        times = master.findall('Time')
        if len(times) > 1:
            raise Unsupported('duplicate time signature')
        if times:
            time = times[0]
            if time.attrib or len(time) or not re.fullmatch(r'[1-9]\d*/[1-9]\d*', (time.text or '').strip()):
                raise Unsupported('unknown time signature structure')
    if any(any(child.tag not in ('Voices', 'Clef') for child in bar) for bar in bars.values()):
        raise Unsupported('unsupported bar feature')
    if any(any(child.tag != 'Beats' for child in voice) for voice in voices.values()):
        raise Unsupported('unsupported voice feature')
    if any(any(child.tag not in ('NoteValue', 'AugmentationDot', 'PrimaryTuplet') for child in rhythm)
           for rhythm in rhythms.values()):
        raise Unsupported('unsupported rhythm feature')
    if any(any(child.attrib or len(child) for child in rhythm) for rhythm in rhythms.values()):
        raise Unsupported('unknown rhythm feature structure')

    # Reject techniques across the whole score: an earlier slide/tie/etc. can
    # affect an otherwise plain-looking target. This is deliberately stricter
    # than necessary, pending complete relationship handling.
    for note in notes.values():
        if any(n.tag not in ('Properties', 'InstrumentArticulation') for n in note):
            raise Unsupported('note technique or unknown note field')
        if set(note.attrib) != {'id'}:
            raise Unsupported('unknown note attribute')
        articulation = _one(note, 'InstrumentArticulation')
        if articulation.attrib or len(articulation) or (articulation.text or '').strip() != '0':
            raise Unsupported('unsupported instrument articulation')
        p = _one(note, 'Properties')
        if p.attrib or any(x.tag != 'Property' or x.get('name') not in NOTE_PROPERTIES or
                           set(x.attrib) != {'name'} for x in p):
            raise Unsupported('note technique or unknown pitch property')
    for beat in beats.values():
        if any(child.tag not in BEAT_TAGS for child in beat):
            raise Unsupported('beat technique or unknown field')
        if set(beat.attrib) != {'id'} or len(beat.findall('./Properties')) > 1 or len(beat.findall('./XProperties')) > 1:
            raise Unsupported('unknown beat attribute or duplicate properties')
        if any(child.attrib or len(child) for child in beat
               if child.tag in ('Dynamic', 'TransposedPitchStemOrientation', 'ConcertPitchStemOrientation')):
            raise Unsupported('unknown beat scalar structure')
        for prop in beat.findall('./Properties/*'):
            if (prop.tag != 'Property' or prop.get('name') not in BEAT_PROPERTIES or
                    set(prop.attrib) != {'name'} or len(prop) != 1 or prop[0].tag != 'Float' or
                    prop[0].attrib or len(prop[0])):
                raise Unsupported('beat technique or unknown property')
            try:
                if not math.isfinite(float(prop[0].text)):
                    raise ValueError()
            except (TypeError, ValueError):
                raise Unsupported('invalid pickup property') from None
        if any(group.attrib or len(group) or (group.text or '').strip() for group in beat.findall('./XProperties')):
            raise Unsupported('unknown extended beat properties')
        rhythm_node = _one(beat, 'Rhythm')
        if set(rhythm_node.attrib) != {'ref'} or len(rhythm_node) or (rhythm_node.text or '').strip():
            raise Unsupported('unknown beat rhythm reference')
        rhythm = rhythm_node.get('ref')
        if rhythm not in rhythms:
            raise Unsupported('dangling rhythm')

    counts = {}
    for parents, field, children, empty in ((master_bars, 'Bars', bars, False),
                                             (bars.values(), 'Voices', voices, False),
                                             (voices.values(), 'Beats', beats, False),
                                             (beats.values(), 'Notes', notes, True)):
        refs = Counter()
        for parent in parents:
            for ref in _links(parent, field, allow_empty=empty):
                if ref == '-1' and field in ('Bars', 'Voices'):
                    continue
                if ref not in children:
                    raise Unsupported('dangling reference')
                refs[ref] += 1
        counts[field] = refs

    result = []
    for mi, master in enumerate(master_bars):
        key = _one(master, 'Key')
        if key.attrib or any(child.tag not in ('AccidentalCount', 'Mode') or child.attrib or len(child)
                             for child in key):
            raise Unsupported('unknown key feature')
        if _text(key, 'AccidentalCount') != '0' or _text(key, 'Mode') not in ('Major', 'Minor'):
            continue
        bar_refs = _links(master, 'Bars')
        if len(bar_refs) != 1 or counts['Bars'][bar_refs[0]] != 1:
            continue
        for vi, voice_id in enumerate(_links(bars[bar_refs[0]], 'Voices')):
            if voice_id == '-1' or counts['Voices'][voice_id] != 1:
                continue
            for bi, beat_id in enumerate(_links(voices[voice_id], 'Beats')):
                if counts['Beats'][beat_id] != 1:
                    continue
                note_refs = _links(beats[beat_id], 'Notes', allow_empty=True)
                if len(note_refs) != 1 or counts['Notes'][note_refs[0]] != 1:
                    continue
                note = notes[note_refs[0]]
                p = _one(note, 'Properties')
                names = [x.get('name') for x in p]
                if len(names) != 5 or set(names) != NOTE_PROPERTIES or _text(note, 'InstrumentArticulation') != '0':
                    continue
                if any(len(_property(p, name)) != 1 or _property(p, name)[0].tag != name or
                       _property(p, name)[0].attrib or len(_property(p, name)[0])
                       for name in ('String', 'Fret')):
                    raise Unsupported('unknown numeric pitch structure')
                midi_node = _property(p, 'Midi')
                if len(midi_node) != 1 or midi_node[0].tag != 'Number' or midi_node[0].attrib or len(midi_node[0]):
                    raise Unsupported('unknown MIDI structure')
                string = _integer(_text(_property(p, 'String'), 'String'))
                fret = _integer(_text(_property(p, 'Fret'), 'Fret'))
                midi = _integer(_text(_property(p, 'Midi'), 'Number'))
                if not (0 <= string < 6 and 0 <= fret <= 24 and 0 <= midi <= 127):
                    continue
                if midi != tuning[string] + fret:
                    continue
                if (_note_pitch(note, 'ConcertPitch') != midi or
                        _note_pitch(note, 'TransposedPitch') != midi - observation.display_transposition):
                    continue
                position = (mi, vi, bi)
                if observation.beats.get(position) != (ImportedNote(string + 1, fret, midi),):
                    continue
                span = spans.get(note_refs[0])
                if span is None:
                    raise Unsupported('missing source byte span')
                try:
                    parsed_slice = ET.fromstring(xml[span[0]:span[1]])
                except ET.ParseError:
                    raise Unsupported('invalid source note span') from None
                expected_note = deepcopy(note)
                expected_note.tail = None
                if ET.tostring(parsed_slice) != ET.tostring(expected_note):
                    raise Unsupported('source span differs from parsed note')
                result.append(Candidate(position, note_refs[0], string, fret, midi, span))
    if not result:
        raise Unsupported('no proven simple unique note')
    return tuple(result)

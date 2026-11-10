"""Copy-on-write experiment for a deliberately tiny synthetic GPIF graph.

This is not a GP editor: it accepts no file, handles no ZIP, and rejects real
GPIF pitch and technique properties. The caller supplies a generated XML tree.
"""

from collections import Counter
from copy import deepcopy
from xml.etree import ElementTree as ET


class UnsupportedScore(ValueError):
    pass


RELATIONS = (
    ("MasterBars", "MasterBar", "Bars", "Bars", "Bar"),
    ("Bars", "Bar", "Voices", "Voices", "Voice"),
    ("Voices", "Voice", "Beats", "Beats", "Beat"),
    ("Beats", "Beat", "Notes", "Notes", "Note"),
)


def ids(parent, child):
    matches = parent.findall(child)
    if len(matches) != 1 or not matches[0].text:
        raise UnsupportedScore(f"Missing or repeated {child}")
    return matches[0], matches[0].text.split()


def table(root, name, item):
    section = root.find(name)
    if section is None:
        raise UnsupportedScore(f"Missing {name}")
    result = {}
    for node in section:
        if node.tag != item:
            raise UnsupportedScore(f"Unexpected {name} child")
        identity = node.get("id", "")
        if (not identity.isascii() or not identity.isdigit() or
                str(int(identity)) != identity or identity in result):
            raise UnsupportedScore(f"Invalid or duplicate {item} id")
        result[identity] = node
    return section, result


def validate(root):
    if root.tag != "GPIF" or root.get("experiment") != "synthetic-only":
        raise UnsupportedScore("Only the generated synthetic format is supported")
    for parent_section, parent_type, field, child_section, child_type in RELATIONS:
        parents = root.find(parent_section)
        if parents is None:
            raise UnsupportedScore(f"Missing {parent_section}")
        _, children = table(root, child_section, child_type)
        for parent in parents:
            if parent.tag != parent_type:
                raise UnsupportedScore(f"Unexpected {parent_section} child")
            _, references = ids(parent, field)
            if any(reference not in children for reference in references):
                raise UnsupportedScore(f"Dangling {field} reference")
    _, rhythms = table(root, "Rhythms", "Rhythm")
    for beat in root.findall("./Beats/Beat"):
        nodes = beat.findall("Rhythm")
        if len(nodes) != 1 or nodes[0].get("ref") not in rhythms:
            raise UnsupportedScore("Invalid rhythm reference")


def synthetic_pitch(note, bases):
    # Real GPIF usually contains further representations of pitch and effects;
    # rejecting them is intentional until their semantics are verified.
    if [child.tag for child in note] != ["Properties"]:
        raise UnsupportedScore("Unsupported note structure or technique")
    properties = note[0]
    expected = {"String": "String", "Fret": "Fret", "Midi": "Number"}
    if len(properties) != len(expected):
        raise UnsupportedScore("Unknown or missing pitch properties")
    values = {}
    for prop in properties:
        key = prop.get("name")
        if prop.tag != "Property" or key not in expected or key in values:
            raise UnsupportedScore("Unknown or repeated pitch property")
        if len(prop) != 1 or prop[0].tag != expected[key] or len(prop[0]):
            raise UnsupportedScore("Unsupported pitch value")
        try:
            values[key] = int(prop[0].text)
        except (ValueError, TypeError):
            raise UnsupportedScore("Invalid pitch value") from None
    string, fret, midi = values["String"], values["Fret"], values["Midi"]
    if string not in bases or not 0 <= fret <= 24 or not 0 <= midi <= 127 or bases[string] + fret != midi:
        raise UnsupportedScore("Pitch relation is unknown or inconsistent")
    return values


def reference_counts(root, section, item, field):
    return Counter(reference for node in root.findall(f"./{section}/{item}")
                   for reference in ids(node, field)[1])


def edit_fret(root, target, new_fret, bases):
    """Return a modified copy for a synthetic occurrence, never change input.

    target=(masterbar, bar-slot, voice-slot, beat-slot, note-slot), zero-based.
    Only synthetic notes with a caller-verified open-string MIDI relation are
    permitted. No output is suitable for saving as a real GP file.
    """
    work = deepcopy(root)
    validate(work)
    if len(target) != 5 or any(not isinstance(i, int) or i < 0 for i in target):
        raise UnsupportedScore("Invalid occurrence")
    if not isinstance(new_fret, int) or not 0 <= new_fret <= 24:
        raise UnsupportedScore("Invalid fret")
    master_bars = list(work.find("MasterBars"))
    if target[0] >= len(master_bars):
        raise UnsupportedScore("Unknown master bar")
    current = master_bars[target[0]]
    cloned = []
    for relation, index in zip(RELATIONS, target[1:]):
        parent_section, parent_type, field, child_section, child_type = relation
        link, references = ids(current, field)
        if index >= len(references):
            raise UnsupportedScore("Unknown occurrence")
        identity = references[index]
        destination, entities = table(work, child_section, child_type)
        current = entities[identity]
        if child_type == "Beat" and [child.tag for child in current] != ["Rhythm", "Notes"]:
            raise UnsupportedScore("Unsupported beat structure or technique")
        if reference_counts(work, parent_section, parent_type, field)[identity] > 1:
            new_id = str(max((int(i) for i in entities), default=-1) + 1)
            current = deepcopy(current)
            current.set("id", new_id)
            destination.append(current)
            references[index] = new_id
            link.text = " ".join(references)
            cloned.append(child_type)
    old = synthetic_pitch(current, bases)
    new_midi = bases[old["String"]] + new_fret
    if not 0 <= new_midi <= 127:
        raise UnsupportedScore("MIDI pitch outside supported range")
    for prop in current.find("Properties"):
        if prop.get("name") == "Fret":
            prop[0].text = str(new_fret)
        if prop.get("name") == "Midi":
            prop[0].text = str(new_midi)
    validate(work)
    return work, cloned


def occurrences(root, bases):
    """Return pitch values for every occurrence in a generated graph."""
    validate(root)
    indexes = [table(root, section, item)[1] for _, _, _, section, item in RELATIONS]
    result = {}
    for master_index, master in enumerate(root.find("MasterBars")):
        def walk(node, level, path):
            if level == len(RELATIONS):
                result[path] = synthetic_pitch(node, bases)
                return
            references = ids(node, RELATIONS[level][2])[1]
            for index, reference in enumerate(references):
                walk(indexes[level][reference], level + 1, path + (index,))
        walk(master, 0, (master_index,))
    return result


def synthetic_score():
    """Three bars and six note occurrences that share every graph level."""
    return ET.fromstring('''<GPIF experiment="synthetic-only">
      <MasterBars><MasterBar><Bars>0</Bars></MasterBar><MasterBar><Bars>0</Bars></MasterBar>
        <MasterBar><Bars>1</Bars></MasterBar></MasterBars>
      <Bars><Bar id="0"><Voices>0</Voices></Bar><Bar id="1"><Voices>0</Voices></Bar></Bars>
      <Voices><Voice id="0"><Beats>0 1</Beats></Voice></Voices>
      <Beats><Beat id="0"><Rhythm ref="0"/><Notes>0</Notes></Beat>
        <Beat id="1"><Rhythm ref="0"/><Notes>0</Notes></Beat></Beats>
      <Notes><Note id="0"><Properties><Property name="String"><String>0</String></Property>
        <Property name="Fret"><Fret>3</Fret></Property><Property name="Midi"><Number>43</Number></Property>
        </Properties></Note></Notes>
      <Rhythms><Rhythm id="0"><NoteValue>Quarter</NoteValue></Rhythm></Rhythms>
      </GPIF>''')

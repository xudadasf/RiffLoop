"use strict";

// Isolated new-score experiment: no GP import/edit and no file writes.
// Each 4/4 measure is exactly 3840 ticks; one quarter note is 960 ticks.
const durations = new Set([1, 2, 4, 8, 16, 32, 64]);
const tuning = [40, 45, 50, 55, 59, 64]; // low to high, MIDI

function fields(value, keys, label) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error(`${label} has missing or unsupported fields`);
    }
    const actual = Reflect.ownKeys(value);
    if (actual.length !== keys.length || actual.some(key => typeof key !== "string" || !keys.includes(key)) ||
        keys.some(key => {
            const descriptor = Object.getOwnPropertyDescriptor(value, key);
            return !descriptor || !descriptor.enumerable || !Object.hasOwn(descriptor, "value");
        })) {
        throw new Error(`${label} has missing or unsupported fields`);
    }
}

// JSON arrays have a dense sequence of enumerable data properties and no
// extra string or symbol keys. Reject other JS arrays instead of skipping data.
function array(value, maximum, label) {
    if (!Array.isArray(value) || value.length > maximum || Reflect.ownKeys(value).length !== value.length + 1) {
        throw new Error(`Invalid ${label}`);
    }
    for (let index = 0; index < value.length; index++) {
        const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
        if (!descriptor || !descriptor.enumerable || !Object.hasOwn(descriptor, "value")) throw new Error(`Invalid ${label}`);
    }
}

function integer(value, lower, upper, label) {
    if (!Number.isInteger(value) || value < lower || value > upper) throw new Error(`Invalid ${label}`);
}

function beat(value, triplet, group) {
    fields(value, ["duration", "dots", "notes"], "beat");
    if (!durations.has(value.duration)) throw new Error("Unsupported duration");
    if (![0, 1].includes(value.dots) || (triplet && value.dots !== 0)) throw new Error("Unsupported dots");
    array(value.notes, 6, "notes");
    const usedStrings = new Set();
    const notes = value.notes.map(note => {
        fields(note, ["string", "fret"], "note");
        integer(note.string, 1, 6, "string");
        integer(note.fret, 0, 36, "fret");
        if (usedStrings.has(note.string)) throw new Error("Duplicate string in chord");
        usedStrings.add(note.string);
        return { string: note.string, fret: note.fret };
    });
    let ticks = 3840 / value.duration;
    if (value.dots === 1) ticks = ticks * 3 / 2;
    if (triplet) ticks = ticks * 2 / 3;
    if (!Number.isSafeInteger(ticks)) throw new Error("Inexact beat duration");
    return { duration: value.duration, dots: value.dots, notes, ticks, group };
}

function validate(input) {
    fields(input, ["version", "title", "tempo", "meter", "tuning", "bars"], "draft");
    if (input.version !== 2) throw new Error("Unsupported draft version");
    if (typeof input.title !== "string" || input.title.length > 512 || Array.from(input.title).length > 256) throw new Error("Invalid title");
    integer(input.tempo, 1, 999, "tempo");
    fields(input.meter, ["numerator", "denominator"], "meter");
    if (input.meter.numerator !== 4 || input.meter.denominator !== 4) throw new Error("Unsupported meter");
    array(input.tuning, tuning.length, "tuning");
    if (input.tuning.length !== tuning.length || !tuning.every((value, index) => value === input.tuning[index])) throw new Error("Unsupported tuning");
    array(input.bars, 64, "bars");
    if (input.bars.length === 0) throw new Error("Invalid bars");
    let nextGroup = 0;
    let totalBeats = 0;
    let totalNotes = 0;
    return input.bars.map(bar => {
        array(bar, 128, "bar");
        if (bar.length === 0) throw new Error("Invalid bar");
        const beats = [];
        for (const item of bar) {
            if (item && typeof item === "object" && Object.hasOwn(item, "tuplet")) {
                fields(item, ["tuplet", "beats"], "tuplet group");
                fields(item.tuplet, ["numerator", "denominator"], "tuplet ratio");
                array(item.beats, 3, "triplet beats");
                if (item.tuplet.numerator !== 3 || item.tuplet.denominator !== 2 || item.beats.length !== 3) throw new Error("Unsupported triplet group");
                const group = nextGroup++;
                const members = item.beats.map(value => beat(value, true, group));
                if (!members.every(member => member.duration === members[0].duration)) throw new Error("Mixed triplet durations");
                beats.push(...members);
            } else {
                beats.push(beat(item, false, null));
            }
        }
        if (beats.length > 128) throw new Error("Too many beats");
        totalBeats += beats.length;
        totalNotes += beats.reduce((sum, value) => sum + value.notes.length, 0);
        // Temporary safety bounds, not measured iPad mini 6 capacity.
        if (totalBeats > 512 || totalNotes > 512) throw new Error("Draft exceeds experimental size limits");
        if (beats.reduce((sum, value) => sum + value.ticks, 0) !== 3840) throw new Error("Bar must fill 4/4 exactly");
        return beats;
    });
}

function alphaText(beats) {
    return beats.map(value => {
        let text = "r";
        if (value.notes.length === 1) text = `${value.notes[0].fret}.${value.notes[0].string}`;
        if (value.notes.length > 1) text = `(${value.notes.map(n => `${n.fret}.${n.string}`).join(" ")})`;
        return `:${value.duration} ${text}`;
    }).join(" ");
}

function exportDraft(alphaTab, input) {
    const bars = validate(input);
    const settings = new alphaTab.Settings();
    const importer = new alphaTab.importer.AlphaTexImporter();
    importer.initFromString(`\\tempo ${input.tempo} . ` + bars.map(alphaText).join(" | "), settings);
    const score = importer.readScore();
    score.title = input.title;
    const staff = score.tracks[0].staves[0];
    if (staff.bars.length !== bars.length) throw new Error("Imported bar count mismatch");
    for (let i = 0; i < bars.length; i++) {
        const voices = staff.bars[i].voices;
        if (voices.length !== 1 || voices[0].beats.length !== bars[i].length) throw new Error("Imported beat count mismatch");
        for (let j = 0; j < bars[i].length; j++) {
            const expected = bars[i][j];
            const actual = voices[0].beats[j];
            actual.dots = expected.dots;
            if (expected.group !== null) {
                actual.tupletNumerator = 3;
                actual.tupletDenominator = 2;
            }
        }
    }
    const bytes = new alphaTab.exporter.Gp7Exporter().export(score, settings);
    const restored = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, settings);
    verify(restored, input, bars);
    return bytes;
}

function verify(score, input, bars) {
    const fail = () => { throw new Error("GP round-trip verification failed"); };
    if (score.title !== input.title || score.tempo !== input.tempo || score.tracks.length !== 1 ||
        score.masterBars.length !== bars.length || score.tracks[0].staves.length !== 1) fail();
    const playback = score.tracks[0].playbackInfo;
    if (!playback || playback.program !== 25 || playback.bank !== 0 || playback.isMute !== false ||
        playback.isSolo !== false || playback.volume !== 15 || playback.balance !== 8 ||
        playback.port !== 1 || playback.primaryChannel !== 0 || playback.secondaryChannel !== 1) fail();
    const staff = score.tracks[0].staves[0];
    const highToLow = [...tuning].reverse();
    if (JSON.stringify(staff.stringTuning.tunings) !== JSON.stringify(highToLow) || staff.capo !== 0 ||
        staff.transpositionPitch !== 0 || staff.isPercussion || staff.bars.length !== bars.length) fail();
    for (let i = 0; i < bars.length; i++) {
        const master = score.masterBars[i];
        const bar = staff.bars[i];
        if (master.timeSignatureNumerator !== 4 || master.timeSignatureDenominator !== 4 ||
            master.start !== i * 3840 || master.isRepeatStart || master.isRepeatEnd || master.repeatCount !== 0 ||
            master.alternateEndings !== 0 || master.tripletFeel !== 0 || master.isFreeTime ||
            master.tempoAutomations.length !== (i === 0 ? 1 : 0) ||
            (i === 0 && (master.tempoAutomations[0].value !== input.tempo ||
                master.tempoAutomations[0].ratioPosition !== 0 || master.tempoAutomations[0].isLinear)) ||
            bar.voices.length !== 1 || bar.voices[0].beats.length !== bars[i].length) fail();
        let start = 0;
        const groups = new Map();
        for (let j = 0; j < bars[i].length; j++) {
            const expected = bars[i][j];
            const actual = bar.voices[0].beats[j];
            if (actual.duration !== expected.duration || actual.dots !== expected.dots ||
                actual.tupletNumerator !== (expected.group === null ? -1 : 3) ||
                actual.tupletDenominator !== (expected.group === null ? -1 : 2) ||
                actual.playbackStart !== start || actual.playbackDuration !== expected.ticks ||
                actual.absolutePlaybackStart !== i * 3840 + start ||
                actual.graceType !== 0 || actual.isLegatoOrigin || actual.isLetRing || actual.isPalmMute ||
                actual.notes.length !== expected.notes.length || actual.isRest !== (expected.notes.length === 0)) fail();
            if (expected.group !== null) {
                if (!actual.tupletGroup || actual.tupletGroup.beats.length !== 3) fail();
                if (groups.has(expected.group) && groups.get(expected.group) !== actual.tupletGroup) fail();
                groups.set(expected.group, actual.tupletGroup);
            }
            if (actual.notes.some(note => note.isTieDestination || note.isDead || note.isGhost || note.isStaccato ||
                note.isPalmMute || note.isLetRing || note.isHammerPullOrigin || note.slideInType !== 0 ||
                note.slideOutType !== 0 || note.harmonicType !== 0 || note.trillValue !== -1 || note.bendType !== 0)) fail();
            const actualNotes = actual.notes.map(note => ({ string: 7 - note.string, fret: note.fret, real: note.realValue }))
                .sort((a, b) => a.string - b.string);
            const expectedNotes = expected.notes.map(note => ({ ...note, real: highToLow[note.string - 1] + note.fret }))
                .sort((a, b) => a.string - b.string);
            if (JSON.stringify(actualNotes) !== JSON.stringify(expectedNotes)) fail();
            start += expected.ticks;
        }
        if (new Set(groups.values()).size !== groups.size) fail();
        for (const [id, group] of groups) {
            const members = bars[i].flatMap((beat, index) => beat.group === id ? [bar.voices[0].beats[index]] : []);
            if (members.length !== 3 || group.beats.some((member, index) => member !== members[index])) fail();
        }
    }
}

module.exports = { exportDraft, validate };

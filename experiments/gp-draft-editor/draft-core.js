"use strict";

// A deliberately limited experiment for newly generated drafts. It cannot open
// existing GP files; importing them would silently discard unsupported content.
const DURATIONS = new Set([1, 2, 4, 8, 16, 32, 64]);

function objectWithKeys(value, keys, label) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} 格式错误`);
    const actual = Object.keys(value);
    if (actual.length !== keys.length || keys.some(key => !actual.includes(key))) {
        throw new Error(`${label} 包含缺失或不支持的内容`);
    }
}

function integer(value, min, max, label) {
    if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${label} 不合法`);
    return value;
}

function checkedNote(note) {
    if (note && typeof note === "object" && Object.hasOwn(note, "rest")) {
        objectWithKeys(note, ["rest", "duration"], "休止符");
        if (note.rest !== true) throw new Error("休止符格式错误");
        if (!DURATIONS.has(note.duration)) throw new Error("时值不受支持");
        return { rest: true, duration: note.duration };
    }
    objectWithKeys(note, ["string", "fret", "duration"], "音符");
    integer(note.string, 1, 6, "弦号");
    integer(note.fret, 0, 36, "品位");
    if (!DURATIONS.has(note.duration)) throw new Error("时值不受支持");
    return { string: note.string, fret: note.fret, duration: note.duration };
}

function createDraft(alphaTab, input) {
    objectWithKeys(input, ["title", "tempo", "bars"], "草稿");
    if (typeof input.title !== "string") throw new Error("标题格式错误");
    integer(input.tempo, 1, 999, "速度");
    if (!Array.isArray(input.bars) || input.bars.length === 0) throw new Error("至少需要一个小节");
    const { title, tempo } = input;
    const bars = input.bars.map(bar => {
        if (!Array.isArray(bar) || bar.length === 0) throw new Error("每个小节至少需要一个音符");
        return bar.map(checkedNote);
    });

    function noteAt(barIndex, noteIndex) {
        integer(barIndex, 0, bars.length - 1, "小节位置");
        integer(noteIndex, 0, bars[barIndex].length - 1, "音符位置");
        return bars[barIndex][noteIndex];
    }

    return Object.freeze({
        notes() {
            return bars.map(bar => bar.map(note => ({ ...note })));
        },
        setFret(barIndex, noteIndex, fret) {
            integer(fret, 0, 36, "品位");
            const note = noteAt(barIndex, noteIndex);
            if (note.rest) throw new Error("休止符不能设置品位");
            note.fret = fret;
        },
        setDuration(barIndex, noteIndex, duration) {
            if (!DURATIONS.has(duration)) throw new Error("时值不受支持");
            noteAt(barIndex, noteIndex).duration = duration;
        },
        setRest(barIndex, noteIndex) {
            const previous = noteAt(barIndex, noteIndex);
            bars[barIndex][noteIndex] = { rest: true, duration: previous.duration };
        },
        setNote(barIndex, noteIndex, string, fret) {
            integer(string, 1, 6, "弦号");
            integer(fret, 0, 36, "品位");
            const previous = noteAt(barIndex, noteIndex);
            bars[barIndex][noteIndex] = { string, fret, duration: previous.duration };
        },
        exportGp() {
            // This experiment only creates 4/4 bars of plain notes and rests. An incomplete
            // edit is allowed in memory, but never written as a misleading GP.
            if (bars.some(bar => bar.reduce((total, note) => total + 64 / note.duration, 0) !== 64)) {
                throw new Error("每小节时值之和必须为 4/4");
            }
            const source = `\\tempo ${tempo} . ` + bars.map(bar =>
                bar.map(note => `:${note.duration} ${note.rest ? "r" : `${note.fret}.${note.string}`}`).join(" ")
            ).join(" | ");
            const settings = new alphaTab.Settings();
            const importer = new alphaTab.importer.AlphaTexImporter();
            importer.initFromString(source, settings);
            const score = importer.readScore();
            score.title = title;
            return new alphaTab.exporter.Gp7Exporter().export(score, settings);
        }
    });
}

// Bridge only our new versioned draft format. This is not an existing GP
// importer: any unknown field must be rejected rather than discarded.
function exportStoredDraft(alphaTab, input) {
    objectWithKeys(input, ["version", "title", "tempo", "bars"], "已保存的草稿");
    if (input.version !== 1) throw new Error("草稿版本不受支持");
    if (!Array.isArray(input.bars) || input.bars.length > 512 ||
        input.bars.some(bar => !Array.isArray(bar) || bar.length > 128)) {
        throw new Error("草稿小节数量不受支持");
    }
    const draft = createDraft(alphaTab, { title: input.title, tempo: input.tempo, bars: input.bars });
    const expected = draft.notes();
    const bytes = draft.exportGp();

    // Never return an apparently successful export if the GP writer dropped or
    // changed an event. This compares the actual re-imported playback timeline.
    const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
    const mismatch = () => { throw new Error("导出校验失败，未返回 GP 文件"); };
    if (score.title !== input.title || score.tempo !== input.tempo || score.tracks.length !== 1 ||
        score.masterBars.length !== expected.length || score.tracks[0].staves.length !== 1) mismatch();
    const staff = score.tracks[0].staves[0];
    const tuning = staff.stringTuning.tunings;
    if (JSON.stringify(tuning) !== JSON.stringify([64, 59, 55, 50, 45, 40]) ||
        staff.bars.length !== expected.length) mismatch();
    for (let barIndex = 0; barIndex < expected.length; barIndex++) {
        const master = score.masterBars[barIndex];
        const bar = staff.bars[barIndex];
        if (master.timeSignatureNumerator !== 4 || master.timeSignatureDenominator !== 4 ||
            bar.voices.length !== 1 || bar.voices[0].beats.length !== expected[barIndex].length) mismatch();
        let start = 0;
        for (let eventIndex = 0; eventIndex < expected[barIndex].length; eventIndex++) {
            const event = expected[barIndex][eventIndex];
            const beat = bar.voices[0].beats[eventIndex];
            const duration = 3840 / event.duration;
            if (beat.duration !== event.duration || beat.playbackStart !== start ||
                beat.playbackDuration !== duration) mismatch();
            if (event.rest) {
                if (!beat.isRest || beat.notes.length !== 0) mismatch();
            } else if (beat.isRest || beat.notes.length !== 1 ||
                       7 - beat.notes[0].string !== event.string || beat.notes[0].fret !== event.fret ||
                       beat.notes[0].realValue !== tuning[event.string - 1] + event.fret) mismatch();
            start += duration;
        }
    }
    return bytes;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { createDraft, exportStoredDraft };
} else {
    globalThis.RiffLoopDraftEditor = Object.freeze({ createDraft, exportStoredDraft });
}

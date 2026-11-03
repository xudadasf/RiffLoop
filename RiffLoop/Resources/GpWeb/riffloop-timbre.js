(() => {
    const programs = new Set([24, 25, 26, 27, 28, 29, 30]);
    const channels = track => new Set([
        track?.playbackInfo?.primaryChannel,
        track?.playbackInfo?.secondaryChannel
    ]);

    const canChange = (score, index) => {
        const tracks = score?.tracks || [];
        const track = tracks.find(item => item.index === index);
        if (!track || (track.staves || []).some(staff => staff.isPercussion)) return false;
        const used = channels(track);
        if ([...used].some(channel => !Number.isInteger(channel) || channel < 0 || channel === 9)) return false;
        return !tracks.some(other => other !== track && [...channels(other)].some(channel => used.has(channel)));
    };

    const apply = (midiFile, score, entries, alphaTab) => {
        const overrides = new Map();
        for (const entry of entries || []) {
            if (!Array.isArray(entry) || entry.length !== 2) continue;
            const [index, program] = entry;
            if (Number.isInteger(index) && programs.has(program) && canChange(score, index)) {
                overrides.set(index, { program, channels: channels(score.tracks.find(track => track.index === index)) });
            }
        }
        for (const event of midiFile.events) {
            const override = overrides.get(event.track);
            if (!override || !override.channels.has(event.channel)) continue;
            if (event instanceof alphaTab.midi.ProgramChangeEvent) {
                event.program = override.program;
            } else if (event instanceof alphaTab.midi.ControlChangeEvent &&
                [alphaTab.midi.ControllerType.BankSelectCoarse, alphaTab.midi.ControllerType.BankSelectFine].includes(event.controller)) {
                event.value = 0;
            }
        }
    };

    window.RiffLoopTimbre = { canChange, apply };
})();

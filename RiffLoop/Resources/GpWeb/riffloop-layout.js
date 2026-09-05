(() => {
    "use strict";
    const rhythmHeight = (tracks) => (tracks || []).some(track =>
        (track.staves || []).some(staff => staff.showTablature &&
            (staff.bars || []).some(bar => (bar.voices || []).some(voice =>
                (voice.beats || []).some(beat => (beat.notes || []).some(note =>
                    note.isHammerPullOrigin || note.isHammerPullDestination)))))) ? 50 : 25;

    window.RiffLoopLayout = {
        rhythmHeight,
        zoom: value => Number.isFinite(Number(value)) ? Math.min(1.5, Math.max(0.8, Number(value))) : 1
    };
})();

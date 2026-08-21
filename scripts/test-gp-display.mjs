import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const html = readFileSync(
    new URL("../RiffLoop/Resources/GpWeb/index.html", import.meta.url),
    "utf8"
);
const script = readFileSync(
    new URL("../RiffLoop/Resources/GpWeb/riffloop-gp.js", import.meta.url),
    "utf8"
);

const cssRule = (selector) => {
    const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = html.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`));
    assert.ok(match, `${selector} style is missing`);
    return match[1];
};

const beatCursor = cssRule(".at-cursor-beat");
assert.doesNotMatch(
    beatCursor,
    /\bwidth\s*:/,
    "the beat cursor width must remain controlled by alphaTab's inline transform"
);
assert.match(beatCursor, /background\s*:\s*transparent/i, "the moving cursor layer must not cover notation");
const beatCursorLine = cssRule(".at-cursor-beat::after");
assert.match(beatCursorLine, /width\s*:\s*2px/i, "the visible beat cursor line must be thin");
assert.match(
    beatCursorLine,
    /background\s*:\s*rgba\(0,\s*122,\s*255,\s*0\.82\)/i,
    "the thin beat cursor must remain visibly blue"
);

const barCursor = cssRule(".at-cursor-bar");
assert.match(barCursor, /rgba\(0,\s*122,\s*255,\s*0\.1\)/i, "the current bar must use a subtle blue tint");

assert.match(html, /\.at-highlight\s*,\s*\.at-highlight\s+\*/, "played notation needs a visible highlight rule");
assert.match(html, /fill\s*:\s*#006edc/i, "played notation must visibly differ from unplayed notation");

assert.match(script, /scrollMode\s*:\s*alphaTab\.ScrollMode\.Smooth/, "score following must use smooth scrolling");
assert.match(script, /enableAnimatedBeatCursor\s*:\s*true/, "the beat cursor must animate between beats");
assert.match(script, /enableElementHighlighting\s*:\s*true/, "played notation highlighting must be enabled");
assert.match(
    script,
    /const playbackRangeTrack = \(\) => api\.tracks\?\.\[0\]/,
    "range selection must use the currently rendered track"
);
assert.match(
    script,
    /const playbackRangeBeats[\s\S]*?staves\?\.\[0\][\s\S]*?voices\?\.\[0\]/,
    "range selection endpoints must stay in the same rendered staff and voice"
);
assert.match(
    script,
    /const refreshPendingRangeHighlight[\s\S]*?try\s*\{[\s\S]*?highlightPlaybackRange[\s\S]*?catch/,
    "range highlighting must tolerate a render that has not produced bounds yet"
);

console.log("GP playback display policy passed");

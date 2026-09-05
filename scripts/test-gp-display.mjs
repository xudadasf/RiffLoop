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
const gpView = readFileSync(
    new URL("../RiffLoop/GP/GpPracticeView.swift", import.meta.url),
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
assert.match(beatCursorLine, /width\s*:\s*70%/i, "the visible beat cursor must retain 70% of alphaTab's beat width");
assert.match(
    beatCursorLine,
    /background\s*:\s*rgba\(0,\s*122,\s*255,\s*0\.28\)/i,
    "the wider beat cursor must stay translucent so notation remains visible"
);

const barCursor = cssRule(".at-cursor-bar");
assert.match(barCursor, /rgba\(0,\s*122,\s*255,\s*0\.1\)/i, "the current bar must use a subtle blue tint");
const loopSelection = cssRule(".at-selection div");
assert.match(
    loopSelection,
    /rgba\(0,\s*92,\s*210,\s*0\.2\)/i,
    "the selected loop must use a blue tint slightly deeper than the current bar"
);

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
{
    const start = script.indexOf("    const refreshPendingRangeHighlight = () => {");
    const end = script.indexOf("\n    const hitScorePosition", start);
    assert.notEqual(start, -1, "range highlight refresh implementation is missing");
    assert.notEqual(end, -1, "range highlight refresh boundary is missing");
    assert.doesNotMatch(
        script.slice(start, end),
        /pendingRangeHighlight\s*=\s*null/,
        "a successful redraw must retain the committed range so later interactions can restore its highlight"
    );
}
assert.match(
    script,
    /const closestRangeBeat[\s\S]*?pendingRangeHighlight\.startTick[\s\S]*?pendingRangeHighlight\.endTick/,
    "range highlighting must resolve the selected start and end beats instead of whole bars"
);
assert.match(
    script,
    /previewRange\(firstBar, lastBar, startTick, endTick\)/,
    "native range previews must include precise note ticks"
);
assert.match(
    script,
    /api\.playerStateChanged\.on\(\(state\) => \{[\s\S]*?refreshPendingRangeHighlight\(\);[\s\S]*?post\("playerStateChanged"/,
    "play and pause state changes must restore the active loop highlight"
);
assert.ok(
    script.indexOf("    const refreshPendingRangeHighlight = () => {")
        < script.indexOf("    api.playerStateChanged.on((state) => {"),
    "the range highlight refresher must be initialized before playerStateChanged can fire synchronously"
);
assert.match(
    script,
    /cancelRangePreview\(\) \{[\s\S]*?if \(bars\)[\s\S]*?else \{[\s\S]*?pendingRangeHighlight = null;[\s\S]*?clearPlaybackRangeHighlight\(\)/,
    "cancelling an uncommitted selection must not let a later state change restore it"
);
assert.doesNotMatch(
    gpView,
    /\.popover\(isPresented: panelBinding\(for: panel\)/,
    "GP settings must stay non-modal so transport controls remain interactive"
);
assert.match(
    gpView,
    /GpWebView\(viewModel: viewModel\)[\s\S]*?simultaneousGesture\([\s\S]*?activePanel = nil/,
    "tapping the GP score must dismiss the non-modal settings panel"
);
assert.doesNotMatch(
    gpView,
    /Label\("更多", systemImage: "ellipsis"\)/,
    "the GP toolbar must not duplicate the bottom control panels"
);
assert.match(
    gpView,
    /if let panel = activePanel \{[\s\S]*?panelContent\(panel\)/,
    "the selected GP settings must render as an in-page overlay"
);
{
    const start = script.indexOf("    const seekBoth = (tick, options = {}) => {");
    const end = script.indexOf("\n    const stopTick", start);
    assert.notEqual(start, -1, "coordinated seek implementation is missing");
    assert.notEqual(end, -1, "coordinated seek implementation boundary is missing");
    assert.match(
        script.slice(start, end),
        /refreshPendingRangeHighlight\(\);/,
        "tapping a note inside an active loop must restore the loop highlight after seeking"
    );
}

console.log("GP playback display policy passed");
const layoutSource = readFileSync(new URL('../RiffLoop/Resources/GpWeb/riffloop-layout.js', import.meta.url), 'utf8');
const layoutWindow = {};
new Function('window', layoutSource)(layoutWindow);
const layout = layoutWindow.RiffLoopLayout;
assert.equal(layout.rhythmHeight([]), 25);
assert.equal(layout.zoom(NaN), 1);
assert.equal(layout.zoom(0), .8);
assert.equal(layout.zoom(3), 1.5);
const legatoTrack = {staves:[{showTablature:true,bars:[{voices:[{beats:[{notes:[{isHammerPullOrigin:true}]}]}]}]}]};
assert.equal(layout.rhythmHeight([legatoTrack]), 50);
assert.equal(layout.rhythmHeight([{staves: [{showTablature:false}]}]), 25);

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const gpWeb = read("RiffLoop/Resources/GpWeb/riffloop-gp.js");
const gpPage = read("RiffLoop/Resources/GpWeb/index.html");
const gpView = read("RiffLoop/GP/GpPracticeView.swift");
const metronome = read("RiffLoop/Audio/MetronomeEngine.swift");
const pdfView = read("RiffLoop/PDF/PdfPracticeView.swift");
const pdfViewModel = read("RiffLoop/PDF/PdfPracticeViewModel.swift");

assert.match(
    gpWeb,
    /const scoreFollowOffset = \(height\) => -Math\.round\(Math\.max\(0, Number\(height\) \|\| 0\) \* 0\.42\);[\s\S]*?scrollOffsetY: scoreFollowOffset/,
    "the active GP row must be vertically centered with room for following rows"
);
assert.match(
    gpWeb,
    /const createTransportController = \(deps\) => \{[\s\S]*?schedule\(pauseAgain, 80\);[\s\S]*?schedule\(pauseAgain, 240\);/,
    "GP pause must retry both transports after asynchronous player startup settles"
);
assert.match(
    gpWeb,
    /pause\(\) \{ transport\.pause\(\); \}/,
    "every native pause command must use the coordinated GP transport"
);
assert.match(
    gpWeb,
    /reportState: \(playing, stopped\) => post\("playerStateChanged", \{[\s\S]*?state: playing \? 1 : 0/,
    "GP controls and paused-only loop actions must follow the coordinated transport state"
);
assert.match(
    gpWeb,
    /api\.playerStateChanged\.on\(\(state\) => post\("playerStateChanged", \{[\s\S]*?state: transport\.isPlayingIntent\(\) \? 1 : 0/,
    "late alphaTab state events must not overwrite the coordinated GP transport state"
);
assert.match(
    gpView,
    /\.overlay\(alignment: \.bottomLeading\) \{[\s\S]*?if viewModel\.loopRange != nil, !viewModel\.isPlaying \{[\s\S]*?Button\(action: viewModel\.clearLoop\)[\s\S]*?退出区间循环/,
    "the loop exit action must appear directly over the score while playback is paused"
);

for (const expected of [
    /frequency: 2_600,[\s\S]*?amplitude: 0\.95,[\s\S]*?decay: 65/,
    /frequency: 1_800,[\s\S]*?amplitude: 0\.66,[\s\S]*?decay: 85/,
    /frequency: 1_100,[\s\S]*?amplitude: 0\.44,[\s\S]*?decay: 105/,
]) {
    assert.match(metronome, expected, "native strong, secondary and normal clicks must be clearly separated");
}
assert.match(gpWeb, /if \(accent === "subAccent"\) return 0\.32;/);
assert.match(gpWeb, /return 0\.10;/);
assert.match(
    gpPage,
    /\.at-cursor-beat\s*\{[\s\S]*?background: transparent !important;[\s\S]*?\.at-cursor-beat::after\s*\{[\s\S]*?width: 70%;[\s\S]*?background: rgba\(0, 122, 255, 0\.28\);/,
    "the GP beat cursor must stay visible without fully covering the note beneath it"
);
assert.match(
    gpWeb,
    /setBackingEnabled\(enabled\) \{[\s\S]*?transport\.pause\(\);[\s\S]*?backingSynchronizer\.align\(api\.timePosition\)/,
    "enabling embedded backing mid-score must pause and align it to the current score time"
);

assert.match(pdfView, /Button\("控制", action: openPracticePanel\)/);
assert.match(pdfView, /Button\("返回 PDF"\)[\s\S]*?closePracticePanel\(\)/);
assert.match(pdfView, /\.background\(\.black\.opacity\(0\.82\)\)/);
assert.match(pdfView, /\.zIndex\(3\)/);
assert.match(pdfView, /暂停伴奏|播放伴奏/);
assert.match(pdfView, /暂停节拍器|启动节拍器/);
assert.match(pdfView, /伴奏开头＝第1拍/);
assert.match(pdfView, /当前位置＝第1拍/);
assert.match(pdfViewModel, /func toggleAudioPlayback\(\)/);
assert.match(pdfViewModel, /func toggleMetronomePlayback\(\)/);
assert.match(pdfViewModel, /func setBeatOneAtAudioStart\(\)/);
assert.match(pdfViewModel, /func setBeatOneAtCurrentPosition\(\)/);

console.log("Reported iOS issue policies passed");

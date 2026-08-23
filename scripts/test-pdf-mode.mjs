import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const pdfView = read("RiffLoop/PDF/PdfPracticeView.swift");
const pdfKitView = read("RiffLoop/PDF/PdfKitView.swift");
const pdfViewModel = read("RiffLoop/PDF/PdfPracticeViewModel.swift");
const documentLibrary = read("RiffLoop/Library/DocumentLibraryView.swift");

assert.match(
    pdfView,
    /ContentUnavailableView\s*\{[\s\S]*?选择 PDF 开始练习[\s\S]*?\}\s*actions:\s*\{[\s\S]*?Button\("选择或导入 PDF"\)\s*\{\s*pdfLibraryPresented = true/,
    "the empty PDF page must expose a visible choose/import action"
);
assert.match(
    pdfView,
    /\.toolbar\s*\{[\s\S]*?Label\(viewModel\.document == nil \? "选择 PDF" : "更换 PDF", systemImage: "folder"\)/,
    "the navigation bar must keep a visible choose/replace PDF action"
);
assert.doesNotMatch(
    documentLibrary,
    /if model\.kind == \.guitarPro \|\| model\.kind == \.video\s*\{[\s\S]*?Button\(role: \.destructive\)/,
    "PDF files must not be excluded from the shared library deletion flow"
);
assert.match(
    pdfView,
    /if viewModel\.openPdf\(at: url\)\s*\{[\s\S]*?recentProjects\.opened\(kind: \.pdf/,
    "a corrupt or stale PDF must not be written to recent projects"
);
assert.match(
    pdfKitView,
    /name: \.PDFViewScaleChanged[\s\S]*?onScaleChanged/,
    "pinch zoom changes must be written back to the PDF profile"
);
assert.match(
    pdfKitView,
    /observe\(\\\.contentSize[\s\S]*?pendingProgress[\s\S]*?applyProgress/,
    "restored PDF scroll progress must wait until PDFKit has a laid-out content size"
);
assert.match(
    pdfViewModel,
    /private var metronomeOnlyTimer: Timer\?[\s\S]*?anchor\.mediaTime\(forHostTime:/,
    "metronome-only PDF practice must advance the shared media timeline"
);
assert.match(
    pdfViewModel,
    /AVPlayerItemDidPlayToEndTime[\s\S]*?handleAudioPlaybackEnded/,
    "PDF backing playback state must converge when the item reaches its end"
);
assert.match(
    pdfViewModel,
    /AVPlayerItemFailedToPlayToEndTime[\s\S]*?handleAudioPlaybackFailed/,
    "a broken PDF backing file must leave the playing state and report an error"
);
assert.match(
    pdfViewModel,
    /AVAudioSession\.interruptionNotification[\s\S]*?InterruptionType\(rawValue: rawValue\) == \.began[\s\S]*?self\?\.pause\(\)/,
    "an audio interruption must converge PDF backing and metronome state"
);
assert.match(
    pdfViewModel,
    /func openPdf\(at url: URL\) -> Bool \{[\s\S]*?pause\(\)[\s\S]*?resetAudioItem\(\)[\s\S]*?self\.document = document/,
    "switching PDFs must clear the previous backing transport before restoring the new profile"
);
assert.match(
    pdfViewModel,
    /private func handleLoopBoundary\(\)[\s\S]*?let generation = transportGeneration[\s\S]*?self\.transportGeneration == generation/,
    "an obsolete loop seek must not restart PDF playback after the user pauses"
);
assert.match(
    pdfViewModel,
    /resumeMetronome \|\| self\.loopCountInEnabled[\s\S]*?stopMetronomeAfterCountIn: self\.loopCountInEnabled && !resumeMetronome/,
    "per-loop count-in must sound even when the continuous metronome was off"
);
assert.match(
    pdfViewModel,
    /func setPlaybackRate\(_ rate: Float\) \{[\s\S]*?speedLadderTarget = max\(speedLadderTarget, playbackRate\)/,
    "manually raising PDF speed must keep the ladder target reachable"
);
assert.match(
    pdfViewModel,
    /func setSpeedLadderTarget\(_ target: Float\) \{[\s\S]*?min\(max\(target, playbackRate\), 1\.5\)/,
    "the PDF speed ladder target must not be lower than the manual speed"
);
assert.match(
    pdfView,
    /\.safeAreaInset\(edge: \.bottom, spacing: 0\) \{[\s\S]*?controlDeck/,
    "the PDF score must use the shared bottom practice deck"
);
assert.match(
    pdfView,
    /private enum PdfControlPanel[\s\S]*?case loop[\s\S]*?case metronome[\s\S]*?case sound[\s\S]*?case follow/,
    "PDF tools must keep loop, metronome, backing, and following in separate cards"
);
assert.match(
    pdfView,
    /\.popover\(isPresented: panelBinding\(for: panel\), arrowEdge: \.bottom\)/,
    "PDF tool cards must open native iPad popovers"
);
assert.doesNotMatch(
    pdfView,
    /\.task\(id: controlsVisible\)|practicePanel\s*\.frame\(width: 340\)/,
    "PDF controls must not auto-hide or cover the score with the legacy side panel"
);

console.log("PDF mode policies passed");

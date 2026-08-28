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
    /private func apply\(_ profile: PdfPracticeProfile\) \{[\s\S]*?loopEnabled = false[\s\S]*?loopCountInEnabled = false[\s\S]*?speedLadderEnabled = false/,
    "legacy PDF profiles must not silently restore removed loop behavior"
);
assert.match(
    pdfViewModel,
    /pointA: nil,[\s\S]*?pointB: nil,[\s\S]*?loopEnabled: false,[\s\S]*?loopCountInEnabled: false,[\s\S]*?speedLadderEnabled: false/,
    "saved PDF profiles must migrate removed loop settings to disabled values"
);
assert.match(
    pdfView,
    /\.safeAreaInset\(edge: \.bottom, spacing: 0\) \{[\s\S]*?controlDeck/,
    "the PDF score must use the shared bottom practice deck"
);
assert.match(
    pdfView,
    /private enum PdfControlPanel[\s\S]*?case metronome[\s\S]*?case sound[\s\S]*?case follow/,
    "PDF tools must keep metronome, backing, and following in separate cards"
);
assert.doesNotMatch(
    pdfView,
    /case loop|\.loop|A\/B 循环|循环阶梯|每轮预备/,
    "PDF practice must not expose loop controls"
);
assert.match(
    pdfView,
    /if viewModel\.autoFollowSuspended \{[\s\S]*?Button\("继续跟谱", action: viewModel\.resumeAutoFollow\)/,
    "a manually suspended PDF reading track must expose a resume action"
);
assert.match(
    pdfView,
    /从轨迹起点开始[\s\S]*?startAutoFollowFromBeginning/,
    "saved PDF reading tracks must have an obvious replay entry point"
);
assert.match(
    pdfViewModel,
    /var isFollowingTransportActive: Bool \{ isAutoFollowing && isPlaying \}/,
    "the PDF primary transport must expose following state rather than raw metronome state"
);
assert.match(
    pdfViewModel,
    /func toggleReadingFollowPlayback\(\)[\s\S]*?startReadingFollow\(at:/,
    "the PDF primary play control must start a recorded reading track"
);
assert.match(
    pdfViewModel,
    /func setFollowLoopEnabled\(_ enabled: Bool\)[\s\S]*?followLoopEnabled = enabled/,
    "recorded reading tracks need an independent loop setting"
);
assert.match(
    pdfViewModel,
    /private func restartReadingFollowLoopIfNeeded\(\)[\s\S]*?prepareReadingFollow\(at:/,
    "reaching the final reading point must return through the follow transport"
);
assert.match(
    pdfViewModel,
    /func pause\(\) \{[\s\S]*?isReadingFollowLoopTransitioning = false/,
    "pausing during a follow-loop return must leave the next follow start available"
);
assert.match(
    pdfView,
    /Button\(action: viewModel\.toggleReadingFollowPlayback\)/,
    "the PDF bottom play button must operate the reading track"
);
assert.match(
    pdfView,
    /Toggle\("循环跟谱", isOn: Binding\([\s\S]*?setFollowLoopEnabled/,
    "the PDF follow panel must expose optional follow looping"
);
assert.match(
    pdfView,
    /\.overlay\(alignment: \.bottomTrailing\) \{[\s\S]*?if let panel = activePanel/,
    "PDF tool cards must open an in-page iPad settings panel"
);
assert.doesNotMatch(
    pdfView,
    /\.task\(id: controlsVisible\)|practicePanel\s*\.frame\(width: 340\)/,
    "PDF controls must not auto-hide or cover the score with the legacy side panel"
);
assert.doesNotMatch(
    pdfView,
    /\.popover\(isPresented: panelBinding\(for: panel\)/,
    "PDF settings must stay non-modal so transport controls remain interactive"
);
assert.match(
    pdfView,
    /onTap: \{ activePanel = nil \},[\s\S]*?onManualInteraction: viewModel\.manualViewportInteraction/,
    "interacting with the PDF display must dismiss settings"
);
assert.match(
    pdfKitView,
    /UITapGestureRecognizer\([\s\S]*?didTap[\s\S]*?parent\.onTap\(\)/,
    "PDF taps must be reported separately from scroll and zoom interactions"
);
assert.match(
    pdfView,
    /if let panel = activePanel \{[\s\S]*?panelContent\(panel\)/,
    "the selected PDF settings must render as an in-page overlay"
);
assert.doesNotMatch(
    pdfView,
    /Label\("更多", systemImage: "ellipsis"\)/,
    "the PDF toolbar must not duplicate bottom tool panels"
);

console.log("PDF mode policies passed");

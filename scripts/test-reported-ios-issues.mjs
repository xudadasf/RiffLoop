import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const gpWeb = read("RiffLoop/Resources/GpWeb/riffloop-gp.js");
const gpPage = read("RiffLoop/Resources/GpWeb/index.html");
const gpView = read("RiffLoop/GP/GpPracticeView.swift");
const metronome = read("RiffLoop/Audio/MetronomeEngine.swift");
const pdfView = read("RiffLoop/PDF/PdfPracticeView.swift");
const pdfViewModel = read("RiffLoop/PDF/PdfPracticeViewModel.swift");
const mediaViewModel = read("RiffLoop/Media/PracticeViewModel.swift");
const gpViewModel = read("RiffLoop/GP/GpWebViewModel.swift");
const gpNativeBackingPlayer = read("RiffLoop/GP/GpNativeBackingPlayer.swift");
const homeView = read("RiffLoop/UI/HomeView.swift");
const videoView = read("RiffLoop/UI/PracticeView.swift");
const documentLibrary = read("RiffLoop/Library/DocumentLibraryView.swift");
const displayNameStore = read("RiffLoop/Library/DocumentDisplayNameStore.swift");
const app = read("RiffLoop/App/RiffLoopApp.swift");
const practiceHistory = read("RiffLoop/Library/PracticeHistoryStore.swift");

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
    /pause\(\) \{[\s\S]*?rangeCountInRestarter\.cancel\(\); transport\.pause\(true\); \}/,
    "every native pause command must use the coordinated GP transport"
);
assert.match(
    gpWeb,
    /reportState: \(playing, stopped\) => post\("playerStateChanged", \{[\s\S]*?state: playing \? 1 : 0/,
    "GP controls and paused-only loop actions must follow the coordinated transport state"
);
assert.match(
    gpWeb,
    /api\.playerStateChanged\.on\(\(state\) => \{[\s\S]*?post\("playerStateChanged", \{[\s\S]*?state: transport\.isPlayingIntent\(\) \? 1 : 0/,
    "late alphaTab state events must not overwrite the coordinated GP transport state"
);
assert.match(
    gpView,
    /\.overlay\(alignment: \.bottomLeading\) \{[\s\S]*?if viewModel\.loopRange != nil, !viewModel\.isPlaying \{[\s\S]*?Button\(action: viewModel\.clearLoop\)[\s\S]*?退出区间循环/,
    "the loop exit action must appear directly over the score while playback is paused"
);
assert.match(
    gpView,
    /Picker\("目标速度"[\s\S]*?ForEach\(speeds\.filter \{ \$0 >= viewModel\.playbackSpeed \}/,
    "GP ladder target choices must not include speeds below the current manual speed"
);
assert.ok(
    gpView.includes('Text("当前第 \\(viewModel.currentSpeedLadderRound)/\\(viewModel.loopsPerSpeedStep) 轮 · \\(viewModel.playbackSpeed, specifier: "%.2f")×")'),
    "the GP ladder status must show the round currently in progress and its actual speed"
);

for (const expected of [
    /frequency: 2_600,[\s\S]*?amplitude: 0\.95,[\s\S]*?decay: 65/,
    /frequency: 1_800,[\s\S]*?amplitude: 0\.66,[\s\S]*?decay: 85/,
    /frequency: 1_100,[\s\S]*?amplitude: 0\.44,[\s\S]*?decay: 105/,
]) {
    assert.match(metronome, expected, "native strong, secondary and normal clicks must be clearly separated");
}
// GP audibility is verified from rendered PCM in test-gp-playback.mjs.
assert.doesNotMatch(
    gpWeb,
    /midiEventsPlayed[\s\S]*?pdfClickMetronome\.play/,
    "a delayed MIDI callback must never generate the audible GP metronome click"
);
assert.match(
    gpWeb,
    /midiFile\.addEvent\(new alphaTab\.midi\.ControlChangeEvent\([\s\S]*?metronomeControlValue\(pulse\)/,
    "GP beat accents must be inserted into alphaTab's MIDI buffer before playback"
);
assert.doesNotMatch(
    gpWeb,
    /midiEventsPlayed\.on\([\s\S]*?metronomeVolume/,
    "an already-played MIDI callback must not change the audible metronome volume"
);
assert.match(
    gpPage,
    /\.at-cursor-beat\s*\{[\s\S]*?background: transparent !important;[\s\S]*?\.at-cursor-beat::after\s*\{[\s\S]*?width: 70%;[\s\S]*?background: rgba\(0, 122, 255, 0\.28\);/,
    "the GP beat cursor must stay visible without fully covering the note beneath it"
);
assert.match(
    gpWeb,
    /setBackingEnabled\(enabled\) \{[\s\S]*?transport\.pause\(\);[\s\S]*?backingAligner\.align\(api\.timePosition\)/,
    "enabling embedded backing mid-score must pause and align it to the current score time"
);
assert.match(
    gpWeb,
    /setBackingAudible\(false\)[\s\S]*?synthApi\.play\(\)[\s\S]*?api\.play\(\)[\s\S]*?synthApi\.playerStateChanged\.on[\s\S]*?markBackingStarted\(api\.timePosition\)[\s\S]*?playerPositionChanged\.on\(\(position\) => \{[\s\S]*?startDeferredBacking\(position\.currentTime\)/,
    "embedded backing must prewarm silently and become audible only after both playback clocks are ready"
);
assert.match(
    gpViewModel,
    /gpBackingTime\([\s\S]*?forPlaybackTime: position\.currentTime,[\s\S]*?playbackSpeed: playbackSpeed/,
    "speed-adjusted alphaTab time must be converted back to the source-audio timeline"
);
assert.match(
    gpViewModel,
    /func setPlaybackSpeed\(_ speed: Double\) \{[\s\S]*?speedLadderTarget = max\(speedLadderTarget, playbackSpeed\)[\s\S]*?completedLoops = 0/,
    "manually raising GP speed must also raise the ladder target and restart its cadence"
);
assert.match(
    gpViewModel,
    /func setSpeedLadderTarget\(_ target: Double\) \{[\s\S]*?min\(max\(target, playbackSpeed\), 1\.5\)/,
    "the GP speed ladder target must never be lower than the current manual speed"
);
assert.match(
    gpViewModel,
    /private func recordLoopCompletion\(\) \{[\s\S]*?if update\.playbackSpeed != playbackSpeed \{[\s\S]*?applyEffectivePlaybackSpeed\(\)/,
    "a GP ladder speed increase must apply the user-base BPM scale"
);
assert.match(
    gpViewModel,
    /private func applyEffectivePlaybackSpeed\(\) \{[\s\S]*?nativeBackingPlayer\.setRate\(speed\)[\s\S]*?call\("setPlaybackSpeed", arguments: \[speed\]\)/,
    "native backing and alphaTab must receive the same effective BPM multiplier"
);
assert.match(
    gpNativeBackingPlayer,
    /AVAudioEngine\(\)[\s\S]*?AVAudioUnitTimePitch\(\)[\s\S]*?func setRate\(_ rate: Double\)[\s\S]*?gpNativeBackingRate\(rate\)/,
    "embedded backing must use a time-pitch audio chain that supports the full BPM scale"
);
assert.match(
    gpNativeBackingPlayer,
    /func load\(data: Data, mimeType: String\) throws \{[\s\S]*?AVAudioSession\.sharedInstance\(\)[\s\S]*?setActive\(true\)[\s\S]*?AVAudioFile\(forReading: url\)/,
    "the audio session must be active before the native backing engine starts"
);
{
    const synchronizeStart = gpViewModel.indexOf("    private func synchronizeNativeBacking");
    const synchronizeEnd = gpViewModel.indexOf("\n    private func appendNativeBackingDiagnostic", synchronizeStart);
    const synchronizeBody = gpViewModel.slice(synchronizeStart, synchronizeEnd);
    assert.doesNotMatch(
        synchronizeBody,
        /nativeBackingPlayer\.set(?:Rate|Volume)/,
        "ordinary position callbacks must not repeatedly reconfigure the native backing player"
    );
    assert.equal(
        synchronizeBody.match(/nativeBackingPlayer\.seek\(/g)?.length ?? 0,
        1,
        "one alphaTab seek event must reschedule native backing at most once"
    );
    assert.doesNotMatch(
        synchronizeBody,
        /currentTimeMilliseconds[\s\S]*?> 250[\s\S]*?nativeBackingPlayer\.seek/,
        "steady playback drift checks must not stop and reschedule audible backing"
    );
}

assert.match(gpView, /基准 BPM：[\s\S]*?恢复导入 BPM/);
assert.match(gpView, /1\.00× 以当前基准 BPM 为准/);
assert.match(
    gpView,
    /format: "基准 %\.0f BPM · 当前 %\.0f BPM · %\.2f×",[\s\S]*?viewModel\.currentBpm/,
    "the status must show the scaled BPM for the current tempo-map segment"
);
assert.match(
    gpWeb,
    /initialBpm,[\s\S]*?hasTempoChanges:[\s\S]*?originalTempo: Number\(position\.originalTempo\)/,
    "the bridge must expose the score base BPM and current tempo segment"
);
assert.doesNotMatch(
    gpViewModel,
    /recordLoopCompletionIfNeeded|previousPositionTick/,
    "Swift must not infer loop completions from throttled position callbacks"
);

for (const source of [mediaViewModel, pdfViewModel, gpViewModel]) {
    assert.match(source, /PracticeHistoryStore\.shared\.record\(/, "every practice mode must update daily history");
}
assert.match(homeView, /继续今天的练习[\s\S]*?continuePracticeCard/);
assert.match(homeView, /开始新的练习[\s\S]*?modeButton\(for: \.video\)[\s\S]*?modeButton\(for: \.guitarPro\)[\s\S]*?modeButton\(for: \.pdf\)/);
assert.match(homeView, /calendarDays\(weeks: 4\)[\s\S]*?最近一个月/);
assert.match(
    homeView,
    /welcomeHeader[\s\S]*?signingStatusCard[\s\S]*?continuePracticeCard/,
    "the signing status must be visible in the scroll content instead of collapsing to a toolbar icon"
);
assert.match(homeView, /Text\("签名与续签"\)[\s\S]*?signingExpirationTitle[\s\S]*?查看续签方法/);
assert.match(homeView, /expirationDate\.formatted\(date: \.long, time: \.shortened\)[\s\S]*?到期：/);
assert.match(homeView, /Automatic Refresh[\s\S]*?手动覆盖续签/);
assert.doesNotMatch(homeView, /ToolbarItem\(placement: \.topBarTrailing\)[\s\S]*?signingCompactTitle/);
assert.match(homeView, /最近项目[\s\S]*?recentProjectsPage/);
assert.match(homeView, /ForEach\(filteredRecentProjects\) \{ project in[\s\S]*?destination\(for: project\)/);
assert.doesNotMatch(homeView, /\.navigationTitle\("RiffLoop"\)/);
assert.match(homeView, /ProjectPreviewThumbnail[\s\S]*?projectOpeningPreview/);
assert.match(homeView, /generator\.image\(at: \.zero\)/, "video preview must be the opening frame");
assert.match(homeView, /PDFDocument\(url: url\)\?\.page\(at: 0\)/, "PDF preview must start on the first page");
assert.match(homeView, /NavigationStack(?:\(path: \$externalDocuments\))?\s*\{\s*ScrollView\s*\{/);
assert.match(practiceHistory, /calendarDays\(weeks: Int = 5/);
assert.match(practiceHistory, /while segmentStart < endingAt/, "sessions crossing midnight must be split by day");

assert.match(
    displayNameStore,
    /func displayName[\s\S]*?customNames\[key\(kind: kind, fileName: fileName\)\] \?\? fileName/,
    "an unset display name must fall back to the physical filename"
);
assert.match(app, /\.environmentObject\(displayNames\)/, "all screens must share one display-name store");
assert.match(homeView, /Text\(displayName\(for: project\)\)/, "the home screen must show custom display names");
assert.match(documentLibrary, /filePendingRename = model\.importExternalFile\(url\)/, "a successful import must offer display-name editing");
assert.match(documentLibrary, /恢复原文件名/, "the library must allow resetting a custom display name");
assert.match(videoView, /displayName\(for: \.video, fileName: currentFileName\)/, "the video page must show the shared display name");
assert.match(gpView, /displayName\(for: \.guitarPro, fileName: currentFileName\)/, "the GP page must show the shared display name");
assert.match(pdfView, /displayName\(for: \.pdf, fileName: fileName\)/, "the PDF page must show the shared display name");

assert.match(pdfView, /\.safeAreaInset\(edge: \.bottom, spacing: 0\)[\s\S]*?controlDeck/);
assert.match(pdfView, /toolButton\(\.sound,[\s\S]*?toolButton\(\.follow,/);
assert.match(pdfView, /\.background\(\.ultraThinMaterial\)/);
assert.match(pdfView, /\.overlay\(alignment: \.bottomTrailing\)[\s\S]*?if let panel = activePanel/);
assert.match(pdfView, /暂停伴奏|播放伴奏/);
assert.match(pdfView, /暂停节拍器|启动节拍器/);
assert.match(pdfView, /伴奏开头＝第1拍/);
assert.match(pdfView, /当前位置＝第1拍/);
assert.match(pdfViewModel, /func toggleAudioPlayback\(\)/);
assert.match(pdfViewModel, /func toggleMetronomePlayback\(\)/);
assert.match(pdfViewModel, /func setBeatOneAtAudioStart\(\)/);
assert.match(pdfViewModel, /func setBeatOneAtCurrentPosition\(\)/);

console.log("Reported iOS issue policies passed");

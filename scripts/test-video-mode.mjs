import assert from "node:assert/strict";
import fs from "node:fs";

const viewModelSource = fs.readFileSync("RiffLoop/Media/PracticeViewModel.swift", "utf8");
const viewSource = fs.readFileSync("RiffLoop/UI/PracticeView.swift", "utf8");
const metronomeSource = fs.readFileSync("RiffLoop/Audio/MetronomeEngine.swift", "utf8");
const librarySource = fs.readFileSync("RiffLoop/Library/DocumentLibraryView.swift", "utf8");

const checks = [];

function check(name, callback) {
    try {
        callback();
        checks.push({ name, passed: true });
    } catch (error) {
        checks.push({ name, passed: false, message: error.message });
    }
}

function functionBody(source, signature) {
    const signatureIndex = source.indexOf(signature);
    assert.notEqual(signatureIndex, -1, `Missing function: ${signature}`);
    const openingBrace = source.indexOf("{", signatureIndex);
    assert.notEqual(openingBrace, -1, `Missing opening brace: ${signature}`);

    let depth = 0;
    for (let index = openingBrace; index < source.length; index += 1) {
        if (source[index] === "{") depth += 1;
        if (source[index] === "}") depth -= 1;
        if (depth === 0) return source.slice(openingBrace + 1, index);
    }
    assert.fail(`Missing closing brace: ${signature}`);
}

check("speed resynchronization replaces the stale metronome scheduler", () => {
    assert.match(metronomeSource, /private var schedulerGeneration: UInt64\?/);
    const body = functionBody(metronomeSource, "private func startSchedulerIfNeeded()");
    assert.match(body, /scheduler == nil \|\| schedulerGeneration != generation/);
    assert.match(body, /scheduler\?\.cancel\(\)/);
    assert.match(body, /schedulerGeneration = generation/);
});

check("the first manual play waits for seek and preroll before synchronized start", () => {
    const toggleBody = functionBody(viewModelSource, "func togglePlayback()");
    assert.match(toggleBody, /preparePlaybackAndStart\(at: currentTime\)/);

    const body = functionBody(
        viewModelSource,
        "private func preparePlaybackAndStart(at mediaTime: TimeInterval)"
    );
    const seekIndex = body.indexOf("player.seek(");
    const prerollIndex = body.indexOf("self.player.preroll(atRate:");
    const startIndex = body.indexOf("self.coordinatedStart(at:");
    assert.ok(seekIndex >= 0, "manual start must finish an exact seek first");
    assert.ok(prerollIndex > seekIndex, "manual start must preroll after seeking");
    assert.ok(startIndex > prerollIndex, "synchronized start must happen after preroll");
});

check("resuming after a seek prerolls before restarting playback", () => {
    const body = functionBody(viewModelSource, "func seek(to seconds: TimeInterval)");
    const cancelIndex = body.indexOf("player.currentItem?.cancelPendingSeeks()");
    const seekIndex = body.indexOf("player.seek(");
    const prerollIndex = body.indexOf("self.player.preroll(atRate:");
    const startIndex = body.indexOf("self.coordinatedStart(at: target)");
    assert.ok(cancelIndex >= 0, "a new seek must cancel an older pending item seek");
    assert.ok(cancelIndex < seekIndex, "old item seeks must be cancelled before the new target is issued");
    assert.ok(prerollIndex >= 0, "a playing seek must preroll the target frame");
    assert.ok(startIndex > prerollIndex, "seek must restart only after preroll succeeds");
});

check("metronome fine adjustment keeps the video transport running", () => {
    const adjustmentBody = functionBody(
        viewModelSource,
        "func adjustSynchronization(by seconds: TimeInterval)"
    );
    assert.doesNotMatch(adjustmentBody, /applyTimingSettings\(\)/);
    assert.match(adjustmentBody, /resynchronizeMetronome\(\)/);

    const resyncBody = functionBody(
        viewModelSource,
        "private func resynchronizeMetronome()"
    );
    assert.match(resyncBody, /player\.currentTime\(\)/);
    assert.match(resyncBody, /metronome\.synchronize\(/);
    assert.doesNotMatch(resyncBody, /player\.pause\(\)/);
    assert.doesNotMatch(resyncBody, /player\.setRate\(/);

    const resetBody = functionBody(viewModelSource, "func resetSynchronization()");
    assert.match(resetBody, /synchronizationOffset = 0/);
    assert.match(resetBody, /resynchronizeMetronome\(\)/);
    assert.match(viewSource, /Button\("重置", action: viewModel\.resetSynchronization\)/);
});

check("enabling A/B loop seeks to point A through the coordinated transport", () => {
    const body = functionBody(viewModelSource, "func setLoopEnabled(_ enabled: Bool)");
    assert.match(body, /let loopEntryTarget = enabled \? pointA : nil/);
    assert.match(body, /seek\(to: loopEntryTarget\)/);
});

check("the video surface always offers an exit-loop button while looping", () => {
    assert.match(viewSource, /Label\("退出 A\/B 循环"/);
    assert.match(viewSource, /Button\(action: viewModel\.clearLoop\)/);
    assert.match(viewSource, /if viewModel\.loopEnabled \{/);
    assert.doesNotMatch(viewSource, /if viewModel\.loopEnabled, !viewModel\.isPlaying/);
});

check("enabling beat snap rewrites existing A/B values", () => {
    const body = functionBody(viewModelSource, "func setSnapLoopPointsToBeat(_ enabled: Bool)");
    assert.match(body, /pointA = pointA\.map \{ snapToNearestBeat/);
    assert.match(body, /pointB = pointB\.map \{ snapToNearestBeat/);
    assert.match(viewSource, /set: \{ viewModel\.setSnapLoopPointsToBeat\(\$0\) \}/);
});

check("the shared library exposes deletion for every practice mode", () => {
    assert.doesNotMatch(librarySource, /model\.kind == \.guitarPro \|\| model\.kind == \.video/);
    assert.match(librarySource, /model\.deleteFile\(fileURL\)/);
    assert.match(librarySource, /recentProjects\.remove\(/);
});

check("a single compact speed trigger keeps the current multiplier visible", () => {
    assert.match(viewSource, /Menu \{[\s\S]*?Button\(rateLabel\(rate\)\).*?\}[\s\S]*?Text\(rateLabel\(viewModel\.playbackRate\)\)/);
    const soundBody = functionBody(viewSource, "private var compactSoundSection: some View");
    assert.doesNotMatch(soundBody, /Picker\("手动速度"/);
    assert.match(viewSource, /"阶梯说明：/);
    assert.match(viewSource, /String\(format: "%\.2f×", rate\)/);
});

check("disabling the speed ladder restores its latest manual base speed", () => {
    assert.match(viewModelSource, /private var speedLadderBaseRate: Float\?/);

    const toggleBody = functionBody(viewModelSource, "func setSpeedLadderEnabled(_ enabled: Bool)");
    assert.match(toggleBody, /speedLadderBaseRate = playbackRate/);
    assert.match(toggleBody, /playbackRate = speedLadderBaseRate \?\? playbackRate/);
    assert.match(toggleBody, /restartAfterTimingChange\(\)/);

    const rateBody = functionBody(viewModelSource, "func setPlaybackRate(_ rate: Float)");
    assert.match(rateBody, /if speedLadderEnabled \{[\s\S]*?speedLadderBaseRate = playbackRate/);
    assert.match(viewSource, /关闭阶梯时恢复到最后一次手动选择的速度/);
});

check("the speed ladder target never falls below its manual base speed", () => {
    assert.match(
        viewModelSource,
        /var minimumSpeedLadderTarget: Float \{ speedLadderBaseRate \?\? playbackRate \}/
    );

    const rateBody = functionBody(viewModelSource, "func setPlaybackRate(_ rate: Float)");
    assert.match(rateBody, /speedLadderTarget = max\(speedLadderTarget, playbackRate\)/);

    const targetBody = functionBody(viewModelSource, "func setSpeedLadderTarget(_ target: Float)");
    assert.match(targetBody, /max\(target, minimumSpeedLadderTarget\)/);

    assert.match(
        viewSource,
        /\.filter \{ \$0 >= viewModel\.minimumSpeedLadderTarget \}/
    );
    assert.match(viewSource, /目标速度不会低于手动起始速度，阶梯只递增/);
});

check("the video surface keeps custom transport and supports direct tap", () => {
    assert.doesNotMatch(viewSource, /VideoPlayer\(player:/);
    assert.match(viewSource, /VideoSurface\(player:/);
    assert.match(viewSource, /showsPlaybackControls = false/);
    assert.match(viewSource, /TapGesture\(\)\.onEnded \{[\s\S]*?viewModel\.togglePlayback\(\)/);
});

check("the video page keeps the content full-width with GP-style bottom tools", () => {
    assert.match(viewSource, /\.safeAreaInset\(edge: \.bottom, spacing: 0\) \{[\s\S]*?controlDeck/);
    assert.match(viewSource, /private enum VideoControlPanel[\s\S]*?case loop[\s\S]*?case metronome[\s\S]*?case sound/);
    assert.match(viewSource, /\.overlay\(alignment: \.bottomTrailing\) \{[\s\S]*?if let panel = activePanel/);
    assert.doesNotMatch(viewSource, /sideControls\s*\.frame\(width: 360\)/);
});

check("video settings stay open while transport remains interactive", () => {
    assert.doesNotMatch(viewSource, /\.popover\(isPresented: panelBinding\(for: panel\)/);
    assert.match(
        viewSource,
        /videoArea[\s\S]*?simultaneousGesture\([\s\S]*?activePanel = nil/,
        "tapping the video display must dismiss settings"
    );
    assert.match(viewSource, /if let panel = activePanel \{[\s\S]*?panelContent\(panel\)/);
});

check("the video toolbar does not duplicate bottom tool actions", () => {
    assert.doesNotMatch(viewSource, /Label\("更多", systemImage: "ellipsis"\)/);
    assert.match(viewSource, /Label\("选择文件", systemImage: "folder"\)/);
});

for (const result of checks) {
    console.log(`${result.passed ? "PASS" : "FAIL"}: ${result.name}`);
    if (!result.passed) console.log(`  ${result.message}`);
}

if (checks.some((result) => !result.passed)) process.exit(1);

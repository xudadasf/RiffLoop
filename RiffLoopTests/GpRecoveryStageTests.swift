import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class GpRecoveryStageTests: XCTestCase {
    func testRecoveryPreservesLastStageDisplayWhenBothPlansAreEnabled() async throws {
        for transport in [TempoStageTransport.gp, .standalone] {
            try await withModel { model, _, _, metadata in
                self.prepareStages(model)
                model.pause()
                model.setStandaloneStages(.init(stages: [.init(bpm: 80, unit: .seconds, length: 30)]))
                model.setStandaloneStagesEnabled(true)
                model.selectStage(0, for: transport)
                XCTAssertEqual(model.deckStageTransport, transport)

                let loadID = try await self.beginRecovery(model)
                self.finishLoad(model, id: loadID, metadata: metadata)

                XCTAssertTrue(model.gpStagesEnabled)
                XCTAssertTrue(model.standaloneStagesEnabled)
                XCTAssertEqual(model.deckStageTransport, transport)
                XCTAssertFalse(model.isPlaying)
                XCTAssertFalse(model.isStandaloneMetronomePlaying)
            }
        }
    }

    func testAutomaticRecoveryKeepsPausedStageProgressDirectionAndTempoAnchor() async throws {
        try await withModel { model, _, _, metadata in
            self.prepareStages(model)
            let range = model.loopRange
            let plan = model.gpStages
            let readout = model.stageReadout(for: .gp)
            let loops = model.completedLoops
            let loadID = try await self.beginRecovery(model)
            self.finishLoad(model, id: loadID, metadata: metadata)

            XCTAssertTrue(model.gpStagesEnabled)
            XCTAssertTrue(model.rangeLoopingEnabled)
            XCTAssertEqual(model.loopRange, range)
            XCTAssertEqual(model.gpStages, plan)
            XCTAssertEqual(model.stageReadout(for: .gp), readout)
            XCTAssertEqual(model.gpProgress.rounds, 1)
            XCTAssertEqual(model.completedLoops, loops)
            XCTAssertEqual(model.currentBpm, 90, accuracy: 0.001)
            XCTAssertFalse(model.isPlaying)
            XCTAssertFalse(model.gpProgress.clockRunning)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(model.stageReadout(for: .gp), readout)
            self.start(model)
            model.receive(.rangeLoopCompleted)
            model.receive(.rangeLoopCompleted)
            XCTAssertEqual(model.gpProgress.index, 0, "Recovery must retain the returning direction of a bounce plan")
        }
    }

    func testTimedStageFreezesDuringAutomaticRecovery() async throws {
        try await withModel { model, _, _, metadata in
            self.prepareStages(model)
            model.pause()
            model.setGpStages(.init(stages: [.init(bpm: 80, unit: .seconds, length: 20),
                                             .init(bpm: 90, unit: .seconds, length: 20)]))
            model.selectStage(1, for: .gp)
            self.start(model)
            try await Task.sleep(for: .milliseconds(1100))
            model.recoverWebContent()
            let frozen = model.gpProgress
            try await self.waitForRecoveryLoad(model)
            self.finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata)
            let readout = frozen.readout(in: model.gpStages, now: ProcessInfo.processInfo.systemUptime)
            XCTAssertTrue(model.gpStagesEnabled)
            XCTAssertEqual(model.stageReadout(for: .gp), readout)
            XCTAssertLessThan(readout.remaining, 20)
            XCTAssertFalse(model.gpProgress.clockRunning)
        }
    }

    func testAutomaticRecoveryKeepsLegacySpeedAndItsOriginalBase() async throws {
        try await withModel { model, _, _, metadata in
            self.prepareStages(model)
            model.pause()
            model.setGpStagesEnabled(false)
            model.setPlaybackSpeed(0.8)
            model.setSpeedLadderTarget(1.2)
            model.setSpeedLadderStep(0.1)
            model.setLoopsPerSpeedStep(2)
            model.setSpeedLadderEnabled(true)
            self.start(model)
            for _ in 0..<3 { model.receive(.rangeLoopCompleted) }
            XCTAssertEqual(model.playbackSpeed, 0.9, accuracy: 0.001)
            let loadID = try await self.beginRecovery(model)
            self.finishLoad(model, id: loadID, metadata: metadata)
            XCTAssertTrue(model.speedLadderEnabled)
            XCTAssertTrue(model.rangeLoopingEnabled)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertEqual(model.playbackSpeed, 0.9, accuracy: 0.001)
            XCTAssertEqual(model.completedLoops, 3)
            XCTAssertFalse(model.isPlaying)
            model.clearLoop()
            XCTAssertEqual(model.playbackSpeed, 0.8, accuracy: 0.001, "Disabling after recovery must restore the original ladder speed")
        }
    }

    func testOrdinaryOpenAndLeaveCancelPendingRecovery() async throws {
        for action in ["same-file", "other-file", "leave"] {
            try await withModel { model, data, name, metadata in
                self.prepareStages(model)
                let recoveryID = try await self.beginRecovery(model)
                if action == "leave" {
                    model.leaveMode()
                    model.receiveFromWeb(.scoreLoaded(metadata), scoreLoadID: recoveryID)
                    XCTAssertNil(model.score)
                }
                model.loadScore(data: data, fileName: action == "other-file" ? "other-\(name)" : name)
                let newID = try XCTUnwrap(model.scoreLoadID)
                model.receiveFromWeb(.scoreLoaded(metadata), scoreLoadID: recoveryID)
                XCTAssertNil(model.score)
                self.finishLoad(model, id: newID, metadata: metadata)
                XCTAssertFalse(model.gpStagesEnabled, action)
                XCTAssertFalse(model.speedLadderEnabled, action)
                XCTAssertFalse(model.rangeLoopingEnabled, action)
                XCTAssertNil(model.loopRange, action)
                XCTAssertFalse(model.isPlaying, action)
            }
        }
    }

    func testExplicitLoopChangesWhileReadingOrLoadingCannotBeUndoneByRecovery() async throws {
        for afterRead in [false, true] {
            for action in ["stages", "range", "clear"] {
                try await withModel { model, _, _, metadata in
                    self.prepareStages(model)
                    model.recoverWebContent()
                    if afterRead { try await self.waitForRecoveryLoad(model) }
                    switch action {
                    case "stages": model.setGpStagesEnabled(false)
                    case "range": model.setRangeLoopingEnabled(false)
                    default: model.clearLoop()
                    }
                    try await self.waitForRecoveryLoad(model)
                    self.finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata)
                    XCTAssertFalse(model.gpStagesEnabled, "\(action), afterRead=\(afterRead)")
                    XCTAssertFalse(model.rangeLoopingEnabled)
                    XCTAssertNil(model.loopRange)
                    XCTAssertFalse(model.isPlaying)
                }
            }
        }
    }

    func testOpenDuringRecoveryReadCancelsTheOldTransaction() async throws {
        for leave in [false, true] {
            try await withModel { model, data, name, metadata in
                self.prepareStages(model)
                model.recoverWebContent()
                if leave { model.leaveMode() }
                model.loadScore(data: data, fileName: name)
                let newID = try XCTUnwrap(model.scoreLoadID)
                self.finishLoad(model, id: newID, metadata: metadata)
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(model.scoreLoadID, newID)
                XCTAssertFalse(model.gpStagesEnabled)
                XCTAssertFalse(model.rangeLoopingEnabled)
                XCTAssertNil(model.loopRange)
                XCTAssertFalse(model.isPlaying)
            }
        }
    }

    func testReplacedFileWithIdenticalMetadataCannotReceiveOldRange() async throws {
        try await withModel { model, data, name, metadata in
            self.prepareStages(model)
            var replacement = data
            replacement.append(0)
            let file = RiffLoopDocumentStore().folderURL(for: .guitarPro).appendingPathComponent(name)
            try replacement.write(to: file)
            let newID = try await self.beginRecovery(model)
            self.finishLoad(model, id: newID, metadata: metadata)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertFalse(model.rangeLoopingEnabled)
            XCTAssertNil(model.loopRange)
        }
    }

    func testOldAndRepeatedMetadataCannotReplayRecoverySnapshot() async throws {
        try await withModel { model, _, _, metadata in
            self.prepareStages(model)
            let oldID = try XCTUnwrap(model.scoreLoadID)
            let newID = try await self.beginRecovery(model)
            model.receiveFromWeb(.scoreLoaded(metadata), scoreLoadID: oldID)
            XCTAssertNil(model.score)
            XCTAssertFalse(model.gpStagesEnabled)
            self.finishLoad(model, id: newID, metadata: metadata)
            XCTAssertTrue(model.gpStagesEnabled)
            model.setGpStagesEnabled(false)
            model.receiveFromWeb(.scoreLoaded(metadata), scoreLoadID: newID)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertFalse(model.isPlaying)
        }
    }

    func testRecoveryUsesRangeTempoForLowBpmStagesInTempoChangingScores() async throws {
        try await withModel { model, data, name, _ in
            let metadata = GpScoreMetadata(title: "Tempo changes", artist: "", bars: 4, hasBackingTrack: false,
                tracks: [], beatsPerMeasure: 4, beatUnit: 4, initialBpm: 300, hasTempoChanges: true)
            model.loadScore(data: data, fileName: name)
            self.finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata, tempo: 120)
            model.receive(.pointerDown(.init(index: 1, startTick: 3840, endTick: 4800)))
            model.receive(.pointerUp)
            model.receive(.positionChanged(.init(currentTime: 2000, totalTime: 8000, currentTick: 3840,
                endTick: 15360, originalTempo: 120)))
            let plan = TempoStagePlan(stages: [.init(bpm: 40, unit: .loops, length: 2),
                                              .init(bpm: 30, unit: .loops, length: 3)])
            model.setGpStages(plan)
            model.setGpStagesEnabled(true)
            model.selectStage(1, for: .gp)
            self.start(model)
            model.receive(.rangeLoopCompleted)
            let newID = try await self.beginRecovery(model)
            self.finishLoad(model, id: newID, metadata: metadata, tempo: 120)
            XCTAssertTrue(model.gpStagesEnabled)
            XCTAssertEqual(model.gpStages, plan)
            XCTAssertEqual(model.gpProgress.index, 1)
            XCTAssertEqual(model.gpProgress.rounds, 1)
            XCTAssertEqual(model.currentBpm, 30, accuracy: 0.001)

            model.loadScore(data: data, fileName: name)
            self.finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata, tempo: 120)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertEqual(model.gpStages.stages[1].bpm, 38, "Ordinary reopening keeps the existing initial-tempo validation")
        }
    }

    func testStageSelectionAndLegacyEditsAreRejectedDuringBothRecoveryPhases() async throws {
        for afterRead in [false, true] {
            try await withModel { model, _, _, metadata in
                self.prepareStages(model)
                model.pause()
                model.recoverWebContent()
                if afterRead { try await self.waitForRecoveryLoad(model) }
                XCTAssertTrue(model.isRecoveringPractice)
                XCTAssertFalse(model.canSelectStage(for: .gp))
                let index = model.gpProgress.index
                model.selectStage(2, for: .gp)
                XCTAssertEqual(model.gpProgress.index, index)
                try await self.waitForRecoveryLoad(model)
                self.finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata)
                XCTAssertEqual(model.gpProgress.index, 1)
                XCTAssertFalse(model.isRecoveringPractice)
            }
            try await withModel { model, _, _, metadata in
                self.prepareStages(model)
                model.pause()
                model.setGpStagesEnabled(false)
                model.setPlaybackSpeed(0.8)
                model.setSpeedLadderTarget(1.2)
                model.setSpeedLadderStep(0.1)
                model.setLoopsPerSpeedStep(2)
                model.setSpeedLadderEnabled(true)
                self.start(model)
                for _ in 0..<3 { model.receive(.rangeLoopCompleted) }
                model.recoverWebContent()
                if afterRead { try await self.waitForRecoveryLoad(model) }
                let before = [model.baseBpm, model.playbackSpeed, model.speedLadderTarget,
                              model.speedLadderStep, Double(model.loopsPerSpeedStep), Double(model.completedLoops)]
                model.setPlaybackSpeed(0.7)
                model.setPracticeStartBpm(93)
                model.setBaseBpm(100)
                model.resetBaseBpm()
                model.setSpeedLadderTarget(1.9)
                model.setSpeedLadderStep(0.2)
                model.setLoopsPerSpeedStep(8)
                XCTAssertEqual([model.baseBpm, model.playbackSpeed, model.speedLadderTarget,
                                model.speedLadderStep, Double(model.loopsPerSpeedStep), Double(model.completedLoops)], before)
                try await self.waitForRecoveryLoad(model)
                self.finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata)
                XCTAssertTrue(model.rangeLoopingEnabled)
                XCTAssertTrue(model.speedLadderEnabled)
                XCTAssertEqual(model.playbackSpeed, 0.9, accuracy: 0.001)
                XCTAssertEqual(model.completedLoops, 3)
            }
        }
    }

    func testIncompatibleMetadataAndInvalidRangeRejectRecovery() async throws {
        for invalidRange in [false, true] {
            try await withModel { model, _, _, metadata in
                self.prepareStages(model)
                if invalidRange {
                    model.receive(.pointerDown(.init(index: 1, startTick: 3840, endTick: 20000)))
                    model.receive(.pointerUp)
                }
                let loadID = try await self.beginRecovery(model)
                let loaded = invalidRange ? metadata : GpScoreMetadata(title: "Changed", artist: "", bars: 1,
                    hasBackingTrack: false, tracks: [], beatsPerMeasure: 4, beatUnit: 4, initialBpm: 120)
                self.finishLoad(model, id: loadID, metadata: loaded)
                XCTAssertFalse(model.gpStagesEnabled)
                XCTAssertFalse(model.rangeLoopingEnabled)
                XCTAssertNil(model.loopRange)
                XCTAssertFalse(model.isPlaying)
            }
        }
    }

    func testRecoveryStaysLockedBetweenMetadataAndPlayerReadiness() async throws {
        for legacy in [false, true] {
            try await withModel { model, _, _, metadata in
                self.prepareStages(model)
                model.pause()
                if legacy {
                    model.setGpStagesEnabled(false)
                    model.setPlaybackSpeed(0.8)
                    model.setSpeedLadderTarget(1.2)
                    model.setSpeedLadderStep(0.1)
                    model.setLoopsPerSpeedStep(2)
                    model.setSpeedLadderEnabled(true)
                }
                let newID = try await self.beginRecovery(model)
                // Metadata consumes the recovery snapshot before the MIDI player
                // is ready to apply the saved midpoint (4320), not the A point (3840).
                model.receiveFromWeb(.scoreLoaded(metadata), scoreLoadID: newID)
                XCTAssertFalse(model.playerReady)
                XCTAssertTrue(model.isRecoveringPractice, "The loop settings must stay disabled until playerReady")
                XCTAssertFalse(model.canSelectStage(for: .gp))
                let index = model.gpProgress.index
                model.selectStage(2, for: .gp)
                XCTAssertEqual(model.gpProgress.index, index, "A new stage must not be selected before the pending resume seek")
                let before = [model.baseBpm, model.playbackSpeed, model.speedLadderTarget,
                              model.speedLadderStep, Double(model.loopsPerSpeedStep), Double(model.completedLoops)]
                model.setPlaybackSpeed(0.7)
                model.setPracticeStartBpm(93)
                model.setBaseBpm(100)
                model.resetBaseBpm()
                model.setSpeedLadderTarget(1.9)
                model.setSpeedLadderStep(0.2)
                model.setLoopsPerSpeedStep(8)
                XCTAssertEqual([model.baseBpm, model.playbackSpeed, model.speedLadderTarget,
                                model.speedLadderStep, Double(model.loopsPerSpeedStep), Double(model.completedLoops)], before)

                model.receiveFromWeb(.playerReady, scoreLoadID: newID)
                XCTAssertTrue(model.playerReady)
                XCTAssertFalse(model.isRecoveringPractice)
                XCTAssertFalse(model.isPlaying)
                XCTAssertEqual(model.gpProgress.index, index)
                if legacy {
                    model.setPlaybackSpeed(0.9)
                    XCTAssertEqual(model.playbackSpeed, 0.9, accuracy: 0.001)
                } else {
                    XCTAssertTrue(model.canSelectStage(for: .gp))
                    model.selectStage(2, for: .gp)
                    XCTAssertEqual(model.gpProgress.index, 2)
                    XCTAssertFalse(model.gpProgress.clockRunning)
                }
            }
        }
    }

    private func prepareStages(_ model: GpWebViewModel) {
        model.receive(.pointerDown(.init(index: 1, startTick: 3840, endTick: 7680)))
        model.receive(.pointerUp)
        model.setGpStages(.init(stages: [.init(bpm: 70, unit: .loops, length: 2),
                                        .init(bpm: 90, unit: .loops, length: 3),
                                        .init(bpm: 110, unit: .loops, length: 1)], order: .bounce))
        model.setGpStagesEnabled(true)
        model.selectStage(1, for: .gp)
        model.receive(.positionChanged(.init(currentTime: 2000, totalTime: 8000, currentTick: 3840,
            endTick: 15360, originalTempo: 180)))
        model.receive(.positionChanged(.init(currentTime: 2250, totalTime: 8000, currentTick: 4320,
            endTick: 15360, originalTempo: 180)))
        start(model)
        for _ in 0..<5 { model.receive(.rangeLoopCompleted) }
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertEqual(model.gpProgress.rounds, 1)
    }

    private func start(_ model: GpWebViewModel) {
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: true)))
    }

    private func beginRecovery(_ model: GpWebViewModel) async throws -> String {
        model.recoverWebContent()
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.gpProgress.clockRunning)
        try await waitForRecoveryLoad(model)
        return try XCTUnwrap(model.scoreLoadID)
    }

    private func waitForRecoveryLoad(_ model: GpWebViewModel) async throws {
        for _ in 0..<200 {
            if model.scoreLoadID != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Recovery did not finish reading its temporary fixture: \(model.errorMessage ?? "no error")")
        throw NSError(domain: "GpRecoveryStageTests", code: 1)
    }

    private func finishLoad(_ model: GpWebViewModel, id: String, metadata: GpScoreMetadata, tempo: Double = 180) {
        model.receiveFromWeb(.scoreLoaded(metadata), scoreLoadID: id)
        model.receiveFromWeb(.playerReady, scoreLoadID: id)
        model.receiveFromWeb(.positionChanged(.init(currentTime: 2250, totalTime: 8000, currentTick: 4320,
            endTick: 15360, isSeek: true, originalTempo: tempo)), scoreLoadID: id)
    }

    private func withModel(_ body: (GpWebViewModel, Data, String, GpScoreMetadata) async throws -> Void) async throws {
        let suite = "GpRecoveryStageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = GpWebViewModel(settingsStore: FilePracticeSettingsStore(defaults: defaults))
        let webView = WKWebView()
        model.attach(webView: webView)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: source)
        let folder = RiffLoopDocumentStore().folderURL(for: .guitarPro)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "recovery-stage-\(UUID().uuidString).gp"
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        defer {
            model.leaveMode()
            webView.stopLoading()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        // These unit tests drive metadata/position events directly; the companion
        // real WebKit playback test covers rendering and actual range playback.
        let metadata = GpScoreMetadata(title: "Recovery", artist: "", bars: 4, hasBackingTrack: false,
            tracks: [], beatsPerMeasure: 4, beatUnit: 4, initialBpm: 120, hasTempoChanges: true)
        model.loadScore(data: data, fileName: name)
        finishLoad(model, id: try XCTUnwrap(model.scoreLoadID), metadata: metadata)
        try await body(model, data, name, metadata)
    }
}

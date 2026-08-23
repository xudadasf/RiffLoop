import XCTest
@testable import RiffLoop

final class GpBridgeEventTests: XCTestCase {
    func testDecodesScoreMetadataSentByTheOfflineRenderer() throws {
        let event = try GpBridgeEvent.decode(messageBody: [
            "event": "scoreLoaded",
            "payload": [
                "title": "此生不换",
                "artist": "青鸟飞鱼",
                "bars": 34,
                "hasBackingTrack": true,
                "initialBpm": 120,
                "hasTempoChanges": true,
                "tracks": [
                    [
                        "index": 0,
                        "name": "Electric Guitar",
                        "shortName": "E.Gt",
                        "volume": 15,
                        "isMute": false,
                        "isSolo": true,
                    ],
                ],
            ],
        ])

        XCTAssertEqual(
            event,
            .scoreLoaded(
                GpScoreMetadata(
                    title: "此生不换",
                    artist: "青鸟飞鱼",
                    bars: 34,
                    hasBackingTrack: true,
                    tracks: [
                        GpTrackMetadata(
                            index: 0,
                            name: "Electric Guitar",
                            shortName: "E.Gt",
                            volume: 15,
                            isMute: false,
                            isSolo: true
                        ),
                    ],
                    initialBpm: 120,
                    hasTempoChanges: true
                )
            )
        )
    }

    func testRejectsUnknownMessagesInsteadOfSilentlyChangingState() {
        XCTAssertThrowsError(
            try GpBridgeEvent.decode(messageBody: ["event": "futureEvent"])
        )
    }

    func testDecodesPreciseBeatTickForTapSeeking() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "barHit",
                "payload": [
                    "index": 8,
                    "startTick": 7_680,
                    "endTick": 8_640,
                    "seekTick": 8_160,
                    "seekEndTick": 8_400,
                ],
            ]),
            .barHit(
                GpBarHit(
                    index: 8,
                    startTick: 7_680,
                    endTick: 8_640,
                    seekTick: 8_160,
                    seekEndTick: 8_400
                )
            )
        )
    }

    func testDecodesPointerHitsForLongPressDragSelection() throws {
        let hit = GpBarHit(
            index: 8,
            startTick: 7_680,
            endTick: 8_640,
            seekTick: 8_160,
            seekEndTick: 8_400
        )
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "pointerDown",
                "payload": [
                    "index": 8,
                    "startTick": 7_680,
                    "endTick": 8_640,
                    "seekTick": 8_160,
                    "seekEndTick": 8_400,
                ],
            ]),
            .pointerDown(hit)
        )
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "pointerMove",
                "payload": [
                    "index": 8,
                    "startTick": 7_680,
                    "endTick": 8_640,
                    "seekTick": 8_160,
                    "seekEndTick": 8_400,
                ],
            ]),
            .pointerMove(hit)
        )
    }

    func testDecodesPointerCompletionEventsWithoutPayload() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: ["event": "pointerUp"]),
            .pointerUp
        )
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: ["event": "pointerCancel"]),
            .pointerCancel
        )
    }

    func testDecodesTemporaryBackingAudioDiagnostic() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "diagnostic",
                "payload": ["message": "{\"stage\":\"media-playing\"}"],
            ]),
            .diagnostic("{\"stage\":\"media-playing\"}")
        )
    }

    func testDecodesEmbeddedBackingAudioForTheNativePlayer() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "backingAudioLoaded",
                "payload": [
                    "mimeType": "audio/mpeg",
                    "data": Data([0x49, 0x44, 0x33]).base64EncodedString(),
                    "syncPoints": [
                        ["synthTime": 0, "syncTime": -2_798.639455782313],
                        ["synthTime": 140_307, "syncTime": 137_508.3605442177],
                    ],
                ],
            ]),
            .backingAudioLoaded(
                GpBackingAudio(
                    mimeType: "audio/mpeg",
                    data: Data([0x49, 0x44, 0x33]),
                    syncPoints: [
                        GpBackingSyncPoint(synthTime: 0, syncTime: -2_798.639455782313),
                        GpBackingSyncPoint(synthTime: 140_307, syncTime: 137_508.3605442177),
                    ]
                )
            )
        )
    }

    func testDecodesSeekFlagUsedToRejectFalseLoopCompletions() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "positionChanged",
                "payload": [
                    "currentTime": 1_000,
                    "totalTime": 10_000,
                    "currentTick": 960,
                    "endTick": 9_600,
                    "isSeek": true,
                    "originalTempo": 120,
                    "modifiedTempo": 90,
                ],
            ]),
            .positionChanged(
                GpPlaybackPosition(
                    currentTime: 1_000,
                    totalTime: 10_000,
                    currentTick: 960,
                    endTick: 9_600,
                    isSeek: true,
                    originalTempo: 120,
                    modifiedTempo: 90
                )
            )
        )
    }

    func testDecodesExplicitRangeLoopCompletion() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: ["event": "rangeLoopCompleted"]),
            .rangeLoopCompleted
        )
    }

    @MainActor
    func testCountsOnlyExplicitRangeLoopCompletions() {
        let viewModel = GpWebViewModel()
        let rangeHit = GpBarHit(
            index: 0,
            startTick: 0,
            endTick: 960,
            seekTick: 0,
            seekEndTick: 960
        )
        viewModel.receive(.pointerDown(rangeHit))
        viewModel.receive(.pointerUp)

        viewModel.receive(.positionChanged(GpPlaybackPosition(
            currentTime: 900,
            totalTime: 1_000,
            currentTick: 900,
            endTick: 960,
            isSeek: false
        )))
        viewModel.receive(.positionChanged(GpPlaybackPosition(
            currentTime: 10,
            totalTime: 1_000,
            currentTick: 10,
            endTick: 960,
            isSeek: false
        )))

        XCTAssertEqual(viewModel.completedLoops, 0)
        viewModel.receive(.rangeLoopCompleted)
        XCTAssertEqual(viewModel.completedLoops, 1)
    }

    @MainActor
    func testLadderRoundAdvancesOncePerPhysicalLoopAndResetsAfterSpeedIncrease() {
        let viewModel = GpWebViewModel()
        let rangeHit = GpBarHit(
            index: 0,
            startTick: 0,
            endTick: 960,
            seekTick: 0,
            seekEndTick: 960
        )
        viewModel.receive(.pointerDown(rangeHit))
        viewModel.receive(.pointerUp)
        viewModel.setPlaybackSpeed(0.75)
        viewModel.setSpeedLadderEnabled(true)

        XCTAssertEqual(viewModel.currentSpeedLadderRound, 1)
        XCTAssertEqual(viewModel.playbackSpeed, 0.75)

        viewModel.receive(.rangeLoopCompleted)
        XCTAssertEqual(viewModel.currentSpeedLadderRound, 2)
        XCTAssertEqual(viewModel.playbackSpeed, 0.75)

        viewModel.receive(.rangeLoopCompleted)
        XCTAssertEqual(viewModel.currentSpeedLadderRound, 3)
        XCTAssertEqual(viewModel.playbackSpeed, 0.75)

        viewModel.receive(.rangeLoopCompleted)
        XCTAssertEqual(viewModel.currentSpeedLadderRound, 1)
        XCTAssertEqual(viewModel.playbackSpeed, 0.8, accuracy: 1e-12)
    }

    @MainActor
    func testCurrentBpmScalesTheOriginalTempoMapFromTheUsersBase() {
        let viewModel = GpWebViewModel()
        viewModel.receive(.scoreLoaded(GpScoreMetadata(
            title: "Variable tempo",
            artist: "",
            bars: 2,
            hasBackingTrack: false,
            tracks: [],
            initialBpm: 120,
            hasTempoChanges: true
        )))
        viewModel.setBaseBpm(150)
        viewModel.setPlaybackSpeed(0.8)
        viewModel.receive(.positionChanged(GpPlaybackPosition(
            currentTime: 1_000,
            totalTime: 2_000,
            currentTick: 960,
            endTick: 1_920,
            isSeek: false,
            originalTempo: 90,
            modifiedTempo: 90
        )))

        XCTAssertEqual(viewModel.baseBpm, 150)
        XCTAssertEqual(viewModel.playbackSpeed, 0.8)
        XCTAssertEqual(viewModel.currentBpm, 90, accuracy: 1e-12)
    }

    @MainActor
    func testLeavingForegroundImmediatelyClearsPlayingState() {
        let viewModel = GpWebViewModel()
        viewModel.receive(.playerStateChanged(GpPlaybackState(state: 1, stopped: false)))

        viewModel.setSceneActive(false)

        XCTAssertFalse(viewModel.isPlaying)
    }
}

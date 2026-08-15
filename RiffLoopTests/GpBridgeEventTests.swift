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
                    ]
                )
            )
        )
    }

    func testRejectsUnknownMessagesInsteadOfSilentlyChangingState() {
        XCTAssertThrowsError(
            try GpBridgeEvent.decode(messageBody: ["event": "futureEvent"])
        )
    }

    func testDecodesPointerHitsForLongPressSelection() throws {
        XCTAssertEqual(
            try GpBridgeEvent.decode(messageBody: [
                "event": "pointerMove",
                "payload": ["index": 8, "startTick": 7_680, "endTick": 8_640],
            ]),
            .pointerMove(GpBarHit(index: 8, startTick: 7_680, endTick: 8_640))
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
                ],
            ]),
            .positionChanged(
                GpPlaybackPosition(
                    currentTime: 1_000,
                    totalTime: 10_000,
                    currentTick: 960,
                    endTick: 9_600,
                    isSeek: true
                )
            )
        )
    }

    @MainActor
    func testLeavingForegroundImmediatelyClearsPlayingState() {
        let viewModel = GpWebViewModel()
        viewModel.receive(.playerStateChanged(GpPlaybackState(state: 1, stopped: false)))

        viewModel.setSceneActive(false)

        XCTAssertFalse(viewModel.isPlaying)
    }
}

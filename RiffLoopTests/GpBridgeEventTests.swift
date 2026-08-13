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
}

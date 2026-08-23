import XCTest
@testable import RiffLoop

final class GpBackingSyncTests: XCTestCase {
    private let thisLifeUnchangedSyncPoints = [
        GpBackingSyncPoint(synthTime: 0, syncTime: -2_798.639455782313),
        GpBackingSyncPoint(synthTime: 140_307, syncTime: 137_508.3605442177),
    ]

    func testMapsScorePositionToEmbeddedBackingPosition() {
        XCTAssertEqual(
            gpBackingTime(
                forScoreTime: 139_526.6394557823,
                syncPoints: thisLifeUnchangedSyncPoints
            )!,
            136_728,
            accuracy: 0.001
        )
    }

    func testPreservesBackingPrerollBeforeItsFirstAudibleSample() {
        XCTAssertEqual(
            gpBackingTime(forScoreTime: 0, syncPoints: thisLifeUnchangedSyncPoints)!,
            -2_798.639455782313,
            accuracy: 0.001
        )
        XCTAssertEqual(
            gpBackingTime(
                forScoreTime: 2_798.639455782313,
                syncPoints: thisLifeUnchangedSyncPoints
            )!,
            0,
            accuracy: 0.001
        )
    }

    func testFallsBackToTheScoreTimelineWhenTheFileHasNoSyncPoints() {
        XCTAssertEqual(
            gpBackingTime(forScoreTime: 16_590, syncPoints: []),
            16_590
        )
    }

    func testInterpolatesBetweenNonUniformSyncPoints() {
        XCTAssertEqual(
            gpBackingTime(
                forScoreTime: 500,
                syncPoints: [
                    GpBackingSyncPoint(synthTime: 0, syncTime: 1_000),
                    GpBackingSyncPoint(synthTime: 1_000, syncTime: 2_500),
                ]
            )!,
            1_750,
            accuracy: 0.001
        )
    }
}

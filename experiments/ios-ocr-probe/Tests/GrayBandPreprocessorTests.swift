import Foundation
import XCTest
@testable import RiffLoopOCRProbe

private struct ImageReference: Decodable {
    struct Case: Decodable {
        let source_width: Int
        let source_height: Int
        let source_sha256: String
        let post_bounds_shape: [Int]
        let tensor_shape: [Int]
        let tensor_sha256: String
        let effective_width: Int
        let resized_gray_base64: String
        let output_shape: [Int]
        let argmax: [Int]
        let argmax_scores: [Float]
    }
    let model_sha256: String
    let rapidocr_version: String
    let cases: [Case]
}

final class GrayBandPreprocessorTests: XCTestCase {
    func testInvalidOrExcessiveInputIsRejected() {
        XCTAssertThrowsError(try GrayBandPreprocessor.prepare([UInt8](repeating: 255, count: 200),
                                                               width: 200, height: 1))
        XCTAssertThrowsError(try GrayBandPreprocessor.prepare([UInt8](repeating: 255, count: 40 * 200 - 1),
                                                               width: 200, height: 40))
    }

    func testSyntheticBandsAgainstDesktopPreprocessingAndModel() throws {
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "image_reference_expected", withExtension: "json"))
        let reference = try JSONDecoder().decode(ImageReference.self, from: Data(contentsOf: fixture))
        XCTAssertEqual(reference.model_sha256, ORTProbe.expectedModelSHA256)
        XCTAssertEqual(reference.rapidocr_version, "3.10.0")
        XCTAssertEqual(reference.cases.map(\.source_width), [200, 560, 200, 531])
        let model = try XCTUnwrap(bundle.url(forResource: "PP-OCRv6_rec_small", withExtension: "onnx"))
        let engine = try ORTProbe(modelURL: model)

        for expected in reference.cases {
            let source = try XCTUnwrap(SyntheticTensor.generatedBand(width: expected.source_width,
                                                                     height: expected.source_height))
            XCTAssertEqual(SyntheticTensor.sha256(Data(source)), expected.source_sha256)
            let prepared = try GrayBandPreprocessor.prepare(source, width: expected.source_width,
                                                            height: expected.source_height)
            XCTAssertEqual([prepared.boundedHeight, prepared.boundedWidth, 3], expected.post_bounds_shape)
            XCTAssertEqual([1, 3, 48, prepared.width], expected.tensor_shape)
            XCTAssertEqual(prepared.effectiveWidth, expected.effective_width)
            let expectedPixels = try XCTUnwrap(Data(base64Encoded: expected.resized_gray_base64))
            XCTAssertEqual(prepared.resizedGray.count, expectedPixels.count)
            let differences = zip(prepared.resizedGray, expectedPixels).map { abs(Int($0) - Int($1)) }
            XCTAssertEqual(differences.filter { $0 != 0 }.count, 0, "Frozen grayscale pixels must match exactly")
            XCTAssertEqual(SyntheticTensor.sha256(SyntheticTensor.data(prepared.tensor)), expected.tensor_sha256)
            for channel in 0..<3 {
                for y in 0..<48 {
                    let padding = (channel * 48 + y) * prepared.width + prepared.effectiveWidth
                    XCTAssertTrue(prepared.tensor[padding..<(padding + prepared.width - prepared.effectiveWidth)]
                        .allSatisfy { $0 == 0 })
                }
            }
            let observed = try engine.run(prepared.tensor, width: prepared.width, sampleTimes: [], sampleClasses: [])
            XCTAssertEqual(observed.outputShape, expected.output_shape)
            XCTAssertEqual(observed.argmax, expected.argmax, "Every model time step must agree for the frozen samples")
            XCTAssertEqual(observed.argmaxScores.count, expected.argmax_scores.count)
            let maxScoreDifference = zip(observed.argmaxScores, expected.argmax_scores)
                .map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(maxScoreDifference, 0.001)
            print("GRAY_BAND_PARITY width=\(expected.source_width) pixelDifferences=\(differences.filter { $0 != 0 }.count) maxPixelDifference=\(differences.max() ?? 0) maxScoreDifference=\(maxScoreDifference)")
        }
    }
}

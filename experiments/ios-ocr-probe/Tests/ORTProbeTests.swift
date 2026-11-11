import Foundation
import XCTest
@testable import RiffLoopOCRProbe

private struct CPUReference: Decodable {
    struct Case: Decodable {
        struct Run: Decodable {
            let `class`: Int
            let start: Int
            let end: Int
            let character: String
        }
        let name: String
        let input_sha256_little_endian: String
        let output_shape: [Int]
        let output_dtype: String
        let argmax: [Int]
        let argmax_scores: [Float]
        let ctc_text: String
        let ctc_runs: [Run]
        let sample_times: [Int]
        let sample_classes: [Int]
        let sample_values: [[Float]]
    }
    let model_sha256: String
    let runtime: String
    let provider: String
    let input_shape: [Int]
    let cases: [Case]
}

final class ORTProbeTests: XCTestCase {
    func testCTCRepeatRequiresBlankAndUnknownIsNotGuessed() {
        let labels = [1: "1"]
        XCTAssertEqual(PartialCTC.decode([1, 1], labels: labels).text, "1")
        XCTAssertEqual(PartialCTC.decode([1, 0, 1], labels: labels).text, "11")
        let unknown = PartialCTC.decode([1, 0, 7], labels: labels)
        XCTAssertNil(unknown.text)
        XCTAssertEqual(unknown.unknownClasses, [7])
        XCTAssertEqual(unknown.runs.map(\.classID), [1, 7])
        XCTAssertNil(unknown.runs.last?.character)
        let runs = PartialCTC.decode([0, 1, 1, 0, 1, 7, 7, 0], labels: labels).runs
        XCTAssertEqual(runs.map(\.start), [1, 4, 5])
        XCTAssertEqual(runs.map(\.end), [2, 4, 6])
        XCTAssertTrue(PartialCTC.decode([0, 0], labels: labels).runs.isEmpty)
    }

    func testSyntheticInputsMatchCPUByteHashes() {
        XCTAssertEqual(SyntheticTensor.sha256(SyntheticTensor.data(SyntheticTensor.pattern())), SyntheticTensor.patternSHA256)
        XCTAssertEqual(SyntheticTensor.sha256(SyntheticTensor.data(SyntheticTensor.glyphsInput())), SyntheticTensor.glyphSHA256)
    }

    func testModelExecutesAndMatchesCPUReference() throws {
        let bundle = Bundle(for: Self.self)
        let model = try XCTUnwrap(bundle.url(forResource: "PP-OCRv6_rec_small", withExtension: "onnx"),
                                  "Supply the fixed-hash model via ORT_PROBE_MODEL_PATH before XcodeGen")
        let referenceURL = try XCTUnwrap(bundle.url(forResource: "cpu_reference_expected", withExtension: "json"))
        let reference = try JSONDecoder().decode(CPUReference.self, from: Data(contentsOf: referenceURL))
        XCTAssertEqual(reference.model_sha256, ORTProbe.expectedModelSHA256)
        XCTAssertEqual(reference.input_shape, SyntheticTensor.shape)
        XCTAssertEqual(reference.provider, "CPUExecutionProvider")
        XCTAssertEqual(Set(reference.cases.map(\.name)), Set(["pattern", "glyphs"]))

        let engine = try ORTProbe(modelURL: model)
        for expected in reference.cases {
            let values: [Float]
            switch expected.name {
            case "pattern": values = SyntheticTensor.pattern()
            case "glyphs": values = SyntheticTensor.glyphsInput()
            default: XCTFail("Unexpected reference case \(expected.name)"); continue
            }
            let actual = try engine.run(values, sampleTimes: expected.sample_times,
                                        sampleClasses: expected.sample_classes)
            let encoded = try JSONEncoder().encode(actual)
            let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
            attachment.name = "onnx-synthetic-\(expected.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("ONNX_SYNTHETIC_\(expected.name.uppercased()) " + String(decoding: encoded, as: UTF8.self))

            XCTAssertEqual(actual.inputSHA256, expected.input_sha256_little_endian)
            XCTAssertEqual(expected.output_dtype, "float32")
            XCTAssertEqual(actual.outputShape, expected.output_shape)
            XCTAssertEqual(actual.argmax, expected.argmax, "Compare every timestep, not just blank CTC output")
            XCTAssertTrue(actual.partialCTC.unknownClasses.isEmpty,
                          "Unmapped classes: \(actual.partialCTC.unknownClasses)")
            XCTAssertEqual(actual.partialCTC.text, expected.ctc_text)
            XCTAssertEqual(actual.partialCTC.runs.count, expected.ctc_runs.count)
            let digitLabels = Dictionary(uniqueKeysWithValues: (0...9).map { ($0 + 33, String($0)) })
            let confidence = try CTCConfidence.evaluate(indices: actual.argmax, scores: actual.argmaxScores,
                                                        labels: digitLabels)
            XCTAssertEqual(confidence.items.map(\.run), actual.partialCTC.runs)
            XCTAssertTrue(confidence.items.allSatisfy { $0.reviewReasons.contains(.uncalibrated) })
            for (actualRun, expectedRun) in zip(actual.partialCTC.runs, expected.ctc_runs) {
                XCTAssertEqual(actualRun.classID, expectedRun.`class`)
                XCTAssertEqual(actualRun.start, expectedRun.start)
                XCTAssertEqual(actualRun.end, expectedRun.end)
                XCTAssertEqual(actualRun.character, expectedRun.character)
            }
            for item in confidence.items {
                XCTAssertEqual(item.rawFirstScore, expected.argmax_scores[item.run.start], accuracy: 0.001)
            }
            if expected.name == "glyphs" { XCTAssertEqual(expected.ctc_text, "0123456789") }
            XCTAssertEqual(actual.argmaxScores.count, expected.argmax_scores.count)
            for (actualScore, expectedScore) in zip(actual.argmaxScores, expected.argmax_scores) {
                XCTAssertEqual(actualScore, expectedScore, accuracy: 0.001)
            }
            XCTAssertEqual(actual.sampleValues.count, expected.sample_values.count)
            for (actualRow, expectedRow) in zip(actual.sampleValues, expected.sample_values) {
                XCTAssertEqual(actualRow.count, expectedRow.count)
                for (actualValue, expectedValue) in zip(actualRow, expectedRow) {
                    XCTAssertEqual(actualValue, expectedValue, accuracy: 0.001)
                }
            }
        }
    }
}

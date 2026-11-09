import Foundation
import ImageIO
import UIKit
import Vision
import XCTest

/// A small, generated-only measurement. Test success means the benchmark ran;
/// it is not an accuracy, full-page detection, GP export or device-performance gate.
@MainActor
final class SyntheticVisionTabDigitBenchmarkTests: XCTestCase {
    private struct Note: Encodable {
        let string: Int
        let fret: Int
        let x: Double
    }

    private struct Prediction: Encodable {
        let string: Int
        let text: String
        let x: Double
        let confidence: Float
    }

    private struct Counts: Encodable, Equatable {
        var correct = 0
        var missed = 0
        var misread = 0
        var wrongString = 0
        var extra = 0
    }

    private struct Measurement: Encodable {
        let scenario: String
        let recognitionLevel: String
        let revision: Int
        let seconds: Double
        let expected: [Note]
        let predictions: [Prediction]
        let counts: Counts
    }

    // Text is created by the test; none of the user's scores are read or uploaded.
    private let notes: [Note] = [
        Note(string: 1, fret: 0, x: 140),
        Note(string: 2, fret: 1, x: 260),
        Note(string: 3, fret: 8, x: 380),
        Note(string: 4, fret: 10, x: 500),
        Note(string: 5, fret: 11, x: 620),
        Note(string: 5, fret: 11, x: 680),
        Note(string: 6, fret: 12, x: 800),
        Note(string: 1, fret: 3, x: 1000),
        Note(string: 3, fret: 5, x: 1000),
    ]
    private let lineY: [CGFloat] = [80, 128, 176, 224, 272, 320]
    private let size = CGSize(width: 1150, height: 400)

    func testMatcherCountsMissedMisreadWrongStringAndExtraSeparately() {
        let expected = [Note(string: 1, fret: 11, x: 100), Note(string: 1, fret: 11, x: 180),
                        Note(string: 2, fret: 12, x: 260), Note(string: 3, fret: 8, x: 340),
                        Note(string: 4, fret: 1, x: 420)]
        let predictions = [Prediction(string: 1, text: "11", x: 100, confidence: 0.9),
                           Prediction(string: 1, text: "11", x: 180, confidence: 0.9),
                           Prediction(string: 2, text: "1", x: 260, confidence: 0.9),
                           Prediction(string: 5, text: "8", x: 340, confidence: 0.9),
                           Prediction(string: 6, text: "0", x: 500, confidence: 0.9)]
        XCTAssertEqual(compare(expected: expected, predictions: predictions),
                       Counts(correct: 2, missed: 1, misread: 1, wrongString: 1, extra: 1))
    }

    func testSyntheticVisionMeasurementsWithoutAccuracyGate() throws {
        var measurements: [Measurement] = []
        for knockout in [true, false] {
            let image = try XCTUnwrap(makePage(knockout: knockout).cgImage)
            for (label, level) in [("accurate", VNRequestTextRecognitionLevel.accurate),
                                   ("fast", VNRequestTextRecognitionLevel.fast)] {
                // One unmeasured request per configuration reduces first-load bias.
                let warmup = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: lineY[0] - 22, width: size.width, height: 44).integral))
                try VNImageRequestHandler(cgImage: warmup, orientation: .up, options: [:]).perform([makeRequest(level: level)])
                let start = ProcessInfo.processInfo.systemUptime
                var predictions: [Prediction] = []
                var revision = 0
                for (index, y) in lineY.enumerated() {
                    // Ground-truth string positions intentionally bypass line/region detection.
                    let cropRect = CGRect(x: 0, y: y - 22, width: size.width, height: 44).integral
                    let crop = try XCTUnwrap(image.cropping(to: cropRect))
                    let request = makeRequest(level: level)
                    revision = request.revision
                    try VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:]).perform([request])
                    for observation in request.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let text = candidate.string
                        let matches = try NSRegularExpression(pattern: "\\S+")
                            .matches(in: text, range: NSRange(text.startIndex..., in: text))
                        for match in matches {
                            guard let range = Range(match.range, in: text) else { continue }
                            // Vision boxes are approximate; use them only for coarse matching.
                            let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                            predictions.append(Prediction(string: index + 1, text: String(text[range]),
                                                          x: Double(box.midX) * Double(size.width),
                                                          confidence: candidate.confidence))
                        }
                    }
                }
                predictions.sort {
                    if $0.string != $1.string { return $0.string < $1.string }
                    if $0.x != $1.x { return $0.x < $1.x }
                    return $0.text < $1.text
                }
                measurements.append(Measurement(scenario: knockout ? "white_digit_background" : "line_through_digit",
                                                recognitionLevel: label, revision: revision,
                                                seconds: ProcessInfo.processInfo.systemUptime - start,
                                                expected: notes, predictions: predictions,
                                                counts: compare(expected: notes, predictions: predictions)))
            }
        }
        struct Report: Encodable {
            let disclaimer: String
            let system: String
            let imageWidth: Int
            let imageHeight: Int
            let lineY: [Double]
            let bandHeight: Int
            let font: String
            let matchingTolerance: Double
            let timing: String
            let measurements: [Measurement]
        }
        let report = Report(disclaimer: "Generated examples only; not a real-score accuracy or iPad mini 6 performance claim. Positions use known string lines, not automatic region detection. Confidence is not a correctness probability.",
                            system: ProcessInfo.processInfo.operatingSystemVersionString,
                            imageWidth: Int(size.width), imageHeight: Int(size.height),
                            lineY: lineY.map(Double.init), bandHeight: 44,
                            font: "monospacedDigitSystemFont, 30 pt, medium", matchingTolerance: 26,
                            timing: "One warm-up request per configuration; timed section includes six string crops, OCR and result parsing on the reported system.",
                            measurements: measurements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-vision-tab-digit-benchmark"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SYNTHETIC_VISION_TAB_DIGIT_BENCHMARK\n" + String(decoding: data, as: UTF8.self))
        // No OCR quality assertion: CI success means only that measurement ran.
    }

    private func makeRequest(level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        return request
    }

    private func makePage(knockout: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(1)
            for y in lineY {
                cg.move(to: CGPoint(x: 30, y: y))
                cg.addLine(to: CGPoint(x: size.width - 30, y: y))
            }
            cg.strokePath()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for note in notes {
                let text = String(note.fret) as NSString
                let textSize = text.size(withAttributes: attributes)
                let frame = CGRect(x: CGFloat(note.x) - textSize.width / 2,
                                   y: lineY[note.string - 1] - textSize.height / 2,
                                   width: textSize.width, height: textSize.height)
                if knockout {
                    UIColor.white.setFill()
                    context.fill(frame.insetBy(dx: -1, dy: 0))
                }
                text.draw(in: frame, withAttributes: attributes)
            }
        }
    }

    private func compare(expected: [Note], predictions: [Prediction]) -> Counts {
        let tolerance = 26.0
        var remaining = Set(predictions.indices)
        var unresolved: [Note] = []
        var counts = Counts()
        func nearest(_ note: Note, where matches: (Prediction) -> Bool) -> Int? {
            remaining.filter { matches(predictions[$0]) && abs(predictions[$0].x - note.x) <= tolerance }
                .min {
                    let left = abs(predictions[$0].x - note.x), right = abs(predictions[$1].x - note.x)
                    return left == right ? $0 < $1 : left < right
                }
        }
        // Assign exact hits first so chords with vertically aligned notes cannot
        // consume one another as wrong-string matches.
        for note in expected {
            if let index = nearest(note, where: { $0.string == note.string && $0.text == String(note.fret) }) {
                remaining.remove(index)
                counts.correct += 1
            } else {
                unresolved.append(note)
            }
        }
        for note in unresolved {
            if let index = nearest(note, where: { $0.string == note.string }) {
                remaining.remove(index)
                counts.misread += 1
            } else if let index = nearest(note, where: { $0.string != note.string && $0.text == String(note.fret) }) {
                remaining.remove(index)
                counts.wrongString += 1
            } else {
                counts.missed += 1
            }
        }
        counts.extra = remaining.count
        return counts
    }
}

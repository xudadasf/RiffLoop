import Foundation
import ImageIO
import UIKit
import Vision
import XCTest

/// Independent comparison on the exact generated notes used by the first benchmark.
/// This measures hypotheses, not production OCR quality or full-page detection.
/// The extended Vision measurement is opt-in in iOS CI; the deterministic tests
/// still run normally. Dispatch iOS CI with run_vision_comparison=true to run it.
@MainActor
final class SyntheticVisionTabPreprocessingBenchmarkTests: XCTestCase {
    private struct Note: Encodable {
        let string: Int
        let fret: Int
        let x: Double
    }

    private struct CharacterBox {
        let character: Character
        let box: CGRect?
    }

    private struct Token {
        let string: Int
        let text: String
        let box: CGRect
        let characters: [CharacterBox]
        let confidence: Float
    }

    private struct Prediction: Encodable, Equatable {
        let string: Int
        let text: String
        let x: Double
        let confidence: Float
    }

    private struct Counts: Encodable {
        var correct = 0
        var missed = 0
        var misread = 0
        var wrongString = 0
        var extra = 0
    }

    private struct CharacterEvidence: Encodable {
        let character: String
        let box: [Double]?
    }

    private struct MatchEvidence: Encodable {
        let expected: Note
        let status: String
        let prediction: Prediction?
        let deltaX: Double?
    }

    private struct Measurement: Encodable {
        let scenario: String
        let recognitionLevel: String
        let revision: Int
        let method: String
        let preprocessing: String
        let seconds: Double
        let requestCount: Int
        let candidateCrops: [[Int]]
        let rawTokens: [Prediction]
        /// Character boxes share the rawTokens order and are approximate Vision output.
        let rawCharacters: [[CharacterEvidence]]
        let predictions: [Prediction]
        let counts: Counts
        let matches: [MatchEvidence]
        let extraPredictions: [Prediction]
    }

    private let truth: [Note] = [
        Note(string: 1, fret: 0, x: 140), Note(string: 2, fret: 1, x: 260),
        Note(string: 3, fret: 8, x: 380), Note(string: 4, fret: 10, x: 500),
        Note(string: 5, fret: 11, x: 620), Note(string: 5, fret: 11, x: 680),
        Note(string: 6, fret: 12, x: 800), Note(string: 1, fret: 3, x: 1000),
        Note(string: 3, fret: 5, x: 1000),
    ]
    private let lineY: [CGFloat] = [80, 128, 176, 224, 272, 320]
    private let size = CGSize(width: 1150, height: 400)

    func testSplitRequiresIndependentCharacterBoxesAndDoesNotGuessLetters() {
        func char(_ value: Character, _ x: CGFloat, width: CGFloat = 5) -> CharacterBox {
            CharacterBox(character: value, box: CGRect(x: x, y: 0, width: width, height: 20))
        }
        let token = Token(string: 1, text: "-11—11", box: CGRect(x: 80, y: 0, width: 95, height: 20),
                          characters: [char("-", 80), char("1", 96), char("1", 108),
                                       char("—", 135), char("1", 155), char("1", 167)], confidence: 0.8)
        XCTAssertEqual(splitWhenSeparable(token).map(\.text), ["11", "11"])
        let aliased = Token(string: 1, text: token.text, box: token.box,
                            characters: token.characters.map { CharacterBox(character: $0.character, box: token.box) },
                            confidence: 0.8)
        XCTAssertEqual(splitWhenSeparable(aliased).map(\.text), [token.text])
        let cyrillic = Token(string: 1, text: "-о-", box: token.box,
                             characters: [char("-", 80), char("о", 96), char("-", 112)], confidence: 0.8)
        XCTAssertEqual(splitWhenSeparable(cyrillic).map(\.text), ["-о-"])
        let ambiguous = Token(string: 1, text: "1111", box: token.box,
                              characters: [char("1", 80), char("1", 90), char("1", 100), char("1", 110)], confidence: 0.8)
        XCTAssertEqual(splitWhenSeparable(ambiguous).map(\.text), ["1111"])
    }

    func testProjectionFindsGroupsWithoutTruthPositions() {
        var raster = GrayRaster(width: 100, height: 44, pixels: Array(repeating: 255, count: 4400))
        for x in 0..<100 { raster.pixels[22 * 100 + x] = 0 }
        for x in [20, 21, 26, 27, 70, 71] {
            for y in 8..<36 { raster.pixels[y * 100 + x] = 0 }
        }
        let groups = localGroups(raster)
        XCTAssertEqual(groups.map { [$0.lowerBound, $0.upperBound] }, [[17, 31], [67, 75]])
        let cleaned = removeKnownCenterLine(raster)
        XCTAssertEqual(cleaned.pixels[22 * 100 + 50], 255)
        XCTAssertEqual(cleaned.pixels[22 * 100 + 20], 0)
    }

    func testComparisonRecordsSignedErrorsAndNeverHidesExtraTokens() {
        let expected = [Note(string: 1, fret: 11, x: 100), Note(string: 2, fret: 12, x: 200),
                        Note(string: 3, fret: 8, x: 300), Note(string: 4, fret: 1, x: 400)]
        let predictions = [Prediction(string: 1, text: "11", x: 104, confidence: 0.9),
                           Prediction(string: 2, text: "1", x: 198, confidence: 0.8),
                           Prediction(string: 5, text: "8", x: 300, confidence: 0.7),
                           Prediction(string: 6, text: "0", x: 500, confidence: 0.6)]
        let result = compare(expected: expected, predictions: predictions)
        XCTAssertEqual(result.matches.map(\.status), ["correct", "misread", "wrong_string", "missed"])
        XCTAssertEqual(result.matches.map(\.deltaX), [4, -2, 0, nil])
        XCTAssertEqual(result.counts.correct, 1)
        XCTAssertEqual(result.counts.extra, 1)
        XCTAssertEqual(result.extras, [predictions[3]])
    }

    func testIndependentSyntheticVisionPreprocessingComparison() throws {
        var measurements: [Measurement] = []
        for knockout in [true, false] {
            let page = try XCTUnwrap(makePage(knockout: knockout).cgImage)
            let bands = try lineY.map { y in
                try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: y - 22, width: size.width, height: 44).integral))
            }
            for (label, level) in [("accurate", VNRequestTextRecognitionLevel.accurate),
                                   ("fast", VNRequestTextRecognitionLevel.fast)] {
                // Warm-up is outside reported timing and uses only a generated band.
                _ = try recognize(bands[0], string: 1, offset: 0, level: level)
                let scenario = knockout ? "white_digit_background" : "line_through_digit"

                let rawStart = ProcessInfo.processInfo.systemUptime
                var rawTokens: [Token] = []
                for (index, band) in bands.enumerated() {
                    rawTokens += try recognize(band, string: index + 1, offset: 0, level: level)
                }
                let rawTime = ProcessInfo.processInfo.systemUptime - rawStart
                let rawPredictions = rawTokens.map(rawPrediction)
                let revision = makeRequest(level).revision
                measurements.append(measurement(scenario, label, revision, "strict_band", "Unmodified string band; whole non-whitespace tokens.",
                                                rawTime, bands.count, [], rawTokens, rawPredictions))

                let splitStart = ProcessInfo.processInfo.systemUptime
                let split = rawTokens.flatMap(splitWhenSeparable)
                let splitTime = ProcessInfo.processInfo.systemUptime - splitStart
                measurements.append(measurement(scenario, label, revision, "independent_character_boxes", "Same raw OCR as strict_band; split only ASCII digits with individually non-overlapping, ordered Vision boxes; retain ambiguous raw tokens.",
                                                rawTime + splitTime, bands.count, [], rawTokens, split))

                let cleanedStart = ProcessInfo.processInfo.systemUptime
                let rasters = try bands.map(GrayRaster.init)
                let cleaned = rasters.map(removeKnownCenterLine)
                let cleanedImages = try cleaned.map { try XCTUnwrap($0.makeImage()) }
                let preprocessingTime = ProcessInfo.processInfo.systemUptime - cleanedStart
                var cleanedTokens: [Token] = []
                for (index, band) in cleanedImages.enumerated() {
                    cleanedTokens += try recognize(band, string: index + 1, offset: 0, level: level)
                }
                let cleanedTime = ProcessInfo.processInfo.systemUptime - cleanedStart
                let cleanedPredictions = cleanedTokens.map(rawPrediction)
                measurements.append(measurement(scenario, label, revision, "known_line_removal", "Use known band-center line; replace five center rows except vertically continuous dark strokes; OCR whole cleaned band.",
                                                cleanedTime, cleanedImages.count, [], cleanedTokens, cleanedPredictions))

                let localStart = ProcessInfo.processInfo.systemUptime
                var localTokens: [Token] = []
                var cropRecords: [[Int]] = []
                var requestCount = 0
                for (index, raster) in rasters.enumerated() {
                    // Candidate x positions come from ink projection, never the test truth.
                    for group in localGroups(raster) {
                        let rect = CGRect(x: CGFloat(group.lowerBound), y: 0,
                                          width: CGFloat(group.count), height: CGFloat(raster.height))
                        guard let crop = cleanedImages[index].cropping(to: rect) else { continue }
                        cropRecords.append([index + 1, group.lowerBound, group.upperBound])
                        localTokens += try recognize(crop, string: index + 1, offset: Double(group.lowerBound), level: level)
                        requestCount += 1
                    }
                }
                let localTime = ProcessInfo.processInfo.systemUptime - localStart
                let localPredictions = localTokens.map(rawPrediction)
                measurements.append(measurement(scenario, label, revision, "known_line_removal_local_crops", "Find x groups using ink outside the known line; OCR local cleaned crops; no ground-truth note positions used.",
                                                preprocessingTime + localTime, requestCount,
                                                cropRecords, localTokens, localPredictions))
            }
        }
        struct Report: Encodable {
            let disclaimer: String
            let system: String
            let truth: [Note]
            let matchingTolerance: Double
            let timing: String
            let measurements: [Measurement]
        }
        let report = Report(
            disclaimer: "Synthetic font and known string-line positions only. Not full-page recognition, real-score accuracy, or iPad mini 6 performance. OCR confidence is not a correctness probability. Character boxes are approximate and not guaranteed for image processing.",
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            truth: truth, matchingTolerance: 26,
            timing: "One warm-up per scenario/mode. Each method is timed once. Character-box timing includes shared strict-band OCR; local-crop timing includes the shared grayscale and cleaning cost, but excludes cleaned-band OCR. Do not interpret as device performance.",
            measurements: measurements
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-vision-tab-preprocessing-comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SYNTHETIC_VISION_TAB_PREPROCESSING_COMPARISON\n" + String(decoding: data, as: UTF8.self))
        // No acceptance assertion for OCR accuracy: this is a measurement.
    }

    private func makeRequest(_ level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        return request
    }

    private func recognize(_ image: CGImage, string: Int, offset: Double, level: VNRequestTextRecognitionLevel) throws -> [Token] {
        let request = makeRequest(level)
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        let regex = try NSRegularExpression(pattern: "\\S+")
        var result: [Token] = []
        func pixelBox(_ box: CGRect) -> CGRect {
            CGRect(x: CGFloat(offset) + box.minX * CGFloat(image.width), y: box.minY * CGFloat(image.height),
                   width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
        }
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let whole = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                var characters: [CharacterBox] = []
                var cursor = range.lowerBound
                while cursor < range.upperBound {
                    let next = text.index(after: cursor)
                    let box = (try? candidate.boundingBox(for: cursor..<next))?.boundingBox
                    characters.append(CharacterBox(character: text[cursor], box: box.map(pixelBox)))
                    cursor = next
                }
                result.append(Token(string: string, text: String(text[range]), box: pixelBox(whole),
                                    characters: characters, confidence: candidate.confidence))
            }
        }
        return result
    }

    private func rawPrediction(_ token: Token) -> Prediction {
        Prediction(string: token.string, text: token.text, x: Double(token.box.midX), confidence: token.confidence)
    }

    private func splitWhenSeparable(_ token: Token) -> [Prediction] {
        let original = [rawPrediction(token)]
        guard !token.characters.isEmpty, token.characters.map({ String($0.character) }).joined() == token.text else { return original }
        let allowed = "0123456789-–—_"
        guard token.characters.allSatisfy({ allowed.contains($0.character) && $0.box != nil }) else { return original }
        let boxes = token.characters.compactMap(\.box)
        guard boxes.count == token.characters.count,
              boxes.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.width <= 72 }),
              zip(boxes, boxes.dropFirst()).allSatisfy({ pair in pair.0.maxX <= pair.1.minX }) else { return original }
        var runs: [(String, CGRect)] = []
        var current = ""
        var bounds = CGRect.null
        var previous: CGRect?
        func flush() {
            if !current.isEmpty { runs.append((current, bounds)) }
            current = ""
            bounds = .null
            previous = nil
        }
        for (index, item) in token.characters.enumerated() {
            let box = boxes[index]
            guard "0123456789".contains(item.character) else { flush(); continue }
            if let previous, box.minX - previous.maxX > 48 * 0.38 { flush() }
            current.append(item.character)
            bounds = bounds.union(box)
            previous = box
        }
        flush()
        guard !runs.isEmpty, runs.allSatisfy({ run in
            run.0.count <= 2 && (run.0.count == 1 || run.0.first != "0") &&
                Int(run.0).map({ (0...36).contains($0) }) == true && run.1.width <= 72
        }) else { return original }
        return runs.map { Prediction(string: token.string, text: $0.0, x: Double($0.1.midX), confidence: token.confidence) }
    }

    private struct GrayRaster {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init(_ image: CGImage) throws {
            let imageWidth = image.width, imageHeight = image.height
            width = imageWidth
            height = imageHeight
            var data = [UInt8](repeating: 255, count: imageWidth * imageHeight)
            let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: imageWidth, height: imageHeight,
                                              bitsPerComponent: 8, bytesPerRow: imageWidth,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.translateBy(x: 0, y: CGFloat(imageHeight))
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
                return true
            }
            guard rendered else { throw BenchmarkError.rasterFailed }
            pixels = data
        }

        func makeImage() -> CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                           bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    private enum BenchmarkError: Error { case rasterFailed }

    private func removeKnownCenterLine(_ input: GrayRaster) -> GrayRaster {
        var output = input
        let center = input.height / 2
        guard center >= 3, center + 3 < input.height else { return output }
        for x in 0..<input.width {
            let above = input.pixels[(center - 3) * input.width + x] < 180
            let below = input.pixels[(center + 3) * input.width + x] < 180
            for y in (center - 2)...(center + 2) {
                output.pixels[y * input.width + x] = above && below ? input.pixels[y * input.width + x] : 255
            }
        }
        return output
    }

    private func localGroups(_ image: GrayRaster) -> [Range<Int>] {
        let center = image.height / 2
        var active: [Int] = []
        for x in 0..<image.width {
            var dark = 0
            for y in 0..<image.height where abs(y - center) > 2 {
                if image.pixels[y * image.width + x] < 180 { dark += 1 }
            }
            if dark >= 2 { active.append(x) }
        }
        guard let first = active.first else { return [] }
        var groups: [Range<Int>] = []
        var start = first, previous = first
        for x in active.dropFirst() {
            if x - previous > 19 {
                groups.append(max(0, start - 3)..<min(image.width, previous + 4))
                start = x
            }
            previous = x
        }
        groups.append(max(0, start - 3)..<min(image.width, previous + 4))
        return groups
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
                .font: UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .medium), .foregroundColor: UIColor.black,
            ]
            for note in truth {
                let text = String(note.fret) as NSString
                let textSize = text.size(withAttributes: attributes)
                let frame = CGRect(x: CGFloat(note.x) - textSize.width / 2,
                                   y: lineY[note.string - 1] - textSize.height / 2,
                                   width: textSize.width, height: textSize.height)
                if knockout { UIColor.white.setFill(); context.fill(frame.insetBy(dx: -1, dy: 0)) }
                text.draw(in: frame, withAttributes: attributes)
            }
        }
    }

    private func measurement(_ scenario: String, _ level: String, _ revision: Int, _ method: String,
                             _ preprocessing: String, _ seconds: Double, _ requestCount: Int,
                             _ crops: [[Int]], _ raw: [Token], _ predictions: [Prediction]) -> Measurement {
        let comparison = compare(expected: truth, predictions: predictions)
        return Measurement(scenario: scenario, recognitionLevel: level, revision: revision, method: method,
                           preprocessing: preprocessing, seconds: seconds, requestCount: requestCount,
                           candidateCrops: crops, rawTokens: raw.map(rawPrediction),
                           rawCharacters: raw.map { token in token.characters.map { character in
                               CharacterEvidence(character: String(character.character), box: character.box.map {
                                   [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)]
                               })
                           } },
                           predictions: predictions, counts: comparison.counts,
                           matches: comparison.matches, extraPredictions: comparison.extras)
    }

    private func compare(expected: [Note], predictions: [Prediction]) -> (counts: Counts, matches: [MatchEvidence], extras: [Prediction]) {
        let tolerance = 26.0
        var remaining = Set(predictions.indices)
        var unresolved: [(Int, Note)] = []
        var matches: [Int: MatchEvidence] = [:]
        var counts = Counts()
        func nearest(_ note: Note, where matches: (Prediction) -> Bool) -> Int? {
            remaining.filter { matches(predictions[$0]) && abs(predictions[$0].x - note.x) <= tolerance }
                .min {
                    let left = abs(predictions[$0].x - note.x), right = abs(predictions[$1].x - note.x)
                    return left == right ? $0 < $1 : left < right
                }
        }
        func record(_ index: Int, _ note: Note, _ status: String, _ predictionIndex: Int?) {
            let prediction = predictionIndex.map { predictions[$0] }
            matches[index] = MatchEvidence(expected: note, status: status, prediction: prediction,
                                           deltaX: prediction.map { $0.x - note.x })
        }
        for (expectedIndex, note) in expected.enumerated() {
            if let index = nearest(note, where: { $0.string == note.string && $0.text == String(note.fret) }) {
                remaining.remove(index); counts.correct += 1
                record(expectedIndex, note, "correct", index)
            } else { unresolved.append((expectedIndex, note)) }
        }
        for (expectedIndex, note) in unresolved {
            if let index = nearest(note, where: { $0.string == note.string }) {
                remaining.remove(index); counts.misread += 1
                record(expectedIndex, note, "misread", index)
            } else if let index = nearest(note, where: { $0.string != note.string && $0.text == String(note.fret) }) {
                remaining.remove(index); counts.wrongString += 1
                record(expectedIndex, note, "wrong_string", index)
            } else {
                counts.missed += 1
                record(expectedIndex, note, "missed", nil)
            }
        }
        counts.extra = remaining.count
        return (counts, expected.indices.compactMap { matches[$0] }, remaining.sorted().map { predictions[$0] })
    }
}

import CryptoKit
import Foundation
import OnnxRuntimeBindings

enum ORTProbeError: Error {
    case unexpectedModel
    case unexpectedNames
    case unexpectedTensor
    case invalidSample
}

struct PartialCTCResult: Codable, Equatable {
    struct Run: Codable, Equatable {
        let classID: Int
        let start: Int
        var end: Int
        let character: String?
    }

    /// Nil means at least one class is outside the deliberately partial map.
    let text: String?
    let unknownClasses: [Int]
    /// Inclusive model time steps; these are not yet image coordinates.
    let runs: [Run]
}

enum PartialCTC {
    static func decode(_ indices: [Int], labels: [Int: String], blank: Int = 0) -> PartialCTCResult {
        var previous: Int?
        var pieces: [String] = []
        var unknown = Set<Int>()
        var runs: [PartialCTCResult.Run] = []
        for (time, index) in indices.enumerated() {
            defer { previous = index }
            guard index != blank else { continue }
            if index == previous {
                runs[runs.count - 1].end = time
            } else {
                let character = labels[index]
                runs.append(.init(classID: index, start: time, end: time, character: character))
                if let character { pieces.append(character) } else { unknown.insert(index) }
            }
        }
        return PartialCTCResult(text: unknown.isEmpty ? pieces.joined() : nil,
                                unknownClasses: unknown.sorted(), runs: runs)
    }
}

enum SyntheticTensor {
    static let shape = [1, 3, 48, 320]
    static let count = shape.reduce(1, *)
    static let patternSHA256 = "49afe1d7d68e25e5a49d0cff47d15d54f1c37cb939a72c17b4daf031c421f9c4"
    static let glyphSHA256 = "c799e3dae03b67589e41846970041504c13d2d04e9a9b6cdbc9baa9dee8b58cf"
    static let glyphs = [
        "01110/10001/10011/10101/11001/10001/01110",
        "00100/01100/00100/00100/00100/00100/01110",
        "01110/10001/00001/00010/00100/01000/11111",
        "11110/00001/00001/01110/00001/00001/11110",
        "00010/00110/01010/10010/11111/00010/00010",
        "11111/10000/10000/11110/00001/00001/11110",
        "01110/10000/10000/11110/10001/10001/01110",
        "11111/00001/00010/00100/01000/01000/01000",
        "01110/10001/10001/01110/10001/10001/01110",
        "01110/10001/10001/01111/00001/00001/01110",
    ]

    static func pattern() -> [Float] {
        (0..<count).map { Float(($0 % 7) - 3) * 0.25 }
    }

    static func glyphsInput() -> [Float] {
        var result = [Float](repeating: 1, count: count)
        for (number, glyph) in glyphs.enumerated() {
            for (row, line) in glyph.split(separator: "/").enumerated() {
                for (column, bit) in line.enumerated() where bit == "1" {
                    let x = 4 + number * 31 + column * 4
                    let y = 10 + row * 4
                    for channel in 0..<3 {
                        for dy in 0..<4 {
                            for dx in 0..<4 { result[(channel * 48 + y + dy) * 320 + x + dx] = -1 }
                        }
                    }
                }
            }
        }
        return result
    }

    static func generatedBand(width: Int, height: Int = 40) -> [UInt8]? {
        guard (height == 40 && (width == 200 || width == 560)) ||
                (height == 20 && (width == 200 || width == 531)) else { return nil }
        let step = width == 200 ? 19 : (width == 560 ? 55 : 52)
        let scale = height == 40 ? 3 : 2
        let top = height == 40 ? 9 : 3
        var pixels = [UInt8](repeating: 255, count: width * height)
        for x in 0..<width { pixels[(height / 2) * width + x] = 140 }
        for (number, glyph) in glyphs.enumerated() {
            for (row, line) in glyph.split(separator: "/").enumerated() {
                for (column, bit) in line.enumerated() where bit == "1" {
                    let x = 4 + number * step + column * scale
                    let y = top + row * scale
                    for dy in 0..<scale {
                        for dx in 0..<scale { pixels[(y + dy) * width + x + dx] = 0 }
                    }
                }
            }
        }
        return pixels
    }

    static func data(_ values: [Float]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ORTProbeObservation: Encodable {
    let inputSHA256: String
    let outputShape: [Int]
    let argmax: [Int]
    let argmaxScores: [Float]
    let partialCTC: PartialCTCResult
    let sampleTimes: [Int]
    let sampleClasses: [Int]
    let sampleValues: [[Float]]
    /// Simulator timing is diagnostic only; this is not mini 6 performance.
    let inferenceSeconds: Double
}

final class ORTProbe {
    static let expectedModelSHA256 = "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884"
    private let environment: ORTEnv
    private let session: ORTSession
    private let classes = 18_710

    init(modelURL: URL) throws {
        guard SyntheticTensor.sha256(try Data(contentsOf: modelURL)) == Self.expectedModelSHA256 else {
            throw ORTProbeError.unexpectedModel
        }
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        let loaded = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        guard try loaded.inputNames() == ["x"], try loaded.outputNames() == ["fetch_name_0"] else {
            throw ORTProbeError.unexpectedNames
        }
        environment = env
        session = loaded
    }

    func run(_ values: [Float], width: Int = 320, sampleTimes: [Int], sampleClasses: [Int]) throws -> ORTProbeObservation {
        guard width > 0, width <= 3200, values.count == 3 * 48 * width,
              sampleClasses.allSatisfy({ (0..<classes).contains($0) }) else { throw ORTProbeError.invalidSample }
        let inputData = SyntheticTensor.data(values)
        let input = try ORTValue(tensorData: NSMutableData(data: inputData), elementType: .float,
                                 shape: [1, 3, 48, width].map { NSNumber(value: $0) })
        let start = ProcessInfo.processInfo.systemUptime
        let outputs = try session.run(withInputs: ["x": input], outputNames: ["fetch_name_0"], runOptions: nil)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard let output = outputs["fetch_name_0"] else { throw ORTProbeError.unexpectedTensor }
        let info = try output.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        guard info.elementType == .float, shape.count == 3, shape[0] == 1,
              shape[1] > 0, shape[2] == classes else { throw ORTProbeError.unexpectedTensor }
        let timeSteps = shape[1]
        guard sampleTimes.allSatisfy({ (0..<timeSteps).contains($0) }) else { throw ORTProbeError.invalidSample }
        let raw = try output.tensorData()
        guard raw.length == timeSteps * classes * MemoryLayout<Float>.size else { throw ORTProbeError.unexpectedTensor }
        // ORT owns the tensor memory; copy it before the ORTValue leaves scope.
        let copy = Data(bytes: raw.bytes, count: raw.length)
        let floats: [Float] = copy.withUnsafeBytes { bytes in
            (0..<(timeSteps * classes)).map { index in
                let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        guard floats.allSatisfy(\.isFinite) else { throw ORTProbeError.unexpectedTensor }
        var indices: [Int] = []
        var scores: [Float] = []
        for time in 0..<timeSteps {
            let start = time * classes
            var best = 0
            for index in 1..<classes where floats[start + index] > floats[start + best] { best = index }
            indices.append(best)
            scores.append(floats[start + best])
        }
        // This is deliberately only the fixed model's digits, not its full alphabet.
        let digits = Dictionary(uniqueKeysWithValues: (0...9).map { ($0 + 33, String($0)) })
        let sampled = sampleTimes.map { time in sampleClasses.map { floats[time * classes + $0] } }
        return ORTProbeObservation(inputSHA256: SyntheticTensor.sha256(inputData), outputShape: shape,
                                   argmax: indices, argmaxScores: scores,
                                   partialCTC: PartialCTC.decode(indices, labels: digits),
                                   sampleTimes: sampleTimes, sampleClasses: sampleClasses,
                                   sampleValues: sampled, inferenceSeconds: elapsed)
    }
}

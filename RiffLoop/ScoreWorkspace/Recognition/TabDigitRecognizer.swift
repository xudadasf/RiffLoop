import Foundation
import CryptoKit
import OnnxRuntimeBindings

enum TabRecognitionError: LocalizedError {
    case modelMissing, invalidImage, invalidTensor, noStrings, tooLarge
    var errorDescription: String? {
        switch self {
        case .modelMissing: return "数字模型缺失或校验失败"
        case .invalidImage: return "无法读取识别区域"
        case .invalidTensor: return "数字模型输出无效"
        case .noStrings: return "没有找到完整的六根谱线，请缩小到一行六线谱后重试"
        case .tooLarge: return "区域过大，请拆成较小的识别区域"
        }
    }
}

struct TabDigitCandidate {
    var x: Double
    var fret: Int?
    var score: Float
    var text: String
}

/// Constructed and used only inside the recognition actor, then released.
/// No network requests, audio sessions, or model allocation during practice.
final class TabDigitRecognizer {
    private let environment: ORTEnv
    private let session: ORTSession
    init(modelURL: URL? = Bundle.main.url(forResource: "PP-OCRv6_rec_small", withExtension: "onnx")) throws {
        guard let url = modelURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884" else { throw TabRecognitionError.modelMissing }
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
    }

    func recognize(_ pixels: [UInt8], width: Int, height: Int, gap: Double) throws -> [TabDigitCandidate] {
        try Task.checkCancellation()
        return try autoreleasepool {
            let band = try GrayBandPreprocessor.prepare(pixels, width: width, height: height)
            let data = band.tensor.withUnsafeBytes { Data($0) }
            let input = try ORTValue(tensorData: NSMutableData(data: data), elementType: .float,
                                     shape: [1, 3, 48, band.width].map { NSNumber(value: $0) })
            let outputs = try session.run(withInputs: ["x": input], outputNames: ["fetch_name_0"], runOptions: nil)
            guard let output = outputs["fetch_name_0"] else { throw TabRecognitionError.invalidTensor }
            let info = try output.tensorTypeAndShapeInfo(), shape = info.shape.map(\.intValue)
            guard info.elementType == .float, shape.count == 3, shape[0] == 1, (1...800).contains(shape[1]), shape[2] == 18710 else { throw TabRecognitionError.invalidTensor }
            let raw = try output.tensorData()
            guard raw.length == shape[1] * shape[2] * 4 else { throw TabRecognitionError.invalidTensor }
            // Read ORT-owned memory in place; do not duplicate the large class matrix.
            let values = raw.bytes.assumingMemoryBound(to: Float.self)
            var indices: [Int] = [], scores: [Float] = []
            for time in 0..<shape[1] {
                let start = time * shape[2]
                var best = 0
                for i in 1..<shape[2] where values[start + i] > values[start + best] { best = i }
                guard values[start + best].isFinite else { throw TabRecognitionError.invalidTensor }
                indices.append(best); scores.append(values[start + best])
            }
            let labels = Dictionary(uniqueKeysWithValues: (0...9).map { ($0 + 33, String($0)) })
            let result = PartialCTC.decode(indices, labels: labels)
            let located = try CTCLocation.locate(result.runs, timeSteps: shape[1], boundedWidth: band.boundedWidth,
                                                boundedHeight: band.boundedHeight, sourceLeft: 0, sourceRight: Double(width))
            let grouped = try DigitGrouping.group(located.map { .init(character: $0.run.character, x: $0.x, isWithinSource: $0.isWithinSource) }, stringGap: gap)
            return grouped.groups.map { group in
                let x = group.inputIndices.map { located[$0].x }.reduce(0, +) / Double(group.inputIndices.count)
                let confidence = group.inputIndices.map { scores[located[$0].run.start] }.min() ?? 0
                return TabDigitCandidate(x: x, fret: group.fret, score: confidence, text: group.text)
            }
        }
    }
}

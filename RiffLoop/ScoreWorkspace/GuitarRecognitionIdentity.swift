import CryptoKit
import Foundation

enum GuitarRecognitionIdentity {
    private struct Input: Encodable {
        let source: GuitarSource
        let rotation: Int
        let gapAfter: Int
    }
    private struct Request: Encodable {
        let version: Int = 1
        let inputs: [Input]
        let settings: ScoreRecognitionSettings
    }
    /// URLs change when an app container is updated; content and saved regions
    /// define the result instead. Reopening never overwrites manual corrections.
    static func id(regions: [TabRecognitionRegion], settings: ScoreRecognitionSettings) throws -> UUID {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let request = Request(inputs: regions.map { Input(source: $0.source, rotation: $0.rotation, gapAfter: $0.gapAfter) }, settings: settings)
        let hex = SHA256.hash(data: try encoder.encode(request)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return UUID(uuidString: String(c[0..<8]) + "-" + String(c[8..<12]) + "-" + String(c[12..<16]) + "-" + String(c[16..<20]) + "-" + String(c[20..<32]))!
    }
}

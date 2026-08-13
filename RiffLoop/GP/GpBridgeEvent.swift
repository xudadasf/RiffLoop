import Foundation

struct GpTrackMetadata: Codable, Equatable, Sendable {
    let index: Int
    let name: String
    let shortName: String
    let volume: Int
    let isMute: Bool
    let isSolo: Bool
}

struct GpScoreMetadata: Codable, Equatable, Sendable {
    let title: String
    let artist: String
    let bars: Int
    let tracks: [GpTrackMetadata]
}

struct GpRenderMetrics: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

struct GpPlaybackPosition: Codable, Equatable, Sendable {
    let currentTime: Double
    let totalTime: Double
    let currentTick: Double
    let endTick: Double
}

struct GpPlaybackState: Codable, Equatable, Sendable {
    let state: Int
    let stopped: Bool
}

struct GpBarHit: Codable, Equatable, Sendable {
    let index: Int
    let startTick: Double
    let endTick: Double
}

enum GpBridgeEvent: Equatable, Sendable {
    case ready
    case scoreLoaded(GpScoreMetadata)
    case renderFinished(GpRenderMetrics)
    case playerReady
    case positionChanged(GpPlaybackPosition)
    case playerStateChanged(GpPlaybackState)
    case barHit(GpBarHit)
    case error(String)

    static func decode(messageBody: Any) throws -> Self {
        guard JSONSerialization.isValidJSONObject(messageBody) else {
            throw GpBridgeDecodingError.invalidMessageBody
        }

        let data = try JSONSerialization.data(withJSONObject: messageBody)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let decoder = JSONDecoder()

        switch envelope.event {
        case "ready":
            return .ready
        case "scoreLoaded":
            return .scoreLoaded(try decoder.decode(GpScoreMetadata.self, from: envelope.payloadData))
        case "renderFinished":
            return .renderFinished(try decoder.decode(GpRenderMetrics.self, from: envelope.payloadData))
        case "playerReady":
            return .playerReady
        case "positionChanged":
            return .positionChanged(try decoder.decode(GpPlaybackPosition.self, from: envelope.payloadData))
        case "playerStateChanged":
            return .playerStateChanged(try decoder.decode(GpPlaybackState.self, from: envelope.payloadData))
        case "barHit":
            return .barHit(try decoder.decode(GpBarHit.self, from: envelope.payloadData))
        case "error":
            return .error(try decoder.decode(ErrorPayload.self, from: envelope.payloadData).message)
        default:
            throw GpBridgeDecodingError.unknownEvent(envelope.event)
        }
    }
}

enum GpBridgeDecodingError: Error, Equatable {
    case invalidMessageBody
    case missingPayload
    case unknownEvent(String)
}

private struct Envelope: Decodable {
    let event: String
    private let payload: JSONValue?

    var payloadData: Data {
        get throws {
            guard let payload else { throw GpBridgeDecodingError.missingPayload }
            return try JSONEncoder().encode(payload)
        }
    }
}

private struct ErrorPayload: Codable {
    let message: String
}

private enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

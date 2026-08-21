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
    let hasBackingTrack: Bool
    let tracks: [GpTrackMetadata]
    let beatsPerMeasure: Int?
    let beatUnit: Int?

    init(
        title: String,
        artist: String,
        bars: Int,
        hasBackingTrack: Bool,
        tracks: [GpTrackMetadata],
        beatsPerMeasure: Int? = nil,
        beatUnit: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.bars = bars
        self.hasBackingTrack = hasBackingTrack
        self.tracks = tracks
        self.beatsPerMeasure = beatsPerMeasure
        self.beatUnit = beatUnit
    }
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
    let isSeek: Bool?

    init(
        currentTime: Double,
        totalTime: Double,
        currentTick: Double,
        endTick: Double,
        isSeek: Bool? = nil
    ) {
        self.currentTime = currentTime
        self.totalTime = totalTime
        self.currentTick = currentTick
        self.endTick = endTick
        self.isSeek = isSeek
    }
}

struct GpPlaybackState: Codable, Equatable, Sendable {
    let state: Int
    let stopped: Bool
}

struct GpBarHit: Codable, Equatable, Sendable {
    let index: Int
    let startTick: Double
    let endTick: Double
    let seekTick: Double?

    init(index: Int, startTick: Double, endTick: Double, seekTick: Double? = nil) {
        self.index = index
        self.startTick = startTick
        self.endTick = endTick
        self.seekTick = seekTick
    }
}

enum GpBridgeEvent: Equatable, Sendable {
    case ready
    case scoreLoaded(GpScoreMetadata)
    case renderFinished(GpRenderMetrics)
    case playerReady
    case positionChanged(GpPlaybackPosition)
    case playerStateChanged(GpPlaybackState)
    case playerFinished
    case barHit(GpBarHit)
    case pointerDown(GpBarHit)
    case pointerMove(GpBarHit)
    case pointerUp
    case pointerCancel
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
        case "playerFinished":
            return .playerFinished
        case "barHit":
            return .barHit(try decoder.decode(GpBarHit.self, from: envelope.payloadData))
        case "pointerDown":
            return .pointerDown(try decoder.decode(GpBarHit.self, from: envelope.payloadData))
        case "pointerMove":
            return .pointerMove(try decoder.decode(GpBarHit.self, from: envelope.payloadData))
        case "pointerUp":
            return .pointerUp
        case "pointerCancel":
            return .pointerCancel
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

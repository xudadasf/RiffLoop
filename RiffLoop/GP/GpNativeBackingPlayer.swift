import AVFAudio
import Foundation

func gpBackingTime(
    forScoreTime scoreTime: Double,
    syncPoints: [GpBackingSyncPoint]
) -> Double? {
    guard scoreTime.isFinite else { return nil }
    let sorted = syncPoints
        .filter { $0.synthTime.isFinite && $0.syncTime.isFinite }
        .sorted { $0.synthTime < $1.synthTime }
    guard let first = sorted.first else { return scoreTime }
    guard sorted.count > 1 else {
        return first.syncTime + scoreTime - first.synthTime
    }

    let precedingIndex = sorted.lastIndex { $0.synthTime <= scoreTime } ?? 0
    let segmentIndex = min(precedingIndex, sorted.count - 2)
    let start = sorted[segmentIndex]
    let end = sorted[segmentIndex + 1]
    let scoreSpan = end.synthTime - start.synthTime
    guard scoreSpan > 0 else { return start.syncTime }
    let ratio = (scoreTime - start.synthTime) / scoreSpan
    return start.syncTime + (end.syncTime - start.syncTime) * ratio
}

func gpBackingTime(
    forPlaybackTime playbackTime: Double,
    playbackSpeed: Double,
    syncPoints: [GpBackingSyncPoint]
) -> Double? {
    let speed = playbackSpeed.isFinite && playbackSpeed > 0 ? playbackSpeed : 1
    return gpBackingTime(
        forScoreTime: playbackTime * speed,
        syncPoints: syncPoints
    )
}

func gpNativeBackingRate(_ rate: Double) -> Double {
    guard rate.isFinite else { return 1 }
    return min(max(rate, 1.0 / 32.0), 32)
}

func gpBackingFramePosition(
    milliseconds: Double,
    sampleRate: Double,
    frameLength: AVAudioFramePosition
) -> AVAudioFramePosition {
    guard milliseconds.isFinite, sampleRate.isFinite, sampleRate > 0 else { return 0 }
    let frame = AVAudioFramePosition((max(0, milliseconds) / 1_000 * sampleRate).rounded())
    return min(max(frame, 0), max(0, frameLength - 1))
}

final class GpNativeBackingPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var temporaryURL: URL?
    private var anchorFrame: AVAudioFramePosition = 0

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        playerNode.stop()
        engine.stop()
        removeTemporaryFile()
    }

    var isLoaded: Bool { audioFile != nil }
    var isPlaying: Bool { playerNode.isPlaying }
    var currentTimeMilliseconds: Double {
        guard let audioFile else { return 0 }
        return Double(currentFrame(audioFile: audioFile)) / audioFile.processingFormat.sampleRate * 1_000
    }
    var durationMilliseconds: Double {
        guard let audioFile else { return 0 }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1_000
    }

    func load(data: Data, mimeType: String) throws {
        reset()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("riffloop-gp-backing-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension(for: mimeType))
        do {
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            temporaryURL = url
            anchorFrame = 0
            timePitch.rate = 1
            engine.prepare()
            try engine.start()
            schedule(from: 0, audioFile: file)
        } catch {
            playerNode.stop()
            engine.stop()
            audioFile = nil
            temporaryURL = nil
            anchorFrame = 0
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func setVolume(_ volume: Double) {
        playerNode.volume = Float(min(max(volume, 0), 1))
    }

    func setRate(_ rate: Double) {
        timePitch.rate = Float(gpNativeBackingRate(rate))
    }

    func seek(to milliseconds: Double) {
        guard let audioFile else { return }
        let wasPlaying = playerNode.isPlaying
        let frame = gpBackingFramePosition(
            milliseconds: milliseconds,
            sampleRate: audioFile.processingFormat.sampleRate,
            frameLength: audioFile.length
        )
        schedule(from: frame, audioFile: audioFile)
        if wasPlaying { playerNode.play() }
    }

    @discardableResult
    func play(at milliseconds: Double, rate: Double, volume: Double) throws -> Bool {
        guard let audioFile else { return false }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        setRate(rate)
        setVolume(volume)
        let frame = gpBackingFramePosition(
            milliseconds: milliseconds,
            sampleRate: audioFile.processingFormat.sampleRate,
            frameLength: audioFile.length
        )
        schedule(from: frame, audioFile: audioFile)
        playerNode.play()
        return playerNode.isPlaying
    }

    func pause() {
        guard let audioFile else { return }
        anchorFrame = currentFrame(audioFile: audioFile)
        playerNode.stop()
    }

    func reset() {
        playerNode.stop()
        engine.stop()
        audioFile = nil
        anchorFrame = 0
        removeTemporaryFile()
    }

    private func schedule(from frame: AVAudioFramePosition, audioFile: AVAudioFile) {
        playerNode.stop()
        anchorFrame = min(max(frame, 0), max(0, audioFile.length - 1))
        let remaining = AVAudioFrameCount(max(0, audioFile.length - anchorFrame))
        guard remaining > 0 else { return }
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: anchorFrame,
            frameCount: remaining,
            at: nil
        )
    }

    private func currentFrame(audioFile: AVAudioFile) -> AVAudioFramePosition {
        guard
            playerNode.isPlaying,
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return anchorFrame }
        return min(
            anchorFrame + max(0, playerTime.sampleTime),
            max(0, audioFile.length - 1)
        )
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/ogg": "ogg"
        case "audio/flac": "flac"
        case "audio/mp4", "audio/aac": "m4a"
        default: "mp3"
        }
    }

    private func removeTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
        self.temporaryURL = nil
    }
}

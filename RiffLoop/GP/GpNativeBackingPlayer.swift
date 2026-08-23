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

final class GpNativeBackingPlayer {
    private var player: AVAudioPlayer?

    var isLoaded: Bool { player != nil }
    var isPlaying: Bool { player?.isPlaying == true }
    var currentTimeMilliseconds: Double { (player?.currentTime ?? 0) * 1_000 }
    var durationMilliseconds: Double { (player?.duration ?? 0) * 1_000 }

    func load(data: Data) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        player?.stop()
        let player = try AVAudioPlayer(data: data)
        player.enableRate = true
        player.prepareToPlay()
        self.player = player
    }

    func setVolume(_ volume: Double) {
        player?.volume = Float(min(max(volume, 0), 1))
    }

    func setRate(_ rate: Double) {
        player?.rate = Float(min(max(rate, 0.5), 1.5))
    }

    func seek(to milliseconds: Double) {
        guard let player else { return }
        player.currentTime = min(
            max(milliseconds / 1_000, 0),
            max(0, player.duration - 0.001)
        )
    }

    @discardableResult
    func play(at milliseconds: Double, rate: Double, volume: Double) throws -> Bool {
        guard let player else { return false }
        setRate(rate)
        setVolume(volume)
        seek(to: milliseconds)
        return player.play()
    }

    func pause() {
        player?.pause()
    }

    func reset() {
        player?.stop()
        player = nil
    }
}

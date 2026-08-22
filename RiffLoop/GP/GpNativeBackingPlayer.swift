import AVFAudio
import Foundation

final class GpNativeBackingPlayer {
    private var player: AVAudioPlayer?

    var isLoaded: Bool { player != nil }
    var isPlaying: Bool { player?.isPlaying == true }
    var currentTimeMilliseconds: Double { (player?.currentTime ?? 0) * 1_000 }
    var durationMilliseconds: Double { (player?.duration ?? 0) * 1_000 }

    func load(data: Data) throws {
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
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

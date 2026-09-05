import AVFoundation
import MediaToolbox
import os

func boostedAudioSample(_ sample: Float, gain: Float) -> Float {
    min(1, max(-1, sample * gain))
}

private final class AudioGainState {
    let gain = OSAllocatedUnfairLock(initialState: Float(1))
    var floatPCM = false // Written by prepare; read by process on the audio thread.
}

/// AVPlayer.volume stops at 100%. A processing tap boosts decoded local-file PCM
/// above that level without replacing AVPlayer's seek, pitch or synchronization.
@MainActor
final class PlayerAudioGain {
    private var states: [AudioGainState] = []
    private var requestedGain: Float = 1
    private var generation = 0

    func setVolume(_ volume: Float, player: AVPlayer) {
        requestedGain = min(2, max(0, volume))
        player.volume = min(1, requestedGain)
        let boost = max(1, requestedGain)
        for state in states { state.gain.withLock { $0 = boost } }
    }

    func attach(to item: AVPlayerItem, player: AVPlayer) async {
        generation += 1
        let request = generation
        states = []
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                guard request == self.generation, player.currentItem === item else { return }
                var parameters: [AVAudioMixInputParameters] = []
                for track in tracks {
                    let state = AudioGainState()
                    let boost = max(1, self.requestedGain)
                    state.gain.withLock { $0 = boost }
                    let retained = Unmanaged.passRetained(state)
                    var callbacks = MTAudioProcessingTapCallbacks(
                        version: kMTAudioProcessingTapCallbacksVersion_0,
                        clientInfo: retained.toOpaque(),
                        init: { _, clientInfo, storage in storage.pointee = clientInfo },
                        finalize: { tap in
                            Unmanaged<AudioGainState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                        },
                        prepare: { tap, _, format in
                            let state = Unmanaged<AudioGainState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                            state.floatPCM = format.pointee.mFormatID == kAudioFormatLinearPCM
                                && format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                                && format.pointee.mBitsPerChannel == 32
                        },
                        unprepare: { _ in },
                        process: { tap, frames, _, buffers, framesOut, flagsOut in
                            let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                            guard status == noErr else { framesOut.pointee = 0; return }
                            let state = Unmanaged<AudioGainState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                            let gain = state.gain.withLock { $0 }
                            guard state.floatPCM, gain > 1 else { return }
                            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                                guard let data = buffer.mData else { continue }
                                let samples = data.assumingMemoryBound(to: Float.self)
                                let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size,
                                    Int(framesOut.pointee) * Int(buffer.mNumberChannels))
                                for index in 0..<count {
                                    samples[index] = boostedAudioSample(samples[index], gain: gain)
                                }
                            }
                        }
                    )
                    var tap: Unmanaged<MTAudioProcessingTap>?
                    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                        kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
                    guard status == noErr, let tap else { retained.release(); continue }
                    let input = AVMutableAudioMixInputParameters(track: track)
                    input.audioTapProcessor = tap.takeRetainedValue()
                    parameters.append(input)
                    self.states.append(state)
                }
                let mix = AVMutableAudioMix()
                mix.inputParameters = parameters
                item.audioMix = mix
            } catch {
                // AVPlayer reports actual file/decoder failures through its normal UI.
                // Keep standard playback available if a track cannot provide a tap.
            }
    }
}

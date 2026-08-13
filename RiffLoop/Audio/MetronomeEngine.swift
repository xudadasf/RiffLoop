import AVFoundation
import Foundation
import QuartzCore

final class MetronomeEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let schedulingQueue = DispatchQueue(label: "com.riffloop.metronome.scheduler")
    private let sampleRate = 48_000.0
    private let schedulingHorizon: TimeInterval = 1.0
    private let schedulingLead: TimeInterval = 0.025
    private let format: AVAudioFormat

    private var regularClick: AVAudioPCMBuffer!
    private var accentClick: AVAudioPCMBuffer!
    private var subAccentClick: AVAudioPCMBuffer!
    private var subdivisionClick: AVAudioPCMBuffer!
    private var kickClick: AVAudioPCMBuffer!
    private var snareClick: AVAudioPCMBuffer!
    private var scheduler: DispatchSourceTimer?
    private var timeline: BeatTimeline?
    private var anchor: TransportAnchor?
    private var rhythmMode: RhythmMode = .click
    private var nextEventIndex: Int64 = 0
    private var generation: UInt64 = 0

    init() {
        format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        rebuildClickBuffers(duration: 0.035)
    }

    func prepare() throws {
        guard !engine.isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        engine.prepare()
        try engine.start()
    }

    func synchronize(
        timeline: BeatTimeline,
        anchor: TransportAnchor,
        rhythmMode: RhythmMode = .click,
        volume: Float = 1
    ) throws {
        try prepare()

        schedulingQueue.sync {
            generation &+= 1
            self.timeline = timeline
            self.anchor = anchor
            self.rhythmMode = rhythmMode
            playerNode.volume = min(max(volume, 0), 1)
            rebuildClickBuffers(
                duration: min(0.035, max(0.004, timeline.eventInterval / anchor.mediaRate / 2))
            )
            nextEventIndex = timeline.eventIndex(atOrAfter: anchor.mediaTime)

            playerNode.stop()
            scheduleAvailableEvents(generation: generation)
            playerNode.play()
            startSchedulerIfNeeded()
        }
    }

    func stop() {
        schedulingQueue.sync {
            generation &+= 1
            timeline = nil
            anchor = nil
            playerNode.stop()
            scheduler?.cancel()
            scheduler = nil
        }
    }

    private func startSchedulerIfNeeded() {
        guard scheduler == nil else { return }

        let schedulerGeneration = generation
        let timer = DispatchSource.makeTimerSource(queue: schedulingQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleAvailableEvents(generation: schedulerGeneration)
        }
        timer.resume()
        scheduler = timer
    }

    private func scheduleAvailableEvents(generation expectedGeneration: UInt64) {
        guard
            expectedGeneration == generation,
            let timeline,
            let anchor
        else { return }

        let now = CACurrentMediaTime()
        let horizon = now + schedulingHorizon

        while true {
            let event = timeline.event(at: nextEventIndex)
            let eventHostTime = anchor.hostTime(forMediaTime: event.mediaTime)

            if eventHostTime > horizon { break }
            nextEventIndex += 1

            if eventHostTime < now + schedulingLead { continue }
            if !timeline.shouldPlay(event.index, mode: rhythmMode) { continue }

            let buffer = clickBuffer(for: event.index, timeline: timeline)
            let audioTime = AVAudioTime(
                hostTime: AVAudioTime.hostTime(forSeconds: eventHostTime)
            )
            playerNode.scheduleBuffer(buffer, at: audioTime, options: [])
        }
    }

    private func clickBuffer(for index: Int64, timeline: BeatTimeline) -> AVAudioPCMBuffer {
        if rhythmMode == .drums {
            guard timeline.isBeatBoundary(index) else { return subdivisionClick }
            return [1, 3].contains(timeline.beatIndex(index)) ? snareClick : kickClick
        }
        guard timeline.isBeatBoundary(index) else { return subdivisionClick }
        switch timeline.beatAccent(index) {
        case .strong: return accentClick
        case .subAccent: return subAccentClick
        case .normal, .muted: return regularClick
        }
    }

    private func rebuildClickBuffers(duration: TimeInterval) {
        accentClick = Self.makeClick(
            frequency: 2_350,
            amplitude: 0.95,
            duration: duration,
            format: format
        )
        subAccentClick = Self.makeClick(
            frequency: 1_900,
            amplitude: 0.72,
            duration: duration,
            format: format
        )
        regularClick = Self.makeClick(
            frequency: 1_450,
            amplitude: 0.52,
            duration: duration,
            format: format
        )
        subdivisionClick = Self.makeClick(
            frequency: 1_150,
            amplitude: 0.30,
            duration: duration,
            format: format
        )
        kickClick = Self.makeClick(
            frequency: 120,
            amplitude: 0.95,
            duration: duration,
            format: format
        )
        snareClick = Self.makeClick(
            frequency: 1_700,
            amplitude: 0.78,
            duration: duration,
            format: format
        )
    }

    private static func makeClick(
        frequency: Double,
        amplitude: Float,
        duration: TimeInterval,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return buffer }

        for frame in 0..<Int(frameCount) {
            let seconds = Double(frame) / format.sampleRate
            let envelope = Float(exp(-seconds * 85))
            let sample = amplitude * envelope * Float(sin(2 * .pi * frequency * seconds))

            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }

        return buffer
    }
}

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

    private var regularClick: AVAudioPCMBuffer!
    private var accentClick: AVAudioPCMBuffer!
    private var scheduler: DispatchSourceTimer?
    private var timeline: BeatTimeline?
    private var anchor: TransportAnchor?
    private var nextEventIndex: Int64 = 0
    private var generation: UInt64 = 0

    init() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        regularClick = Self.makeClick(frequency: 1_600, amplitude: 0.55, format: format)
        accentClick = Self.makeClick(frequency: 2_300, amplitude: 0.85, format: format)
    }

    func prepare() throws {
        guard !engine.isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        engine.prepare()
        try engine.start()
    }

    func synchronize(timeline: BeatTimeline, anchor: TransportAnchor) throws {
        try prepare()

        schedulingQueue.sync {
            generation &+= 1
            self.timeline = timeline
            self.anchor = anchor
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

            let buffer = event.isMeasureAccent ? accentClick! : regularClick!
            let audioTime = AVAudioTime(
                hostTime: AVAudioTime.hostTime(forSeconds: eventHostTime)
            )
            playerNode.scheduleBuffer(buffer, at: audioTime, options: [])
        }
    }

    private static func makeClick(
        frequency: Double,
        amplitude: Float,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let duration = 0.035
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

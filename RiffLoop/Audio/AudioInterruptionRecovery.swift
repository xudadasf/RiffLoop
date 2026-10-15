import AVFAudio
import Combine
import UIKit

/// Retains a resume action only across a system interruption, never a user pause.
@MainActor
final class AudioInterruptionRecovery {
    var onBegan: (() -> (() -> Void)?)?
    var onDisconnect: (() -> Void)?
    private var resume: (() -> Void)?
    private var interruptedOutputs: [String] = []
    private var waitingForActivation = false
    private var observers = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                guard let type else { return }
                self?.handle(type: type, options: options,
                    outputs: Self.outputIDs,
                    active: UIApplication.shared.applicationState == .active)
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.disconnect()
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cancel() }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.becameActive(outputs: Self.outputIDs) }.store(in: &observers)
    }

    private static var outputIDs: [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.uid)" }.sorted()
    }

    func cancel() { resume = nil; interruptedOutputs = []; waitingForActivation = false }

    func becameActive(outputs: [String]) {
        guard waitingForActivation else { return }
        let action = outputs == interruptedOutputs && !outputs.isEmpty ? resume : nil
        cancel()
        action?()
    }

    func disconnect() {
        cancel()
        onDisconnect?()
    }

    func handle(type: UInt, options: UInt, outputs: [String], active: Bool) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            // A second interruption needs its own ended/shouldResume permission.
            waitingForActivation = false
            guard resume == nil else { return }
            let action = onBegan?()
            interruptedOutputs = outputs
            resume = action
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let action = resume
            let canResume = !outputs.isEmpty && outputs == interruptedOutputs
                && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            if canResume && !active {
                waitingForActivation = true
                return
            }
            cancel()
            if canResume { action?() }
        }
    }
}

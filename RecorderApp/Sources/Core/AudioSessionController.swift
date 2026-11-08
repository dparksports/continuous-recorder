import AVFoundation
import Foundation

/// Owns the audio session: category, activation, and every notification that can pull
/// the rug out from under a long recording.
///
/// Category choice: `.record` (input only). It is measurably cheaper than
/// `.playAndRecord` because the output route never activates, and it still keeps the
/// app alive in the background when `UIBackgroundModes = [audio]` is set.
/// If you ever need to keep playing audio while recording, switch to
/// `.playAndRecord` with `[.mixWithOthers]` and expect a slightly higher draw.
final class AudioSessionController {

    enum Event {
        case interruptionBegan
        case interruptionEnded(didResume: Bool)
        case inputRouteChanged
        case mediaServicesWereReset
    }

    /// Delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var tokens: [NSObjectProtocol] = []

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func configure() throws {
        try session.setCategory(.record, mode: .default, options: [])
        try session.setPreferredSampleRate(48_000)
        // Deliberately not touching `setPreferredIOBufferDuration`: a smaller buffer means
        // more wake-ups per second and more power for no recording benefit.
        observe()
    }

    func setActive(_ active: Bool) throws {
        try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
    }

    var isInputAvailable: Bool { session.isInputAvailable }
    var sampleRate: Double { session.sampleRate }
    var currentRouteName: String {
        session.currentRoute.inputs.first?.portName ?? "none"
    }

    // MARK: - Notifications

    private func observe() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default

        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Log.session.error("media services were reset")
            self?.onEvent?(.mediaServicesWereReset)
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            Log.session.notice("interruption began")
            onEvent?(.interruptionBegan)

        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            Log.session.notice("interruption ended, shouldResume=\(options.contains(.shouldResume))")
            onEvent?(.interruptionEnded(didResume: options.contains(.shouldResume)))

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override:
            // The hardware input may now be a different channel count or sample rate.
            // The capture format must be re-read; the recorder handles that by restarting.
            Log.session.notice("input route changed (reason \(raw))")
            onEvent?(.inputRouteChanged)
        case .categoryChange:
            Log.session.notice("audio category changed externally")
        default:
            break
        }
    }
}

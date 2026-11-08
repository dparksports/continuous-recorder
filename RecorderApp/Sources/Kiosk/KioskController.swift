import Combine
import Foundation
import UIKit

/// Kiosk mode on iOS is a stack of four controls, and only one of them is an API call:
///
/// 1. **Single-app lock.** `UIAccessibility.requestGuidedAccessSession(enabled: true)` locks
///    the device into this app — but only if Guided Access is switched on in Settings, and
///    the user can still leave with the passcode. On a supervised device, MDM Autonomous
///    Single App Mode is the stronger version (no triple-click escape at all). An app cannot
///    make itself unquittable.
/// 2. **Display.** A brightness floor plus the idle-timer override. There is no API that
///    powers the panel down; see Docs/KIOSK-MODE.md for why zero brightness and a visible
///    watermark cannot both be true.
/// 3. **Radios.** Not controllable — monitored by `RadioMonitor`, enforced as a
///    precondition, and recorded when it changes.
/// 4. **Watermark.** On screen always; optionally burned into each file by
///    `WatermarkComposer` before the hash is taken, so the stamp and the evidence agree.
@MainActor
final class KioskController: ObservableObject {

    /// Two defensible answers to "zero brightness", named so the trade-off is visible
    /// at the call site instead of buried in a constant.
    enum DimLevel {
        /// Nothing is readable. Saves the last ~0.15 W and makes the watermark pointless.
        case dark
        /// Readable in a dim room. The default, because a watermark you cannot see is
        /// just a black rectangle.
        case watermark

        var value: CGFloat {
            switch self {
            case .dark:      return 0.0
            case .watermark: return 0.04
            }
        }
    }

    @Published private(set) var isGuidedAccessActive = false
    @Published private(set) var status = KioskStatus()
    @Published private(set) var radios = RadioMonitor.State()
    @Published private(set) var lastError: String?
    /// Set when a network path appears mid-session. On a kiosk that is an anomaly, not a
    /// convenience: something changed that nobody should have changed.
    @Published private(set) var radioAnomaly: String?

    private let radioMonitor = RadioMonitor()
    private var savedBrightness: CGFloat?
    private var savedIdleTimerState = false
    private var guidedAccessObserver: NSObjectProtocol?
    private var isEngaged = false

    init() {
        // The observer lives for the process lifetime: this controller is created once and
        // held by the view model, so there is nothing to tear down and no `deinit` reaching
        // across the main actor to worry about.
        guidedAccessObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    // MARK: - Engage / disengage

    func enter(dim: DimLevel = .watermark) {
        guard !isEngaged else { return }
        isEngaged = true

        savedBrightness = UIScreen.main.brightness
        savedIdleTimerState = UIApplication.shared.isIdleTimerDisabled
        UIScreen.main.brightness = dim.value
        UIApplication.shared.isIdleTimerDisabled = true

        radioMonitor.onChange = { [weak self] state in
            Task { @MainActor in self?.handleRadioChange(state) }
        }
        radioMonitor.start()

        requestGuidedAccess(true)
        refreshStatus()
    }

    func exit() {
        guard isEngaged else { return }
        isEngaged = false

        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
            self.savedBrightness = nil
        }
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimerState

        if isGuidedAccessActive {
            requestGuidedAccess(false)
        }
        radioMonitor.stop()
        radios = RadioMonitor.State()
        // Guided Access ends asynchronously; do not claim it is still active.
        isGuidedAccessActive = false
        refreshStatus()
    }

    // MARK: - Status

    func refreshStatus(isRecording: Bool = false) {
        var next = KioskStatus()
        next.guidedAccessActive = isGuidedAccessActive
        next.brightness = Double(UIScreen.main.brightness)
        next.idleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        next.radiosSilent = radios.isSilent
        next.charging = PowerGovernor.isCharging()
        next.thermal = PowerGovernor.currentThermalLevel()
        next.battery = PowerGovernor.currentBatteryFraction()
        next.isRecording = isRecording
        status = next
    }

    // MARK: - Guided Access

    private func requestGuidedAccess(_ enabled: Bool) {
        UIAccessibility.requestGuidedAccessSession(enabled: enabled) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if enabled {
                    self.isGuidedAccessActive = success
                    if !success {
                        self.lastError = """
                        Guided Access refused. Turn it on in Settings ▸ Accessibility ▸ \
                        Guided Access, then try again — without it a single swipe ends the \
                        session. On a supervised device, prefer MDM single-app mode.
                        """
                    }
                } else {
                    self.isGuidedAccessActive = false
                }
                self.refreshStatus()
            }
        }
    }

    // MARK: - Radios

    private func handleRadioChange(_ state: RadioMonitor.State) {
        radios = state
        if state.hasPath, isEngaged {
            let line = "\(TelemetryFormat.timestamp(Date())) network path came up (\(state.description))"
            radioAnomaly = line
            Log.power.notice("kiosk radio anomaly: \(state.description, privacy: .public)")
        }
        refreshStatus()
    }
}

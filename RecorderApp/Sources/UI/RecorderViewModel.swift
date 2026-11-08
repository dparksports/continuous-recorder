import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Bridges the recorder to SwiftUI. Deliberately thin: no audio code here, only
/// formatting, the 1 Hz display tick, and the two settings objects the audio thread reads.
@MainActor
final class RecorderViewModel: ObservableObject {

    // MARK: - Live state

    @Published private(set) var isRecording = false
    @Published private(set) var isCapturing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var audioSeconds: Double = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var bytesOnDisk: Int64 = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var coverage = CoverageSummary()
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var batteryFraction: Double?
    @Published private(set) var batteryCharging = false
    @Published private(set) var thermal: PowerGovernor.ThermalLevel = .nominal
    @Published private(set) var lowPowerMode = false
    @Published private(set) var observedWatts: Double?
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var lastError: String?
    @Published private(set) var lastSegment: SegmentRecord?

    // MARK: - Settings (persisted; applied at the next segment boundary)

    @Published var preset: RecordingProfile.Preset = .speech {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset)
            publishProfile()
        }
    }

    @Published var segmentMinutes: Int = 5 {
        didSet {
            UserDefaults.standard.set(segmentMinutes, forKey: Keys.segmentMinutes)
            publishProfile()
        }
    }

    @Published var deviceID: String = EnergyModel.devices[0].id {
        didSet { UserDefaults.standard.set(deviceID, forKey: Keys.deviceID) }
    }

    @Published var autoStopBatteryPercent: Int = 10 {
        didSet {
            UserDefaults.standard.set(autoStopBatteryPercent, forKey: Keys.autoStop)
            var governor = governorBox.current
            governor.limits.stopBelowBatteryFraction = Double(autoStopBatteryPercent) / 100
            governorBox.set(governor)
        }
    }

    private enum Keys {
        static let preset = "preset"
        static let segmentMinutes = "segmentMinutes"
        static let deviceID = "deviceID"
        static let autoStop = "autoStopBatteryPercent"
    }

    // MARK: - Internals

    private let recorder = SegmentedRecorder()
    private let governorBox = Locked(PowerGovernor())
    private let profileBox = Locked(RecordingProfile.default)
    private let meterBox = Locked(EnergyModel.PowerMeter())

    private var ticker: Timer?
    private var uiActive = true

    init() {
        let defaults = UserDefaults.standard
        preset = RecordingProfile.Preset(rawValue: defaults.string(forKey: Keys.preset) ?? "") ?? .speech
        segmentMinutes = max(1, defaults.object(forKey: Keys.segmentMinutes) as? Int ?? 5)
        deviceID = defaults.string(forKey: Keys.deviceID) ?? EnergyModel.devices[0].id
        autoStopBatteryPercent = defaults.object(forKey: Keys.autoStop) as? Int ?? 10

        var governor = PowerGovernor()
        governor.limits.stopBelowBatteryFraction = Double(autoStopBatteryPercent) / 100
        governorBox.set(governor)
        publishProfile()

        recorder.profileProvider = { [profileBox] in profileBox.current }
        recorder.policy = { [governorBox] inputs, profile in
            governorBox.current.decision(for: inputs, profile: profile)
        }
        recorder.onSegmentClosed = { [weak self] record in
            Task { @MainActor in self?.absorb(record) }
        }
        recorder.onGapRecorded = { [weak self] gap in
            Task { @MainActor in self?.absorb(gap) }
        }
        recorder.onAutoStop = { [weak self] reason in
            Task { @MainActor in self?.statusMessage = "Auto-stopped: \(reason)" }
        }

        // `applicationWillTerminate` is the last chance to finalise the open .m4a.
        // Force-quitting from the app switcher skips it, which is why segments are short
        // and the manifest is append-only.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recorder.stop(reason: "appTerminating")
            }
        }

        refreshEnvironment()
        refresh()
    }

    // MARK: - Commands

    func toggle() {
        if isRecording {
            stop(reason: "user")
        } else {
            start()
        }
    }

    func start() {
        do {
            try recorder.start()
            isRecording = true
            lastError = nil
            statusMessage = "Recording"
            var freshMeter = EnergyModel.PowerMeter()
            freshMeter.reset(fraction: PowerGovernor.currentBatteryFraction())
            meterBox.set(freshMeter)
            startTicker()
            refresh()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not start"
            Log.app.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop(reason: String) {
        recorder.stop(reason: reason)
        isRecording = false
        isCapturing = false
        stopTicker()
        statusMessage = reason == "user" ? "Stopped" : "Stopped (\(reason))"
        refresh()
    }

    /// The display tick costs power too, so it only runs while the UI is actually visible.
    func setUIActive(_ active: Bool) {
        uiActive = active
        if active, isRecording {
            startTicker()
            refresh()
        } else {
            stopTicker()
        }
    }

    // MARK: - Derived display values

    var elapsedText: String { Self.hms(elapsed) }

    var device: EnergyModel.Device { EnergyModel.device(id: deviceID) }

    var currentProfile: RecordingProfile {
        RecordingProfile.make(
            preset: preset,
            segmentDuration: TimeInterval(max(1, segmentMinutes) * 60)
        )
    }

    var bytesPerHour: Int64 {
        currentProfile.bytesPerHour(channels: max(1, lastSegment?.channels ?? 1))
    }

    var storageDays: Double? {
        guard let freeBytes, bytesPerHour > 0 else { return nil }
        return Double(freeBytes) / Double(bytesPerHour) / 24
    }

    /// Measured draw when there is one, otherwise the planning constant.
    var projectedHours: Double? {
        guard isRecording, let fraction = batteryFraction else { return nil }
        let floor = governorBox.current.limits.stopBelowBatteryFraction
        let usable = device.wattHours * max(0, fraction - floor)
        let watts = observedWatts ?? EnergyModel.nominalWatts(for: currentProfile)
        return EnergyModel.hours(wattHours: usable, averageWatts: watts)
    }

    var capacityText: String {
        String(format: "%.2f Wh", device.wattHours)
    }

    var coverageText: String {
        coverage.wallSeconds > 0 ? String(format: "%.3f %%", coverage.ratio * 100) : "—"
    }

    var observedWattsText: String {
        guard let observedWatts else { return "measuring…" }
        return String(format: "%.2f W", observedWatts)
    }

    var projectedText: String {
        guard let projectedHours else { return "—" }
        return Self.hoursText(projectedHours)
    }

    // MARK: - Ticker

    private func startTicker() {
        guard uiActive else { return }
        stopTicker()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.25  // tolerance is free battery
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        let snapshot = recorder.snapshot()
        isRecording = snapshot.isRunning
        isCapturing = snapshot.isCapturing
        elapsed = snapshot.elapsed
        audioSeconds = snapshot.audioSeconds
        segmentCount = snapshot.segmentsClosed
        bytesOnDisk = snapshot.bytesOnDisk
        level = snapshot.level
        if let error = snapshot.lastError { lastError = error }
        coverage = recorder.coverageSummary()
        refreshEnvironment()
        updateMeter()
    }

    private func refreshEnvironment() {
        batteryFraction = PowerGovernor.currentBatteryFraction()
        batteryCharging = PowerGovernor.isCharging()
        thermal = PowerGovernor.currentThermalLevel()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        freeBytes = recorder.freeBytes()
    }

    private func updateMeter() {
        var meter = meterBox.current
        if batteryCharging {
            meter.rebaseline(fraction: batteryFraction)
            observedWatts = nil
        } else {
            if !meter.hasBaseline { meter.reset(fraction: batteryFraction) }
            observedWatts = meter.observedWatts(
                deviceWattHours: device.wattHours,
                fraction: batteryFraction
            )
        }
        meterBox.set(meter)
    }

    private func absorb(_ record: SegmentRecord) {
        lastSegment = record
        refresh()
    }

    private func absorb(_ gap: GapRecord) {
        Log.app.notice("gap recorded: \(gap.reason, privacy: .public) \(gap.seconds, format: .fixed(precision: 2))s")
        refresh()
    }

    private func publishProfile() {
        profileBox.set(currentProfile)
    }

    // MARK: - Formatting

    static func hms(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func hoursText(_ hours: Double) -> String {
        if hours >= 48 {
            return String(format: "%.1f days", hours / 24)
        }
        return String(format: "%.1f h", hours)
    }

    static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

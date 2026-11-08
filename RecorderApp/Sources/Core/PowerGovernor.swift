import Foundation
import UIKit

/// Decides whether the recorder may continue, and at what quality.
///
/// This runs once per segment boundary — not once per second — because polling the
/// battery and the filesystem costs more than it saves. `decision(for:profile:)` is a
/// pure function so the policy is unit-testable without a device.
struct PowerGovernor {

    struct Limits {
        /// Stop before the hardware dies. 10% roughly matches iOS's own low-power cutoff.
        var stopBelowBatteryFraction: Double = 0.10
        /// Do not stop for battery below this if the device is on power.
        var warnBelowBatteryFraction: Double = 0.20
        /// Leave this much free space so a write never fails mid-segment.
        var minimumFreeBytes: Int64 = 2_000_000_000
        var downgradeInLowPowerMode: Bool = true
        var stopOnSeriousThermal: Bool = false
    }

    enum ThermalLevel: Int, Comparable {
        case nominal = 0
        case fair
        case serious
        case critical

        static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var displayName: String {
            switch self {
            case .nominal:  return "Nominal"
            case .fair:     return "Fair"
            case .serious:  return "Serious"
            case .critical: return "Critical"
            }
        }
    }

    enum Decision: Equatable {
        case keep
        case downgrade(RecordingProfile.Preset)
        case stop(String)
    }

    struct Inputs {
        var batteryFraction: Double?
        var isCharging: Bool = false
        var thermal: ThermalLevel = .nominal
        var lowPowerMode: Bool = false
        var freeBytes: Int64?
    }

    var limits = Limits()

    func decision(for inputs: Inputs, profile: RecordingProfile) -> Decision {
        if let free = inputs.freeBytes, free < limits.minimumFreeBytes {
            let formatted = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return .stop("Storage almost full — \(formatted) free")
        }

        if inputs.thermal == .critical {
            return .stop("Device temperature critical")
        }

        if inputs.thermal == .serious, limits.stopOnSeriousThermal {
            return .stop("Device temperature serious")
        }

        if let battery = inputs.batteryFraction,
           !inputs.isCharging,
           battery <= limits.stopBelowBatteryFraction {
            return .stop("Battery at \(Int((battery * 100).rounded()))%")
        }

        let wantsLessPower = (inputs.lowPowerMode && limits.downgradeInLowPowerMode)
            || inputs.thermal >= .serious

        if wantsLessPower, profile.codec != .pcm, profile.preset != .speech {
            return .downgrade(.speech)
        }

        return .keep
    }

    // MARK: - Device readers (not used by the pure policy)

    static func currentBatteryFraction() -> Double? {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    static func isCharging() -> Bool {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        switch device.batteryState {
        case .charging, .full: return true
        default: return false
        }
    }

    static func currentThermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func currentInputs(freeBytes: Int64?) -> Inputs {
        Inputs(
            batteryFraction: currentBatteryFraction(),
            isCharging: isCharging(),
            thermal: currentThermalLevel(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            freeBytes: freeBytes
        )
    }
}

import Foundation

/// Pure arithmetic for "how long will this run" and "how much disk will it eat".
/// No UIKit, no I/O: everything here is testable on a Mac without a device.
enum EnergyModel {

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let wattHours: Double
    }

    /// Apple's published design capacities. `Tools/runtime_estimate.py` carries the
    /// same table; keep them in sync if you add hardware.
    static let devices: [Device] = [
        Device(id: "ipad-air-11",   name: "iPad Air 11″ (M2/M3)",     wattHours: 28.93),
        Device(id: "ipad-air-13",   name: "iPad Air 13″ (M2/M3)",     wattHours: 36.59),
        Device(id: "ipad-air-10.9", name: "iPad Air 10.9″ (4/5)",     wattHours: 28.60),
        Device(id: "ipad-pro-11",   name: "iPad Pro 11″ (M4)",        wattHours: 31.29),
        Device(id: "ipad-pro-13",   name: "iPad Pro 13″ (M4)",        wattHours: 38.99),
        Device(id: "iphone-15",     name: "iPhone 15/16 (approx.)",   wattHours: 13.00)
    ]

    static func device(id: String) -> Device {
        devices.first { $0.id == id } ?? devices[0]
    }

    /// Energy you are allowed to spend before the device dies. Default keeps 10% in
    /// reserve so the OS can shut down cleanly instead of yanking power mid-write.
    static func usableWattHours(deviceWattHours: Double, reserveFraction: Double = 0.10) -> Double {
        let reserve = min(max(reserveFraction, 0), 0.9)
        return max(0, deviceWattHours * (1 - reserve))
    }

    static func hours(wattHours: Double, averageWatts: Double) -> Double? {
        guard averageWatts > 0.02 else { return nil }
        return wattHours / averageWatts
    }

    static func days(hours: Double) -> Double { hours / 24 }

    /// Planning draw used before the app has measured anything real.
    /// Derived in `Tools/runtime_estimate.py`: SoC idle + mic front end + AAC encode,
    /// screen off, Wi-Fi off. Deliberately pessimistic-ish, not optimistic.
    static func nominalWatts(for profile: RecordingProfile) -> Double {
        switch profile.codec {
        case .aac:  return 0.22
        case .alac: return 0.28
        case .pcm:  return 0.32
        }
    }

    /// Battery percentage only moves in 1% steps, which sets a floor on how fast the
    /// meter can produce a trustworthy number.
    struct PowerMeter {
        private var anchorFraction: Double?
        private var anchorDate: Date?

        mutating func reset(fraction: Double?, at date: Date = Date()) {
            anchorFraction = fraction
            anchorDate = date
        }

        mutating func rebaseline(fraction: Double?, at date: Date = Date()) {
            reset(fraction: fraction, at: date)
        }

        /// Returns nil until the drop is large enough to be signal rather than rounding:
        /// at least 2 percentage points over at least 10 minutes.
        func observedWatts(deviceWattHours: Double, fraction: Double?, at date: Date = Date()) -> Double? {
            guard let startFraction = anchorFraction,
                  let startDate = anchorDate,
                  let nowFraction = fraction else { return nil }

            let elapsed = date.timeIntervalSince(startDate)
            let drop = startFraction - nowFraction
            guard elapsed >= 600, drop >= 0.02 else { return nil }

            let usedWattHours = deviceWattHours * drop
            return usedWattHours / (elapsed / 3600)
        }

        var hasBaseline: Bool { anchorFraction != nil }
    }
}

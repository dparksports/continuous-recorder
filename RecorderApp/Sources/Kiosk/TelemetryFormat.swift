import CoreGraphics
import Foundation

/// The text that gets stamped on screen and, optionally, burned into the recording.
///
/// Plain text, not icons: a bolt glyph survives downscaling and re-encoding badly, while
/// `CHARGING` survives both. If the watermark is only ever seen on a 264 ppi screen this
/// does not matter — but the version that survives compression is the one worth writing.
enum TelemetryFormat {

    /// `2026-11-07 14:32:08 · 82% · CHARGING`
    static func line(date: Date,
                     battery: Double?,
                     charging: Bool,
                     timeZone: TimeZone = .current) -> String {
        "\(timestamp(date, timeZone: timeZone)) · \(batteryText(battery)) · \(powerStateText(charging))"
    }

    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func batteryText(_ battery: Double?) -> String {
        guard let battery else { return "--" }
        return "\(Int((battery * 100).rounded()))%"
    }

    static func powerStateText(_ charging: Bool) -> String {
        charging ? "CHARGING" : "ON BATTERY"
    }

    /// A permanently static bright element is a bad idea on a panel that runs for weeks.
    /// The watermark drifts by a few points every twenty minutes, which is invisible to a
    /// person and enough to stop one row of pixels from being lit forever. It also makes a
    /// frozen frame obvious: a still watermark in a "live" feed is a splice.
    static func drift(at date: Date, amplitude: CGFloat = 6) -> CGSize {
        let step = Int(date.timeIntervalSince1970 / 1200) // 20 minutes
        let horizontal = CGFloat((step % 3) - 1) * amplitude
        let vertical = CGFloat(((step / 3) % 3) - 1) * (amplitude / 2)
        return CGSize(width: horizontal, height: vertical)
    }
}

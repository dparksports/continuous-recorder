import Foundation

/// What a healthy kiosk looks like, expressed as data rather than as prose in a runbook.
/// The rules are pure, so they can be tested without a device — the device readers live in
/// `KioskController`.
struct KioskStatus: Equatable {
    var guidedAccessActive = false
    var brightness: Double = 1.0
    var idleTimerDisabled = false
    var radiosSilent = false
    var charging = false
    var thermal: PowerGovernor.ThermalLevel = .nominal
    var battery: Double?
    var isRecording = false

    var issues: [String] { KioskPolicy.issues(for: self) }
    var isCompliant: Bool { issues.isEmpty }
}

enum KioskPolicy {

    /// Brightness ceiling for a kiosk. Zero is darker but makes the watermark unreadable,
    /// which defeats the point of having one — see Docs/KIOSK-MODE.md.
    static let brightnessCeiling = 0.08

    static func issues(for status: KioskStatus) -> [String] {
        var issues: [String] = []

        if !status.guidedAccessActive {
            issues.append("Guided Access is not active — one swipe ends the session")
        }
        if !status.idleTimerDisabled {
            issues.append("Auto-lock is on — the display will sleep and capture will stop")
        }
        if status.brightness > brightnessCeiling {
            issues.append(String(format: "Brightness is %.0f%% — above the %.0f%% kiosk ceiling",
                                 status.brightness * 100, brightnessCeiling * 100))
        }
        if !status.radiosSilent {
            issues.append("A network path is up — Airplane Mode is required for a quiet device")
        }
        if !status.charging {
            issues.append("Running on battery — an unattended kiosk should be on mains")
        }
        if status.thermal >= .serious {
            issues.append("Thermal state is \(status.thermal.displayName) — the encoder is throttling")
        }
        if !status.isRecording {
            issues.append("Not recording")
        }
        return issues
    }
}

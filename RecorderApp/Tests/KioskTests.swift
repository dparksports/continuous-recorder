import CoreGraphics
import XCTest
@testable import RecorderApp

final class TelemetryFormatTests: XCTestCase {

    private let utc = TimeZone(secondsFromGMT: 0)!

    func testLineIsExact() {
        // 1_700_000_000 == 2023-11-14 22:13:20 UTC
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            TelemetryFormat.line(date: date, battery: 0.82, charging: true, timeZone: utc),
            "2023-11-14 22:13:20 · 82% · CHARGING"
        )
    }

    func testOnBatteryReadsDifferentlyFromCharging() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let line = TelemetryFormat.line(date: date, battery: 0.05, charging: false, timeZone: utc)
        XCTAssertEqual(line, "2023-11-14 22:13:20 · 5% · ON BATTERY")
    }

    func testUnknownBatteryDoesNotFakeANumber() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            TelemetryFormat.line(date: date, battery: nil, charging: false, timeZone: utc),
            "2023-11-14 22:13:20 · -- · ON BATTERY"
        )
    }

    func testDriftIsStableWithinItsBucket() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let start = TelemetryFormat.drift(at: base, amplitude: 6)
        let ninetySecondsLater = TelemetryFormat.drift(at: base.addingTimeInterval(90), amplitude: 6)
        XCTAssertEqual(start, ninetySecondsLater, "drift must not jitter at the tick rate")
        XCTAssertLessThanOrEqual(abs(start.width), 6)
        XCTAssertLessThanOrEqual(abs(start.height), 3)
    }

    func testDriftActuallyMovesOverHours() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var positions = Set<String>()
        for hour in 0..<8 {
            let point = TelemetryFormat.drift(at: base.addingTimeInterval(Double(hour) * 3600),
                                              amplitude: 6)
            positions.insert("\(point.width)×\(point.height)")
        }
        XCTAssertGreaterThan(positions.count, 1, "a permanently static stamp burns into the panel")
    }
}

final class KioskPolicyTests: XCTestCase {

    private var healthy: KioskStatus {
        var status = KioskStatus()
        status.guidedAccessActive = true
        status.brightness = 0.04
        status.idleTimerDisabled = true
        status.radiosSilent = true
        status.charging = true
        status.thermal = .nominal
        status.isRecording = true
        return status
    }

    func testHealthyKioskHasNoIssues() {
        XCTAssertTrue(KioskPolicy.issues(for: healthy).isEmpty,
                      "got \(KioskPolicy.issues(for: healthy))")
    }

    func testLostGuidedAccessIsReported() {
        var status = healthy
        status.guidedAccessActive = false
        XCTAssertTrue(KioskPolicy.issues(for: status).contains { $0.contains("Guided Access") })
    }

    func testBrightnessAboveCeilingIsReported() {
        var status = healthy
        status.brightness = 0.6
        let issues = KioskPolicy.issues(for: status)
        XCTAssertTrue(issues.contains { $0.contains("Brightness") }, "got \(issues)")
    }

    func testZeroBrightnessPassesPolicy() {
        // Zero is within the ceiling even though it makes the watermark unreadable; that
        // trade-off is a product decision documented in Docs/KIOSK-MODE.md, not a policy
        // violation.
        var status = healthy
        status.brightness = 0
        XCTAssertTrue(KioskPolicy.issues(for: status).isEmpty)
    }

    func testRadioPathIsAnAnomalyForAKiosk() {
        var status = healthy
        status.radiosSilent = false
        XCTAssertTrue(KioskPolicy.issues(for: status).contains { $0.contains("network path") })
    }

    func testBatteryPowerIsReported() {
        var status = healthy
        status.charging = false
        XCTAssertTrue(KioskPolicy.issues(for: status).contains { $0.contains("mains") })
    }

    func testThermalAndRecordingAreReported() {
        var status = healthy
        status.thermal = .critical
        status.isRecording = false
        let issues = KioskPolicy.issues(for: status)
        XCTAssertTrue(issues.contains { $0.contains("Thermal") }, "got \(issues)")
        XCTAssertTrue(issues.contains { $0.contains("Not recording") }, "got \(issues)")
    }
}

import XCTest
@testable import RecorderApp

final class CoverageTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func segment(index: Int, startOffset: Double, duration: Double) -> SegmentRecord {
        SegmentRecord(
            id: UUID(),
            index: index,
            fileName: "seg-\(index).m4a",
            startedAt: start.addingTimeInterval(startOffset),
            endedAt: start.addingTimeInterval(startOffset + duration),
            frames: Int64(duration * 48_000),
            sampleRate: 48_000,
            channels: 1,
            bitRate: 48_000,
            codec: "aac",
            byteSize: Int64(duration * 6_000),
            gapBeforeSeconds: 0,
            endReason: "rotation"
        )
    }

    func testBackToBackSegmentsAreFullCoverage() {
        let summary = CoverageSummary.compute(
            segments: [segment(index: 1, startOffset: 0, duration: 300),
                       segment(index: 2, startOffset: 300, duration: 300)],
            gaps: []
        )
        XCTAssertEqual(summary.wallSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(summary.audioSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(summary.ratio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.unexplainedSeconds, 0, accuracy: 0.001)
    }

    func testInterruptionShowsUpAsGapAndIsExplained() {
        let gap = GapRecord(
            id: UUID(),
            startedAt: start.addingTimeInterval(300),
            endedAt: start.addingTimeInterval(312),
            reason: "interruption"
        )
        let summary = CoverageSummary.compute(
            segments: [segment(index: 1, startOffset: 0, duration: 300),
                       segment(index: 2, startOffset: 312, duration: 288)],
            gaps: [gap]
        )
        XCTAssertEqual(summary.wallSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(summary.gapSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(summary.ratio, 0.98, accuracy: 0.0001)
        XCTAssertEqual(summary.unexplainedSeconds, 0, accuracy: 0.001)
    }

    func testMissingAudioWithoutGapRecordIsVisible() {
        // Second segment starts late but nothing recorded why: that must show up as
        // unexplained, not silently vanish.
        let summary = CoverageSummary.compute(
            segments: [segment(index: 1, startOffset: 0, duration: 300),
                       segment(index: 2, startOffset: 330, duration: 270)],
            gaps: []
        )
        XCTAssertEqual(summary.gapCount, 0)
        XCTAssertEqual(summary.unexplainedSeconds, 30, accuracy: 0.001)
        XCTAssertLessThan(summary.ratio, 1.0)
    }

    func testEmptySessionIsHarmless() {
        let summary = CoverageSummary.compute(segments: [], gaps: [])
        XCTAssertEqual(summary.ratio, 0)
        XCTAssertEqual(summary.wallSeconds, 0)
    }
}

final class PowerGovernorTests: XCTestCase {

    private let profile = RecordingProfile.make(preset: .high, segmentDuration: 300)

    func testStopsBeforeBatteryDies() {
        var inputs = PowerGovernor.Inputs()
        inputs.batteryFraction = 0.06
        inputs.freeBytes = 50_000_000_000

        let decision = PowerGovernor().decision(for: inputs, profile: profile)
        guard case .stop = decision else {
            return XCTFail("expected stop, got \(decision)")
        }
    }

    func testKeepsGoingOnPowerEvenWithLowBattery() {
        var inputs = PowerGovernor.Inputs()
        inputs.batteryFraction = 0.06
        inputs.isCharging = true
        inputs.freeBytes = 50_000_000_000

        XCTAssertEqual(PowerGovernor().decision(for: inputs, profile: profile), .keep)
    }

    func testDowngradesInLowPowerMode() {
        var inputs = PowerGovernor.Inputs()
        inputs.batteryFraction = 0.55
        inputs.lowPowerMode = true
        inputs.freeBytes = 50_000_000_000

        XCTAssertEqual(PowerGovernor().decision(for: inputs, profile: profile), .downgrade(.speech))
    }

    func testDoesNotDowngradeAnAlreadyCheapProfile() {
        var inputs = PowerGovernor.Inputs()
        inputs.batteryFraction = 0.55
        inputs.lowPowerMode = true
        inputs.freeBytes = 50_000_000_000

        let speech = RecordingProfile.make(preset: .speech, segmentDuration: 300)
        XCTAssertEqual(PowerGovernor().decision(for: inputs, profile: speech), .keep)
    }

    func testStopsWhenDiskIsNearlyFull() {
        var inputs = PowerGovernor.Inputs()
        inputs.batteryFraction = 0.90
        inputs.freeBytes = 900_000_000

        let decision = PowerGovernor().decision(for: inputs, profile: profile)
        guard case .stop = decision else {
            return XCTFail("expected stop, got \(decision)")
        }
    }

    func testStopsOnCriticalThermalState() {
        var inputs = PowerGovernor.Inputs()
        inputs.batteryFraction = 0.90
        inputs.freeBytes = 50_000_000_000
        inputs.thermal = .critical

        let decision = PowerGovernor().decision(for: inputs, profile: profile)
        guard case .stop = decision else {
            return XCTFail("expected stop, got \(decision)")
        }
    }
}

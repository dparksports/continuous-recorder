import XCTest
@testable import RecorderApp

final class EnergyModelTests: XCTestCase {

    func testUsableCapacityKeepsReserve() {
        let usable = EnergyModel.usableWattHours(deviceWattHours: 28.93, reserveFraction: 0.10)
        XCTAssertEqual(usable, 26.037, accuracy: 0.001)
    }

    func testHoursAtPlannedDraw() throws {
        let hours = try XCTUnwrap(EnergyModel.hours(wattHours: 26.037, averageWatts: 0.32))
        XCTAssertEqual(hours, 81.4, accuracy: 0.5)
    }

    func testHoursRejectsNonsenseDraw() {
        XCTAssertNil(EnergyModel.hours(wattHours: 26.037, averageWatts: 0))
        XCTAssertNil(EnergyModel.hours(wattHours: 26.037, averageWatts: 0.001))
    }

    func testBytesPerHourForAAC() {
        let profile = RecordingProfile.make(preset: .speech, segmentDuration: 300)
        // 48 kbps mono = 6 kB/s = 21.6 MB/h
        XCTAssertEqual(profile.bytesPerHour(channels: 1), 21_600_000)
        XCTAssertEqual(profile.bytesPerHour(channels: 2), 43_200_000)
    }

    func testBytesPerHourForPCM() {
        let profile = RecordingProfile.make(preset: .pcm, segmentDuration: 300)
        // 48 kHz × 16 bit × 1 ch × 3600 s
        XCTAssertEqual(profile.bytesPerHour(channels: 1), 345_600_000)
    }

    func testPowerMeterNeedsEnoughSignal() {
        var meter = EnergyModel.PowerMeter()
        let start = Date(timeIntervalSince1970: 0)
        meter.reset(fraction: 0.80, at: start)

        // Only 1% over an hour: still inside rounding noise.
        XCTAssertNil(meter.observedWatts(deviceWattHours: 28.93,
                                         fraction: 0.79,
                                         at: start.addingTimeInterval(3600)))

        // 5% over 3 hours: 1.4465 Wh / 3 h ≈ 0.48 W
        let watts = meter.observedWatts(deviceWattHours: 28.93,
                                        fraction: 0.75,
                                        at: start.addingTimeInterval(3 * 3600))
        XCTAssertEqual(try XCTUnwrap(watts), 0.482, accuracy: 0.005)
    }
}

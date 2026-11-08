import XCTest
@testable import RecorderApp

final class AudioTriggerAnalyzerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// 4096 frames at 48 kHz — one buffer of the capture tap.
    private let bufferInterval: TimeInterval = 4096.0 / 48_000.0

    /// Feeds `count` buffers at a fixed level and returns every transition it produced.
    private func feed(_ analyzer: inout AudioTriggerAnalyzer,
                      level: Double,
                      from start: Double,
                      count: Int) -> [(Double, AudioTriggerAnalyzer.Transition)] {
        var results: [(Double, AudioTriggerAnalyzer.Transition)] = []
        for index in 0..<count {
            let offset = start + Double(index) * bufferInterval
            if let transition = analyzer.ingest(levelDB: level, at: t0.addingTimeInterval(offset)) {
                results.append((offset, transition))
            }
        }
        return results
    }

    private func seconds(_ count: Int) -> Double { Double(count) * bufferInterval }

    func testAQuietRoomNeverTriggers() {
        var analyzer = AudioTriggerAnalyzer()
        let transitions = feed(&analyzer, level: -62, from: 0, count: 600) // ~51 s
        XCTAssertTrue(transitions.isEmpty)
        XCTAssertFalse(analyzer.isOpen)
        XCTAssertEqual(analyzer.noiseFloorDB ?? -999, -62, accuracy: 0.5)
    }

    func testASustainedSoundOpensTheEvent() throws {
        var analyzer = AudioTriggerAnalyzer()
        _ = feed(&analyzer, level: -60, from: 0, count: 40)   // settle the floor

        let transitions = feed(&analyzer, level: -35, from: seconds(40), count: 10)
        let opened = try XCTUnwrap(transitions.first)
        guard case .opened(let level, let floor) = opened.1 else {
            return XCTFail("expected an open, got \(opened.1)")
        }
        XCTAssertEqual(level, -35, accuracy: 0.001)
        XCTAssertEqual(floor, -60, accuracy: 1.0)
        XCTAssertTrue(analyzer.isOpen)
    }

    func testASingleBangDoesNotOpenAnEvent() {
        var analyzer = AudioTriggerAnalyzer()
        _ = feed(&analyzer, level: -60, from: 0, count: 40)

        // One buffer (~85 ms) is below the 150 ms hold.
        var transitions = feed(&analyzer, level: -20, from: seconds(40), count: 1)
        transitions += feed(&analyzer, level: -60, from: seconds(41), count: 5)

        XCTAssertTrue(transitions.isEmpty)
        XCTAssertFalse(analyzer.isOpen)
    }

    func testQuietForFiveSecondsClosesTheEvent() throws {
        var analyzer = AudioTriggerAnalyzer()
        _ = feed(&analyzer, level: -60, from: 0, count: 40)
        _ = feed(&analyzer, level: -35, from: seconds(40), count: 20)
        XCTAssertTrue(analyzer.isOpen)

        // A pause shorter than the close hold must not close it.
        let shortPause = feed(&analyzer, level: -60, from: seconds(60), count: 30) // ~2.6 s
        XCTAssertTrue(shortPause.isEmpty)

        let transitions = feed(&analyzer, level: -60, from: seconds(90), count: 120) // ~10 s
        let closed = try XCTUnwrap(transitions.first)
        guard case .closed(let peak, let duration) = closed.1 else {
            return XCTFail("expected a close, got \(closed.1)")
        }
        XCTAssertEqual(peak, -35, accuracy: 0.001)
        XCTAssertGreaterThan(duration, 4)
        XCTAssertFalse(analyzer.isOpen)
    }

    func testANoisyRoomDoesNotDefeatTheTrigger() throws {
        // The point of the adaptive floor: this room sits at -34 dBFS, which is above any
        // fixed threshold you would sensibly pick, so a fixed design never goes dormant.
        var analyzer = AudioTriggerAnalyzer()
        let room = feed(&analyzer, level: -34, from: 0, count: 120)
        XCTAssertTrue(room.isEmpty, "a steady room must not look like an event")
        XCTAssertFalse(analyzer.isOpen)
        XCTAssertEqual(analyzer.noiseFloorDB ?? -999, -34, accuracy: 0.5)

        // A door closing 15 dB above that room still opens it.
        let transitions = feed(&analyzer, level: -19, from: seconds(120), count: 10)
        XCTAssertFalse(transitions.isEmpty)
        XCTAssertTrue(analyzer.isOpen)
    }

    func testTheFloorDoesNotChaseALoudEvent() {
        var analyzer = AudioTriggerAnalyzer()
        _ = feed(&analyzer, level: -60, from: 0, count: 40)
        _ = feed(&analyzer, level: -20, from: seconds(40), count: 600) // ~51 s of noise
        XCTAssertTrue(analyzer.isOpen)
        XCTAssertEqual(analyzer.noiseFloorDB ?? -999, -60, accuracy: 1.0,
                       "an alarm must not teach the analyser that loud is the new normal")
    }

    func testResetClosesAnOpenEvent() {
        var analyzer = AudioTriggerAnalyzer()
        _ = feed(&analyzer, level: -60, from: 0, count: 40)
        _ = feed(&analyzer, level: -30, from: seconds(40), count: 10)
        XCTAssertTrue(analyzer.isOpen)

        analyzer.reset()
        XCTAssertFalse(analyzer.isOpen)
    }
}

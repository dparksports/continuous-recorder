import XCTest
@testable import RecorderApp

final class MotionClassifierTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let upright = Vector3(x: 0, y: -1, z: 0)

    private func sample(_ offset: Double,
                        acceleration: Double = 0,
                        rotation: Double = 0,
                        gravity: Vector3? = nil) -> MotionSample {
        MotionSample(at: t0.addingTimeInterval(offset),
                     acceleration: acceleration,
                     rotation: rotation,
                     gravity: gravity ?? upright)
    }

    private func runToSettle(_ classifier: inout MotionClassifier,
                             from start: Double,
                             to end: Double,
                             gravity: Vector3? = nil) -> MotionEvent? {
        var index = start
        while index <= end {
            if case .ended(let event)? = classifier.ingest(sample(index, gravity: gravity)) {
                return event
            }
            index += 0.1
        }
        return nil
    }

    func testStillSamplesProduceNothing() {
        var classifier = MotionClassifier()
        for step in 0..<50 {
            XCTAssertNil(classifier.ingest(sample(Double(step) * 0.1)))
        }
        XCTAssertEqual(classifier.phase, .stationary)
    }

    func testBumpStartsAndEventuallyEndsAnEvent() throws {
        var classifier = MotionClassifier()
        classifier.calibrate(gravity: upright)

        XCTAssertEqual(classifier.ingest(sample(0, acceleration: 0.4)), .began)

        var index = 1
        while index <= 20 {
            XCTAssertNil(classifier.ingest(sample(Double(index) * 0.1, acceleration: 0.3)))
            index += 1
        }

        let event = try XCTUnwrap(runToSettle(&classifier, from: 2.1, to: 9.0))
        XCTAssertEqual(event.peakAcceleration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(event.peakRotation, 0, accuracy: 0.0001)
        XCTAssertFalse(event.reaimed)
        XCTAssertEqual(classifier.phase, .stationary)
    }

    func testSingleQuietSampleDoesNotEndAnEvent() {
        var classifier = MotionClassifier()
        _ = classifier.ingest(sample(0, acceleration: 0.5))
        _ = classifier.ingest(sample(0.1, acceleration: 0.5))
        XCTAssertNil(classifier.ingest(sample(0.2)))
        XCTAssertEqual(classifier.phase, .moving, "one quiet sample is noise, not an ending")
    }

    func testRotationAloneCountsAsMovement() {
        var classifier = MotionClassifier()
        // A slow turn on a table: no linear acceleration, but angular velocity.
        XCTAssertEqual(classifier.ingest(sample(0, rotation: 0.5)), .began)
    }

    func testTurningTheDeviceIsRecordedAsReAiming() throws {
        var classifier = MotionClassifier()
        classifier.calibrate(gravity: upright)

        let radians = 12.0 * Double.pi / 180
        let tilted = Vector3(x: sin(radians), y: -cos(radians), z: 0)

        XCTAssertEqual(classifier.ingest(sample(0, acceleration: 0.2, gravity: tilted)), .began)
        XCTAssertNil(classifier.ingest(sample(0.1, acceleration: 0.2, gravity: tilted)))

        let event = try XCTUnwrap(runToSettle(&classifier, from: 0.2, to: 8.0, gravity: tilted))
        XCTAssertTrue(event.reaimed, "a 12° change is someone moving the camera, not a knock")
        XCTAssertEqual(event.peakTiltDegrees, 12, accuracy: 0.5)
    }

    func testASmallKnockIsNotReAiming() throws {
        var classifier = MotionClassifier()
        classifier.calibrate(gravity: upright)

        let radians = 1.0 * Double.pi / 180
        let nudged = Vector3(x: sin(radians), y: -cos(radians), z: 0)

        _ = classifier.ingest(sample(0, acceleration: 0.4, gravity: nudged))
        let event = try XCTUnwrap(runToSettle(&classifier, from: 0.1, to: 8.0, gravity: nudged))
        XCTAssertFalse(event.reaimed)
        XCTAssertLessThan(event.peakTiltDegrees, 5)
    }

    func testFlushClosesAnAbandonedEvent() {
        var classifier = MotionClassifier()
        _ = classifier.ingest(sample(0, acceleration: 0.5))
        XCTAssertEqual(classifier.phase, .moving)

        let event = classifier.flush(at: t0.addingTimeInterval(10))
        XCTAssertNotNil(event, "CoreMotion stops delivering when still; the event must still close")
        XCTAssertEqual(classifier.phase, .stationary)
    }

    func testFlushIsANoOpBeforeTheSettleDelay() {
        var classifier = MotionClassifier()
        _ = classifier.ingest(sample(0, acceleration: 0.5))
        XCTAssertNil(classifier.flush(at: t0.addingTimeInterval(1)))
        XCTAssertEqual(classifier.phase, .moving)
    }
}

final class SnapshotGateTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testClosedGateNeverCaptures() {
        let gate = SnapshotGate(minimumInterval: 1)
        XCTAssertFalse(gate.shouldCapture(at: start))
    }

    func testRateLimitsToOnePerInterval() {
        let gate = SnapshotGate(minimumInterval: 1)
        gate.open()

        XCTAssertTrue(gate.shouldCapture(at: start))
        XCTAssertFalse(gate.shouldCapture(at: start.addingTimeInterval(0.4)))
        XCTAssertFalse(gate.shouldCapture(at: start.addingTimeInterval(0.99)))
        XCTAssertTrue(gate.shouldCapture(at: start.addingTimeInterval(1.05)))
    }

    func testClosingDisarmsAndResets() {
        let gate = SnapshotGate(minimumInterval: 1)
        gate.open()
        XCTAssertTrue(gate.shouldCapture(at: start))
        gate.close()
        XCTAssertFalse(gate.isArmed)
        XCTAssertFalse(gate.shouldCapture(at: start.addingTimeInterval(5)))

        gate.open()
        XCTAssertTrue(gate.shouldCapture(at: start.addingTimeInterval(5)))
    }
}

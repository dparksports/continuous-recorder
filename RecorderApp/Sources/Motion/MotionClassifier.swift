import Foundation

/// A tiny vector type so the classifier has no dependency on simd or CoreMotion and can be
/// tested with hand-written numbers.
struct Vector3: Equatable, Codable {
    var x: Double
    var y: Double
    var z: Double

    var length: Double { (x * x + y * y + z * z).squareRoot() }

    func normalized() -> Vector3 {
        let length = self.length
        guard length > 0 else { return self }
        return Vector3(x: x / length, y: y / length, z: z / length)
    }

    func dot(_ other: Vector3) -> Double { x * other.x + y * other.y + z * other.z }
}

/// One IMU sample, already reduced to the three numbers the classifier needs.
struct MotionSample: Equatable {
    var at: Date
    /// Magnitude of `CMDeviceMotion.userAcceleration`, in g. Gravity is already removed by
    /// CoreMotion, so a device sitting still reads ~0 rather than ~1.
    var acceleration: Double
    /// Magnitude of `CMDeviceMotion.rotationRate`, in radians per second.
    var rotation: Double
    /// Gravity direction, used to notice that the device was *re-aimed* rather than bumped.
    var gravity: Vector3?
}

/// One movement episode, as it will be written to disk and signed into the chain.
struct MotionEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var peakAcceleration: Double
    var peakRotation: Double
    var peakTiltDegrees: Double
    /// True when the device ended up pointing somewhere else — the difference between
    /// "somebody knocked the table" and "somebody turned the camera away".
    var reaimed: Bool
    var sampleCount: Int
    var snapshots: [MotionSnapshot]

    var duration: TimeInterval {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct MotionSnapshot: Codable, Equatable {
    var fileName: String
    var takenAt: Date
    /// Presentation time inside the video segment, so an investigator can seek to the exact
    /// frame instead of guessing from wall clock.
    var presentationSeconds: Double
    var sha256: String
}

/// Hysteresis-based movement detector.
///
/// Two thresholds, not one: it takes a real movement to start an event and a quiet stretch
/// to end one. A single threshold makes the state chatter on every passing lorry, and any
/// system that chatters is a system whose alarms get ignored.
struct MotionClassifier {

    struct Thresholds {
        /// Enter "moving" above these.
        var movingAcceleration = 0.06      // g — a firm tap is ~0.2 g, a pickup ~0.4 g
        var movingRotation = 0.20          // rad/s — ~11 deg/s
        /// Leave "moving" below these, sustained for `settleDelay`.
        var settleAcceleration = 0.03
        var settleRotation = 0.10
        var settleDelay: TimeInterval = 3.0
        /// Gravity direction change that counts as re-aiming rather than a knock.
        var reaimDegrees = 5.0
    }

    enum Phase: Equatable {
        case stationary
        case moving
    }

    enum Transition: Equatable {
        case began
        case ended(MotionEvent)
    }

    var thresholds = Thresholds()

    private(set) var phase: Phase = .stationary
    private(set) var referenceGravity: Vector3?
    private var current: MotionEvent?
    private var lastMovementAt: Date?

    mutating func calibrate(gravity: Vector3?) {
        guard let gravity else { return }
        referenceGravity = gravity.normalized()
    }

    mutating func ingest(_ sample: MotionSample) -> Transition? {
        if referenceGravity == nil, let gravity = sample.gravity {
            referenceGravity = gravity.normalized()
        }

        let tilt = tiltDegrees(for: sample.gravity)
        let isMoving = sample.acceleration >= thresholds.movingAcceleration
            || sample.rotation >= thresholds.movingRotation
        let isSettled = sample.acceleration <= thresholds.settleAcceleration
            && sample.rotation <= thresholds.settleRotation

        switch phase {
        case .stationary:
            guard isMoving else { return nil }
            phase = .moving
            lastMovementAt = sample.at
            current = MotionEvent(
                id: UUID(),
                startedAt: sample.at,
                endedAt: nil,
                peakAcceleration: sample.acceleration,
                peakRotation: sample.rotation,
                peakTiltDegrees: tilt,
                reaimed: tilt >= thresholds.reaimDegrees,
                sampleCount: 1,
                snapshots: []
            )
            return .began

        case .moving:
            guard var event = current else { return nil }
            event.sampleCount += 1
            event.peakAcceleration = max(event.peakAcceleration, sample.acceleration)
            event.peakRotation = max(event.peakRotation, sample.rotation)
            event.peakTiltDegrees = max(event.peakTiltDegrees, tilt)
            if tilt >= thresholds.reaimDegrees { event.reaimed = true }
            current = event

            if isMoving {
                lastMovementAt = sample.at
                return nil
            }

            if isSettled, let last = lastMovementAt,
               sample.at.timeIntervalSince(last) >= thresholds.settleDelay {
                return finish(at: sample.at)
            }
            return nil
        }
    }

    /// Ends an in-flight event when samples stop arriving — CoreMotion pauses updates when
    /// the device is still, and an event that never closes would keep the snapshot gate open
    /// forever.
    mutating func flush(at date: Date) -> MotionEvent? {
        guard phase == .moving, let last = lastMovementAt else { return nil }
        guard date.timeIntervalSince(last) >= thresholds.settleDelay else { return nil }
        guard case .ended(let event)? = finish(at: last.addingTimeInterval(thresholds.settleDelay)) else {
            return nil
        }
        return event
    }

    private mutating func finish(at date: Date) -> Transition? {
        guard var event = current else { return nil }
        current = nil
        phase = .stationary
        lastMovementAt = nil
        event.endedAt = date
        return .ended(event)
    }

    private func tiltDegrees(for gravity: Vector3?) -> Double {
        guard let gravity, let reference = referenceGravity else { return 0 }
        let cosine = min(1, max(-1, gravity.normalized().dot(reference)))
        return acos(cosine) * 180 / .pi
    }
}

import CoreMotion
import Foundation

/// Thin wrapper over `CMMotionManager` that reduces each `CMDeviceMotion` to a `MotionSample`.
///
/// Cost, stated up front: device motion at 10 Hz keeps the gyro and accelerometer powered.
/// On an iPad that is tens of milliwatts — small next to the 1.6 W video pipeline, and
/// irrelevant on mains. On an audio-only battery session it is worth turning off, which is
/// why `stop()` exists.
///
/// `CMMotionManager` raw motion does not prompt for permission; the Motion & Fitness prompt
/// belongs to `CMMotionActivityManager` and `CMPedometer`. `NSMotionUsageDescription` is in
/// the plist anyway, because a prompt-less frame of reference is not something to rely on
/// forever.
final class MotionMonitor {

    /// Samples are delivered on this queue, and only this queue. The recorder puts its own
    /// event state on it too, which is what keeps the classifier single-threaded.
    let queue: OperationQueue

    /// Delivered on `queue`.
    var onSample: ((MotionSample) -> Void)?

    private let manager = CMMotionManager()
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0 / 10.0) {
        self.interval = interval
        let queue = OperationQueue()
        queue.name = "com.example.recorderapp.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.queue = queue
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = interval
        // No attitude reference frame: tilt comes from the gravity vector, which needs no
        // magnetometer to be meaningful, and a magnetic reference near steel is worse than
        // no reference at all.
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self, let motion else {
                if let error {
                    Log.app.error("motion update failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            self.onSample?(Self.reduce(motion))
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
    }

    private static func reduce(_ motion: CMDeviceMotion) -> MotionSample {
        let acceleration = motion.userAcceleration
        let rotation = motion.rotationRate
        let gravity = motion.gravity

        return MotionSample(
            at: Date(),
            acceleration: magnitude(acceleration.x, acceleration.y, acceleration.z),
            rotation: magnitude(rotation.x, rotation.y, rotation.z),
            gravity: Vector3(x: gravity.x, y: gravity.y, z: gravity.z)
        )
    }

    private static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

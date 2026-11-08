import AVFoundation
import Foundation

/// Glue between the IMU, the still-capture gate and the evidence chain.
///
/// Threading: every piece of event state lives on `MotionMonitor.queue` — samples arrive
/// there, and snapshot results hop back there. JPEG encoding happens on a separate queue so
/// a 10 ms encode never delays a 100 ms motion sample. Nothing here touches the video writer
/// beyond flipping `SnapshotGate`, which is what keeps the capture path clean.
///
/// What gets recorded for a movement episode:
/// - the episode itself (start, end, peak acceleration, peak rotation, whether it was re-aimed)
/// - one frame per second for as long as it lasts, each with its video presentation time
/// - one JSON file, hashed and signed into the chain along with the SHA-256 of every frame
///
/// The JSON is chained rather than each JPEG: one link per episode stays readable, and the
/// per-frame hashes inside it make the stills tamper-evident transitively.
final class MotionEventRecorder {

    struct Configuration {
        var snapshotInterval: TimeInterval = 1.0
        /// Guard rail: a vibration source (compressor, projector fan) can produce an episode
        /// that never settles. Cap the evidence rather than the disk.
        var maximumSnapshotsPerEvent = 600
    }

    var onEventBegan: ((MotionEvent) -> Void)?
    var onEventEnded: ((MotionEvent) -> Void)?
    var onSnapshot: ((MotionSnapshot) -> Void)?

    private let monitor: MotionMonitor
    private let gate: SnapshotGate
    private let store: MotionSnapshotStore
    private let chain: TamperChain?
    private let configuration: Configuration

    private let encodeQueue = DispatchQueue(label: "com.example.recorderapp.motion.encode",
                                            qos: .utility)

    private var classifier = MotionClassifier()
    private var active: MotionEvent?
    private var snapshotIndex = 0

    init(directory: URL,
         gate: SnapshotGate,
         chain: TamperChain?,
         configuration: Configuration = Configuration(),
         motionInterval: TimeInterval = 1.0 / 10.0) {
        self.store = MotionSnapshotStore(directory: directory)
        self.gate = gate
        self.chain = chain
        self.configuration = configuration
        self.monitor = MotionMonitor(interval: motionInterval)
    }

    var isAvailable: Bool { monitor.isAvailable }

    func start() {
        guard monitor.isAvailable else {
            Log.app.notice("device motion unavailable on this device")
            return
        }
        monitor.onSample = { [weak self] sample in
            self?.handle(sample)
        }
        monitor.start()
    }

    func stop() {
        monitor.stop()
        monitor.queue.addOperation { [weak self] in
            guard let self else { return }
            self.gate.close()
            if let event = self.classifier.flush(at: Date().addingTimeInterval(60)) {
                self.finish(event)
            }
            self.active = nil
        }
    }

    /// Called from the video capture queue, at most once per second while the gate is open.
    func capture(sampleBuffer: CMSampleBuffer) {
        monitor.queue.addOperation { [weak self] in
            guard let self, let active = self.active else { return }
            guard self.snapshotIndex < self.configuration.maximumSnapshotsPerEvent else { return }

            self.snapshotIndex += 1
            let index = self.snapshotIndex
            let eventID = active.id

            self.encodeQueue.async { [weak self] in
                guard let self,
                      let snapshot = try? self.store.encode(sampleBuffer,
                                                            eventID: eventID,
                                                            index: index) else { return }
                self.monitor.queue.addOperation { [weak self] in
                    guard let self, var event = self.active, event.id == eventID else { return }
                    event.snapshots.append(snapshot)
                    self.active = event
                    DispatchQueue.main.async { self.onSnapshot?(snapshot) }
                }
            }
        }
    }

    // MARK: - Event state (MotionMonitor.queue only)

    private func handle(_ sample: MotionSample) {
        if let transition = classifier.ingest(sample) {
            switch transition {
            case .began:
                begin(at: sample.at)
            case .ended(let event):
                finish(event)
            }
        }

        // CoreMotion suspends updates when the device is still; an event left open would keep
        // the gate armed and the stills coming forever.
        if let stale = classifier.flush(at: Date()) {
            finish(stale)
        }
    }

    private func begin(at date: Date) {
        gate.open()
        snapshotIndex = 0
        active = MotionEvent(
            id: UUID(),
            startedAt: date,
            endedAt: nil,
            peakAcceleration: 0,
            peakRotation: 0,
            peakTiltDegrees: 0,
            reaimed: false,
            sampleCount: 0,
            snapshots: []
        )
        let event = active
        DispatchQueue.main.async { [weak self] in
            guard let event else { return }
            self?.onEventBegan?(event)
        }
    }

    private func finish(_ event: MotionEvent) {
        gate.close()

        var completed = event
        if let active, active.id == event.id {
            completed.snapshots = active.snapshots
        }
        active = nil

        do {
            let directory = store.directory.appendingPathComponent(event.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("event.json")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(completed).write(to: url, options: .atomic)

            // Sign after the frames are on disk: the payload contains their hashes, so one
            // link covers the whole episode.
            try? chain?.append(fileAt: url,
                               relativePath: "\(event.id.uuidString)/event.json",
                               durationSeconds: completed.duration)
        } catch {
            Log.storage.error("motion event write failed: \(error.localizedDescription, privacy: .public)")
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEventEnded?(completed)
        }
    }
}

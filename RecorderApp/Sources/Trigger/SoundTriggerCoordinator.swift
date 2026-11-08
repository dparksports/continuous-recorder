import Foundation

/// One sound-triggered recording episode.
struct SoundTriggerEvent: Codable, Equatable {
    var startedAt: Date
    var endedAt: Date?
    var peakLevelDB: Double
    var noiseFloorDB: Double

    var duration: TimeInterval {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// Drives the video recorder between "dormant" and "full" from the audio level.
///
/// Deliberately not `@MainActor`: `ingest` is called from the audio tap, where an actor hop
/// per buffer would be both wasteful and late. State sits behind one lock; the interesting
/// work (setting a capture rate, telling the UI) is handed off.
final class SoundTriggerCoordinator {

    struct Configuration {
        /// Dormant: one frame per second, enough to know something happened and to have a
        /// picture of it, cheap enough to stay on.
        var dormantFramesPerSecond: Int32 = 1
        /// Full: what the recorder normally runs at.
        var activeFramesPerSecond: Int32 = 15
    }

    struct State: Equatable {
        var isTriggered = false
        var levelDB: Double = -100
        var noiseFloorDB: Double = -100
        var triggerCount = 0
        var current: SoundTriggerEvent?
    }

    /// Both delivered on the main queue.
    var onTriggerBegan: ((SoundTriggerEvent) -> Void)?
    var onTriggerEnded: ((SoundTriggerEvent) -> Void)?
    var onLevel: ((Double, Double) -> Void)?

    private let lock = NSLock()
    private var analyzer = AudioTriggerAnalyzer()
    private var state = State()
    private let configuration: Configuration
    private weak var video: HourlyVideoRecorder?

    init(video: HourlyVideoRecorder?, configuration: Configuration = Configuration()) {
        self.video = video
        self.configuration = configuration
    }

    /// Call from the audio tap, once per buffer (~85 ms at 4096 frames / 48 kHz).
    func ingest(levelDB: Double) {
        lock.lock()
        let transition = analyzer.ingest(levelDB: levelDB, at: Date())
        state.levelDB = analyzer.lastLevelDB
        state.noiseFloorDB = analyzer.noiseFloorDB ?? -100
        let floor = state.noiseFloorDB
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(max(-100, levelDB), floor)
        }

        guard let transition else { return }

        switch transition {
        case .opened(let level, let floor):
            video?.setFramesPerSecond(configuration.activeFramesPerSecond)

            let event = SoundTriggerEvent(
                startedAt: Date(),
                endedAt: nil,
                peakLevelDB: level,
                noiseFloorDB: floor
            )
            lock.lock()
            state.isTriggered = true
            state.triggerCount += 1
            state.current = event
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onTriggerBegan?(event)
            }

        case .closed(let peak, let duration):
            video?.setFramesPerSecond(configuration.dormantFramesPerSecond)

            lock.lock()
            var finished = state.current
            if var event = finished {
                event.endedAt = Date()
                event.peakLevelDB = max(event.peakLevelDB, peak)
                finished = event
            }
            state.isTriggered = false
            state.current = nil
            let event = finished ?? SoundTriggerEvent(
                startedAt: Date().addingTimeInterval(-duration),
                endedAt: Date(),
                peakLevelDB: peak,
                noiseFloorDB: state.noiseFloorDB
            )
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onTriggerEnded?(event)
            }
        }
    }

    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func reset() {
        lock.lock()
        analyzer.reset()
        state.isTriggered = false
        state.current = nil
        lock.unlock()
        video?.setFramesPerSecond(configuration.dormantFramesPerSecond)
    }
}

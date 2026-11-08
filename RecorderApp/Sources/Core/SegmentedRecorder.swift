import AVFoundation
import Foundation

/// Gapless, segmented, background-capable audio recorder.
///
/// Why `AVAudioEngine` and not `AVAudioRecorder`:
/// `AVAudioRecorder` tears the capture path down and rebuilds it between files, which
/// leaves a 20–80 ms hole at every segment boundary. With an engine tap the capture
/// stream never stops — only the file being written to changes — so segment *n* and
/// segment *n+1* are contiguous to the sample. That is what makes "record every second"
/// true rather than approximately true.
///
/// Locking rule: `engine.stop()` waits for the render thread, and the render thread can
/// be waiting for `lock`. Therefore the engine is always stopped *outside* the lock,
/// with `suspendWrites` set so the tap drops buffers instead of writing into a file
/// that is being closed.
final class SegmentedRecorder {

    enum RecorderError: LocalizedError {
        case noAudioInput
        case engineStartFailed(String)
        case writerClosed
        case formatMismatch(expected: Double, actual: Double)

        var errorDescription: String? {
            switch self {
            case .noAudioInput:
                return "No audio input is available."
            case .engineStartFailed(let message):
                return "The audio engine failed to start: \(message)"
            case .writerClosed:
                return "The current segment has already been closed."
            case .formatMismatch(let expected, let actual):
                return "Capture format mismatch (expected \(expected), got \(actual))."
            }
        }
    }

    struct Snapshot {
        var isRunning = false          // a session is open (may be paused by an interruption)
        var isCapturing = false        // audio is actively being written
        var sessionStartedAt: Date?
        var segmentsClosed = 0
        var audioSeconds: Double = 0
        var elapsed: Double = 0
        var bytesOnDisk: Int64 = 0
        var currentSegmentName: String?
        var currentSegmentSeconds: Double = 0
        var level: Float = 0
        var lastError: String?
    }

    /// All callbacks may arrive off the main thread — hop to main before touching UI.
    var onSegmentClosed: ((SegmentRecord) -> Void)?
    var onGapRecorded: ((GapRecord) -> Void)?
    var onAutoStop: ((String) -> Void)?

    /// User settings, re-read at every segment boundary so changes apply without
    /// interrupting the file currently being written.
    var profileProvider: (() -> RecordingProfile)?
    /// Power/thermal/storage policy, also evaluated at every segment boundary.
    var policy: ((PowerGovernor.Inputs, RecordingProfile) -> PowerGovernor.Decision)?

    private var engine = AVAudioEngine()
    private let session = AudioSessionController()
    /// Recursive because `snapshot()` can be called from a callback triggered while a
    /// rotation is in progress on the same thread.
    private let lock = NSRecursiveLock()

    private var store: FileStore?
    private var manifest: ManifestStore?
    private var sessionDirectory: URL?

    private var profile = RecordingProfile.default
    private var captureFormat: AVAudioFormat?
    private var writer: SegmentWriter?
    private var sessionStartedAt: Date?
    private var closedSegments: [SegmentRecord] = []
    private var gaps: [GapRecord] = []
    private var nextIndex = 1
    private var tapInstalled = false
    private var suspendWrites = false
    private var smoothedLevel: Float = 0
    private var lastError: String?
    private var pendingStopReason: String?
    private var gapStartedAt: Date?
    private var closedBytes: Int64 = 0

    init() {
        session.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        lock.lock()
        let alreadyRunning = sessionStartedAt != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        try session.configure()
        try session.setActive(true)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false)
            throw RecorderError.noAudioInput
        }

        let store = try FileStore.makeDefault()
        let directory = try store.makeSessionDirectory()
        let manifest = ManifestStore(directory: directory)
        manifest.beginSession(SessionRecord(id: UUID(), startedAt: Date(), endedAt: nil, segments: 0))

        lock.lock()
        self.store = store
        self.sessionDirectory = directory
        self.manifest = manifest
        self.captureFormat = format
        self.sessionStartedAt = Date()
        self.closedSegments = []
        self.gaps = []
        self.closedBytes = 0
        self.nextIndex = 1
        self.lastError = nil
        self.pendingStopReason = nil
        self.suspendWrites = false
        self.profile = profileProvider?() ?? profile

        do {
            try openSegmentLocked(gapBefore: 0)
        } catch {
            sessionStartedAt = nil
            lock.unlock()
            try? session.setActive(false)
            throw error
        }
        lock.unlock()

        // Everything below is outside the lock: `engine.start()` can wait on the render
        // thread, and the render thread takes this lock inside `consume`.
        installTap(format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            removeTap()
            lock.lock()
            writer = nil
            sessionStartedAt = nil
            suspendWrites = true
            lock.unlock()
            try? session.setActive(false)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }

        Log.audio.notice("recording → \(directory.path, privacy: .public)")
    }

    func stop(reason: String = "user") {
        lock.lock()
        let wasRunning = sessionStartedAt != nil
        if wasRunning { suspendWrites = true }
        lock.unlock()
        guard wasRunning else { return }

        // Outside the lock — see the class comment.
        engine.stop()
        removeTap()

        lock.lock()
        defer { lock.unlock() }
        suspendWrites = false
        closeCurrentSegmentLocked(reason: reason)
        closeGapLocked(reason: reason)

        if let started = sessionStartedAt {
            let duration = Date().timeIntervalSince(started)
            manifest?.finishSession(endedAt: Date())
            Log.session.notice("session stopped after \(duration, format: .fixed(precision: 1))s (\(reason, privacy: .public))")
        }

        sessionStartedAt = nil
        captureFormat = nil
        pendingStopReason = nil
        try? session.setActive(false)
    }

    // MARK: - Read-only surface for the UI

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = Snapshot()
        snapshot.isRunning = sessionStartedAt != nil
        snapshot.isCapturing = writer != nil && !suspendWrites
        snapshot.sessionStartedAt = sessionStartedAt
        snapshot.segmentsClosed = closedSegments.count
        snapshot.level = smoothedLevel
        snapshot.lastError = lastError

        let closedAudio = closedSegments.reduce(0) { $0 + $1.audioSeconds }
        let openAudio = writer.map { Double($0.framesWritten) / max(1, $0.sampleRate) } ?? 0
        snapshot.audioSeconds = closedAudio + openAudio

        if let started = sessionStartedAt {
            snapshot.elapsed = Date().timeIntervalSince(started)
        }

        if let writer {
            snapshot.currentSegmentName = writer.url.lastPathComponent
            snapshot.currentSegmentSeconds = Date().timeIntervalSince(writer.startedAt)
            snapshot.bytesOnDisk = closedBytes + Self.estimatedBytes(writer)
        } else {
            snapshot.bytesOnDisk = closedBytes
        }

        return snapshot
    }

    func coverageSummary() -> CoverageSummary {
        lock.lock()
        defer { lock.unlock() }

        var segments = closedSegments
        if let writer {
            segments.append(SegmentRecord(
                id: UUID(),
                index: writer.index,
                fileName: writer.url.lastPathComponent,
                startedAt: writer.startedAt,
                endedAt: Date(),
                frames: writer.framesWritten,
                sampleRate: writer.sampleRate,
                channels: writer.channels,
                bitRate: writer.bitRate,
                codec: writer.codec.rawValue,
                byteSize: 0,
                gapBeforeSeconds: writer.gapBeforeSeconds,
                endReason: nil
            ))
        }
        return CoverageSummary.compute(segments: segments, gaps: gaps)
    }

    func freeBytes() -> Int64? {
        store?.freeBytes()
    }

    // MARK: - Capture

    private func installTap(format: AVAudioFormat) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !suspendWrites, let writer = self.writer else { return }

        do {
            try writer.write(buffer)
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if let level = Self.rmsLevel(buffer) {
            smoothedLevel = smoothedLevel * 0.85 + level * 0.15
        }

        if Date().timeIntervalSince(writer.startedAt) >= profile.segmentDuration {
            rotateLocked(reason: "rotation")
        }
    }

    // MARK: - Segment bookkeeping (all *Locked methods require `lock`)

    private func openSegmentLocked(gapBefore: Double) throws {
        guard let directory = sessionDirectory, let format = captureFormat else {
            throw RecorderError.noAudioInput
        }
        profile = profileProvider?() ?? profile

        let name = "seg-\(String(format: "%05d", nextIndex)).\(profile.codec.fileExtension)"
        let url = directory.appendingPathComponent(name)
        writer = try SegmentWriter(
            index: nextIndex,
            url: url,
            format: format,
            profile: profile,
            gapBeforeSeconds: gapBefore
        )
        nextIndex += 1
    }

    private func closeCurrentSegmentLocked(reason: String) {
        guard let current = writer else { return }
        let record = current.finish(reason: reason)
        writer = nil
        closedSegments.append(record)
        closedBytes += record.byteSize
        manifest?.append(record)
        onSegmentClosed?(record)
        Log.audio.notice("segment \(record.index) closed: \(record.audioSeconds, format: .fixed(precision: 2))s")
    }

    private func rotateLocked(reason: String) {
        guard writer != nil else { return }
        closeCurrentSegmentLocked(reason: reason)
        evaluatePolicyLocked()
        guard pendingStopReason == nil else { return }

        do {
            try openSegmentLocked(gapBefore: 0)
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("next segment failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evaluatePolicyLocked() {
        guard let policy else { return }
        let inputs = PowerGovernor.currentInputs(freeBytes: store?.freeBytes())
        switch policy(inputs, profile) {
        case .keep:
            break

        case .downgrade(let preset):
            guard profile.preset != preset else { break }
            Log.power.notice("downgrading capture to \(preset.rawValue, privacy: .public)")
            profile = RecordingProfile.make(
                preset: preset,
                segmentDuration: profile.segmentDuration,
                sampleRate: profile.sampleRate
            )

        case .stop(let reason):
            pendingStopReason = reason
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onAutoStop?(reason)
                self.stop(reason: "auto: \(reason)")
            }
        }
    }

    private func closeGapLocked(reason: String) {
        guard let started = gapStartedAt else { return }
        gapStartedAt = nil
        let gap = GapRecord(id: UUID(), startedAt: started, endedAt: Date(), reason: reason)
        gaps.append(gap)
        manifest?.append(gap)
        onGapRecorded?(gap)
        Log.audio.notice("gap \(gap.seconds, format: .fixed(precision: 2))s (\(reason, privacy: .public))")
    }

    // MARK: - Session events

    private func handle(_ event: AudioSessionController.Event) {
        switch event {
        case .interruptionBegan:
            pauseCapture(reason: "interruption")

        case .interruptionEnded:
            // Apple only sets `shouldResume` when it thinks resuming is appropriate
            // (it is absent after, say, a Siri session that took the mic). A recorder's
            // whole contract is continuity, so try regardless; a failed activation is
            // logged and leaves an honest gap record behind.
            resumeCapture(reason: "interruption")

        case .inputRouteChanged:
            restartCapture(reason: "routeChange")

        case .mediaServicesWereReset:
            rebuildAfterMediaReset()
        }
    }

    /// A phone call, Siri, or another app grabbing the input: close the file cleanly so
    /// a crash during the interruption cannot leave an unfinalised container behind.
    private func pauseCapture(reason: String) {
        lock.lock()
        guard sessionStartedAt != nil, gapStartedAt == nil else {
            lock.unlock()
            return
        }
        gapStartedAt = Date()
        suspendWrites = true
        lock.unlock()

        engine.stop()
        removeTap()

        lock.lock()
        closeCurrentSegmentLocked(reason: reason)
        lock.unlock()
    }

    private func resumeCapture(reason: String) {
        lock.lock()
        let wasPaused = gapStartedAt != nil
        lock.unlock()
        guard wasPaused else { return }

        do {
            try session.setActive(true)
        } catch {
            lastError = error.localizedDescription
            Log.session.error("could not reactivate session: \(error.localizedDescription, privacy: .public)")
            lock.lock()
            closeGapLocked(reason: reason)
            lock.unlock()
            return
        }

        restartCapture(reason: reason)
    }

    private func restartCapture(reason: String) {
        lock.lock()
        let active = sessionStartedAt != nil
        if active { suspendWrites = true }
        lock.unlock()
        guard active else { return }

        engine.stop()
        removeTap()

        lock.lock()
        closeGapLocked(reason: reason)
        closeCurrentSegmentLocked(reason: reason)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "No usable input after \(reason)"
            lock.unlock()
            return
        }
        captureFormat = format

        do {
            try openSegmentLocked(gapBefore: 0)
        } catch {
            lastError = error.localizedDescription
            lock.unlock()
            return
        }
        suspendWrites = false
        lock.unlock()

        // Same rule as `start()`: never start the engine while holding the lock.
        installTap(format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("restart failed: \(error.localizedDescription, privacy: .public)")
            lock.lock()
            suspendWrites = true
            lock.unlock()
        }
    }

    /// `AVAudioSessionMediaServicesWereResetNotification` invalidates the engine instance
    /// itself; it has to be rebuilt, not restarted.
    private func rebuildAfterMediaReset() {
        lock.lock()
        let active = sessionStartedAt != nil
        if active { suspendWrites = true }
        lock.unlock()
        guard active else { return }

        engine.stop()
        tapInstalled = false
        engine = AVAudioEngine()
        restartCapture(reason: "mediaServicesReset")
    }

    // MARK: - Helpers

    private static func estimatedBytes(_ writer: SegmentWriter) -> Int64 {
        guard writer.sampleRate > 0 else { return 0 }
        let seconds = Double(writer.framesWritten) / writer.sampleRate
        return Int64(seconds * Double(writer.bitRate) / 8)
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }

        var sum: Float = 0
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<frames {
                let value = samples[frame]
                sum += value * value
            }
        }
        let mean = sum / Float(frames * channels)
        // Display-only mapping: useful on a meter, not a calibrated dBFS reading.
        return min(1, sqrt(mean) * 6)
    }
}

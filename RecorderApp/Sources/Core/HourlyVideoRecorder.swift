import AVFoundation
import Foundation

/// Hourly-segmented video recorder built on `AVCaptureVideoDataOutput` + `AVAssetWriter`.
///
/// Two constraints shape this file, and neither is negotiable on iOS:
///
/// 1. **Video capture only runs while the app is frontmost.** Locking the device or
///    backgrounding the app suspends the capture session, and there is no camera
///    background mode to apply for. So the "screen off + recording" trick that works for
///    audio does not exist for video: the panel has to stay lit, at minimum brightness.
/// 2. **A writer only produces a playable file when it is finished.** An hour-long file
///    is an hour of exposure to a power cut or a kill. `segmentDuration` is therefore a
///    real trade-off, not a formatting preference — see Docs/POWER-AND-DISPLAY.md.
///
/// Rotation happens between sample buffers, so the *capture* stream never stops; only the
/// destination file changes. The gap at each boundary is the encoder's restart (one frame),
/// not a tear-down of the camera.
final class HourlyVideoRecorder: NSObject {

    struct Settings {
        var width: Int32 = 1920
        var height: Int32 = 1080
        var framesPerSecond: Int32 = 15
        var bitRate: Int = 4_000_000
        var segmentDuration: TimeInterval = 3600
        var codec: AVVideoCodecType = .hevc
        var position: AVCaptureDevice.Position = .back

        /// Planning number: bytes one hour of this profile costs on disk.
        var bytesPerHour: Int64 { Int64(Double(bitRate) / 8 * 3600) }
    }

    struct VideoSegmentRecord: Codable, Identifiable {
        var id = UUID()
        var index: Int
        var fileName: String
        var relativePath: String
        var startedAt: Date
        var endedAt: Date?
        var byteSize: Int64
        var durationSeconds: Double
        var droppedFrames: Int
    }

    enum RecorderError: LocalizedError {
        case cameraUnavailable
        case notAuthorized
        case cannotAddInput
        case cannotAddOutput
        case writerStartFailed(String)
        case storageUnavailable

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable:      return "No back camera is available."
            case .notAuthorized:          return "Camera access was denied."
            case .cannotAddInput:         return "The capture session refused the camera input."
            case .cannotAddOutput:        return "The capture session refused the video output."
            case .writerStartFailed(let message): return "Video writer failed to start: \(message)"
            case .storageUnavailable:     return "No writable directory for video segments."
            }
        }
    }

    /// Delivered on the write queue.
    var onSegmentClosed: ((VideoSegmentRecord) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Frames are offered to `snapshotHandler` at most once per second while the gate is
    /// open. Set before `start()`; the gate itself is lock-protected because the motion
    /// recorder opens and closes it from a different queue.
    var snapshotHandler: ((CMSampleBuffer) -> Void)?
    let snapshotGate = SnapshotGate()

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.example.recorderapp.video.session")
    private let writeQueue = DispatchQueue(label: "com.example.recorderapp.video.write",
                                           qos: .userInitiated)

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var directory: URL?
    private var settings = Settings()
    private var segmentIndex = 1
    private var segmentStartedAt: Date?
    private var segmentDroppedFrames = 0
    private var isRunning = false
    private var currentFrameRate: Int32 = 15

    // MARK: - Permission

    static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: - Lifecycle

    func start(settings: Settings) throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw RecorderError.notAuthorized
        }

        self.settings = settings
        self.currentFrameRate = settings.framesPerSecond

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: settings.position) else {
            throw RecorderError.cameraUnavailable
        }

        try configure(device: device)

        let store = try FileStore.makeDefault()
        let dayDirectory = try store.makeSessionDirectory()
        let videoDirectory = dayDirectory.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        directory = videoDirectory
        segmentIndex = 1

        isRunning = true
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
        Log.audio.notice("video session starting in \(videoDirectory.path, privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        output.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.async { [weak self] in
            guard let session = self?.session, session.isRunning else { return }
            session.stopRunning()
        }
        writeQueue.async { [weak self] in
            self?.finishCurrentSegment(reason: "stopped")
        }
    }

    /// Drops to a lower frame rate in the heat rather than cooking the battery: 15 fps →
    /// 10 fps cuts the ISP and encoder load by a third and costs nothing for surveillance.
    func applyThermalPolicy(_ state: ProcessInfo.ThermalState) {
        guard isRunning else { return }
        let target: Int32
        switch state {
        case .serious:  target = 10
        case .critical: target = 5
        default:        return
        }
        guard target != currentFrameRate else { return }
        currentFrameRate = target

        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: target)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                Log.power.notice("video frame rate → \(target) fps (thermal \(state.rawValue))")
            } catch {
                Log.audio.error("could not lower frame rate: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Session configuration

    private func configure(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError.cannotAddInput }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw RecorderError.cannotAddOutput }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: writeQueue)

        // No preview layer is attached anywhere, on purpose: the compositor is the second
        // biggest display cost after the backlight, and nothing needs to look at it.
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: settings.framesPerSecond)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            Log.audio.error("could not pin frame rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Writer rotation (all on writeQueue)

    private func shouldRotate() -> Bool {
        guard let started = segmentStartedAt else { return true }
        return Date().timeIntervalSince(started) >= settings.segmentDuration
    }

    private func startNewSegment(at pts: CMTime) {
        guard let directory else {
            fail("Video directory disappeared")
            return
        }

        let name = "hour-\(String(format: "%05d", segmentIndex)).mp4"
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.bitRate,
                AVVideoMaxKeyFrameIntervalKey: Int(settings.framesPerSecond) * 2,
                AVVideoExpectedSourceFrameRateKey: Int(settings.framesPerSecond)
            ]
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: settings.codec,
                AVVideoWidthKey: Int(settings.width),
                AVVideoHeightKey: Int(settings.height),
                AVVideoCompressionPropertiesKey: compression
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.writerStartFailed("input rejected") }
            writer.add(input)

            guard writer.startWriting() else {
                throw RecorderError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
            }
            // A fresh writer starts with a keyframe, so each hour is independently playable
            // without re-encoding.
            writer.startSession(atSourceTime: pts)

            self.writer = writer
            self.writerInput = input
            self.segmentStartedAt = Date()
            self.segmentDroppedFrames = 0
            self.segmentIndex += 1
        } catch {
            fail("could not open video segment: \(error.localizedDescription)")
        }
    }

    private func finishCurrentSegment(reason: String) {
        guard let writer, let input = writerInput, let directory, let startedAt = segmentStartedAt else {
            self.writer = nil
            self.writerInput = nil
            return
        }

        self.writer = nil
        self.writerInput = nil
        self.segmentStartedAt = nil

        input.markAsFinished()
        let index = segmentIndex - 1
        let dropped = segmentDroppedFrames

        writer.finishWriting {
            let url = writer.outputURL
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let record = VideoSegmentRecord(
                index: index,
                fileName: url.lastPathComponent,
                relativePath: url.path.replacingOccurrences(of: directory.path + "/", with: ""),
                startedAt: startedAt,
                endedAt: Date(),
                byteSize: size,
                durationSeconds: Date().timeIntervalSince(startedAt),
                droppedFrames: dropped
            )
            if writer.status == .failed {
                Log.audio.error("video segment failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            Log.audio.notice("video segment \(index) closed (\(reason, privacy: .public)): \(size) bytes, \(dropped) dropped frames")
            self.onSegmentClosed?(record)
        }
    }

    private func fail(_ message: String) {
        Log.audio.error("video: \(message, privacy: .public)")
        onFailure?(message)
    }
}

// MARK: - Capture delegate

extension HourlyVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer == nil {
            startNewSegment(at: pts)
        } else if shouldRotate() {
            finishCurrentSegment(reason: "rotation")
            startNewSegment(at: pts)
        }

        guard let input = writerInput, input.isReadyForMoreMediaData else {
            segmentDroppedFrames += 1
            return
        }
        if !input.append(sampleBuffer) {
            segmentDroppedFrames += 1
        }

        if let snapshotHandler, snapshotGate.shouldCapture(at: Date()) {
            snapshotHandler(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        segmentDroppedFrames += 1
    }
}

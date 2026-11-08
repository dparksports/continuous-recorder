import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// Decides whether a frame from the video stream should be turned into a still.
///
/// The gate is armed only while a motion event is in flight, and it rate-limits to one frame
/// per interval. It is read from the capture queue and written from the motion queue, so it
/// carries its own lock rather than borrowing the recorder's.
final class SnapshotGate {
    private let lock = NSLock()
    private var armed = false
    private var lastCapture: Date?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    func open() {
        lock.lock()
        armed = true
        lastCapture = nil
        lock.unlock()
    }

    func close() {
        lock.lock()
        armed = false
        lastCapture = nil
        lock.unlock()
    }

    /// True at most once per `minimumInterval` while armed. Mutates state, so call it exactly
    /// once per frame you might want to keep.
    func shouldCapture(at date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return false }
        if let lastCapture, date.timeIntervalSince(lastCapture) < minimumInterval {
            return false
        }
        lastCapture = date
        return true
    }
}

/// Turns a frame that is already flowing through the video pipeline into a JPEG.
///
/// Deliberately *not* `AVCapturePhotoOutput`: a photo capture runs the full still pipeline,
/// which costs more, takes longer, and can stutter the video it is supposed to be observing.
/// This reuses one frame the encoder has already seen, at 1 Hz, for the price of a JPEG
/// encode.
struct MotionSnapshotStore {

    /// Wall-clock quality is not the point — being able to recognise a person is. 1280 px
    /// wide at quality 0.7 lands around 90–140 KB per frame, so a five-minute event costs
    /// roughly 30–40 MB rather than 2 GB.
    static let targetWidth: CGFloat = 1280
    static let quality: CGFloat = 0.7

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    let directory: URL

    func encode(_ sampleBuffer: CMSampleBuffer,
                eventID: UUID,
                index: Int) throws -> MotionSnapshot? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, Self.targetWidth / max(1, image.extent.width))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // CIImageRepresentationOption has no compression-quality member (the CG constant
        // kCGImageDestinationLossyCompressionQuality is not bridged as one), so go through
        // UIImage, which has a stable, documented quality knob.
        guard let cgImage = Self.context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: Self.quality) else {
            return nil
        }

        let eventDirectory = directory.appendingPathComponent(eventID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: eventDirectory, withIntermediateDirectories: true)
        let fileName = String(format: "frame-%04d.jpg", index)
        let url = eventDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)

        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return MotionSnapshot(
            fileName: "\(eventID.uuidString)/\(fileName)",
            takenAt: Date(),
            presentationSeconds: presentation.isValid ? presentation.seconds : 0,
            sha256: (try? FileDigest.sha256Hex(of: url)) ?? ""
        )
    }
}

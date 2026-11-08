import AVFoundation
import Foundation
import QuartzCore
import UIKit

/// Burns the watermark into a finished segment.
///
/// This is a re-encode, not an overlay: `AVVideoCompositionCoreAnimationTool` renders the
/// text into the pixels at export time, so the stamp exists in the file and survives being
/// copied, played elsewhere, or handed to someone who was not there.
///
/// Two costs, both real:
/// - Roughly the work of encoding the segment a second time. On a mains-powered kiosk that
///   is fine; on battery it halves the number of hours you get.
/// - It must run *before* the chain hash is taken, so the hash covers the stamped bytes.
///   Order: `finishWriting` → burn → SHA-256 → chain link.
///
/// The alternative costs nothing and is arguably stronger evidence: leave the pixels alone
/// and carry the same values in the chain payload. Do that if the footage is only ever
/// machine-verified; burn it in if a human has to look at the file and know when it was made.
enum WatermarkComposer {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func burn(line: String, from input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "no video track in \(input.lastPathComponent)")
        }

        let duration = try await asset.load(.duration)
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let transform = try await sourceTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw Failure(message: "degenerate render size for \(input.lastPathComponent)")
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure(message: "could not create a composition track")
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                  of: sourceTrack,
                                  at: .zero)
        track.preferredTransform = transform

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Layer space here is bottom-left origin, so `renderSize.height - …` is the top edge.
        let fontSize = max(18, renderSize.height * 0.028)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)

        let textLayer = CATextLayer()
        textLayer.string = line
        textLayer.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        textLayer.fontSize = fontSize
        textLayer.alignmentMode = .center
        textLayer.masksToBounds = true
        textLayer.cornerRadius = 4
        textLayer.foregroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        textLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        textLayer.frame = CGRect(x: renderSize.width * 0.08,
                                 y: renderSize.height - fontSize * 2.6,
                                 width: renderSize.width * 0.84,
                                 height: fontSize * 1.7)
        parentLayer.addSublayer(textLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw Failure(message: "could not create an export session")
        }
        export.videoComposition = videoComposition
        export.outputURL = output
        export.outputFileType = .mp4

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        guard export.status == .completed else {
            throw Failure(message: export.error?.localizedDescription ?? "export did not complete")
        }
    }
}

import AVFoundation
import Foundation

/// One file on disk plus the bookkeeping needed to describe it in the manifest.
///
/// Closing is implicit: `AVAudioFile` finalises the container (writes the MP4 `moov`
/// atom, or the WAV header) when it is deallocated. That is why `finish(reason:)`
/// drops the reference rather than calling a `close()`.
final class SegmentWriter {
    let index: Int
    let url: URL
    let startedAt: Date
    let sampleRate: Double
    let channels: Int
    let bitRate: Int
    let codec: RecordingProfile.AudioCodec
    let gapBeforeSeconds: Double

    private var file: AVAudioFile?
    private var frames: Int64 = 0

    var framesWritten: Int64 { frames }

    init(
        index: Int,
        url: URL,
        format: AVAudioFormat,
        profile: RecordingProfile,
        gapBeforeSeconds: Double
    ) throws {
        self.index = index
        self.url = url
        self.startedAt = Date()
        self.sampleRate = format.sampleRate
        self.channels = Int(format.channelCount)
        self.codec = profile.codec
        self.gapBeforeSeconds = gapBeforeSeconds

        let channelCount = max(1, Int(format.channelCount))
        var settings: [String: Any] = [
            AVFormatIDKey: profile.codec.formatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channelCount
        ]

        switch profile.codec {
        case .aac:
            // The encoder works on bits per second for the whole stream, not per channel.
            let totalBits = max(16_000, profile.bitRatePerChannel * channelCount)
            settings[AVEncoderBitRateKey] = totalBits
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
            self.bitRate = totalBits
        case .alac:
            settings[AVEncoderBitDepthHintKey] = 16
            self.bitRate = Int(RecordingProfile.pcmBytesPerHour(sampleRate: format.sampleRate,
                                                               channels: channelCount) * 8 / 3600)
        case .pcm:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            self.bitRate = Int(RecordingProfile.pcmBytesPerHour(sampleRate: format.sampleRate,
                                                               channels: channelCount) * 8 / 3600)
        }

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Defensive: a mismatch here would throw on every single write, once per buffer,
        // forever. Fail loudly at segment open instead.
        let processing = audioFile.processingFormat
        guard abs(processing.sampleRate - format.sampleRate) < 1 else {
            throw SegmentedRecorder.RecorderError.formatMismatch(
                expected: format.sampleRate,
                actual: processing.sampleRate
            )
        }
        guard processing.channelCount == format.channelCount else {
            throw SegmentedRecorder.RecorderError.formatMismatch(
                expected: Double(format.channelCount),
                actual: Double(processing.channelCount)
            )
        }

        self.file = audioFile
    }

    /// Must be fast: called from the audio tap.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw SegmentedRecorder.RecorderError.writerClosed }
        try file.write(from: buffer)
        frames += Int64(buffer.frameLength)
    }

    func finish(reason: String) -> SegmentRecord {
        file = nil  // deallocation finalises the container
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return SegmentRecord(
            id: UUID(),
            index: index,
            fileName: url.lastPathComponent,
            startedAt: startedAt,
            endedAt: Date(),
            frames: frames,
            sampleRate: sampleRate,
            channels: channels,
            bitRate: bitRate,
            codec: codec.rawValue,
            byteSize: size,
            gapBeforeSeconds: gapBeforeSeconds,
            endReason: reason
        )
    }
}

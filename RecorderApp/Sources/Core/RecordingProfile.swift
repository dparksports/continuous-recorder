import AVFoundation
import Foundation

/// Everything that decides how many bytes one second of audio costs.
///
/// The important thing to understand: **bitrate barely changes power draw.** Encoding
/// 48 kbps or 128 kbps on the Apple audio DSP is the same order of cost. Bitrate changes
/// how many hours fit on disk, not how many hours run on battery. Sample rate and the
/// screen are what actually move the power needle.
struct RecordingProfile: Codable, Equatable {

    enum Preset: String, Codable, CaseIterable, Identifiable {
        case speech
        case balanced
        case high
        case lossless
        case pcm

        var id: String { rawValue }

        var title: String {
            switch self {
            case .speech:   return "Speech · AAC 48 kbps/ch"
            case .balanced: return "Balanced · AAC 96 kbps/ch"
            case .high:     return "High · AAC 128 kbps/ch"
            case .lossless: return "Lossless · ALAC 16-bit"
            case .pcm:      return "Uncompressed · WAV 16-bit"
            }
        }

        var shortTitle: String {
            switch self {
            case .speech:   return "Speech"
            case .balanced: return "Balanced"
            case .high:     return "High"
            case .lossless: return "ALAC"
            case .pcm:      return "WAV"
            }
        }

        var codec: AudioCodec {
            switch self {
            case .speech, .balanced, .high: return .aac
            case .lossless:                 return .alac
            case .pcm:                      return .pcm
            }
        }

        /// Bits per second *per channel*. Ignored for lossless and PCM.
        var bitRatePerChannel: Int {
            switch self {
            case .speech:   return 48_000
            case .balanced: return 96_000
            case .high:     return 128_000
            case .lossless, .pcm: return 0
            }
        }
    }

    enum AudioCodec: String, Codable {
        case aac
        case alac
        case pcm

        var fileExtension: String {
            switch self {
            case .aac, .alac: return "m4a"
            case .pcm:        return "wav"
            }
        }

        var formatID: AudioFormatID {
            switch self {
            case .aac:  return kAudioFormatMPEG4AAC
            case .alac: return kAudioFormatAppleLossless
            case .pcm:  return kAudioFormatLinearPCM
            }
        }

        var displayName: String {
            switch self {
            case .aac:  return "AAC"
            case .alac: return "ALAC"
            case .pcm:  return "PCM"
            }
        }
    }

    var preset: Preset
    var sampleRate: Double
    var bitRatePerChannel: Int
    var codec: AudioCodec
    /// Length of one file on disk. Shorter = less audio lost if the app is killed.
    var segmentDuration: TimeInterval

    static let `default` = RecordingProfile(
        preset: .speech,
        sampleRate: 48_000,
        bitRatePerChannel: Preset.speech.bitRatePerChannel,
        codec: .aac,
        segmentDuration: 300
    )

    static func make(preset: Preset, segmentDuration: TimeInterval, sampleRate: Double = 48_000) -> RecordingProfile {
        RecordingProfile(
            preset: preset,
            sampleRate: sampleRate,
            bitRatePerChannel: preset.bitRatePerChannel,
            codec: preset.codec,
            segmentDuration: segmentDuration
        )
    }

    var effectiveBitRate: Int { bitRatePerChannel }

    /// Planning number for disk space. For AAC this is exact; for ALAC it is an estimate
    /// that lands within ~10% on speech and music.
    func bytesPerHour(channels: Int) -> Int64 {
        let channels = max(1, channels)
        switch codec {
        case .aac:
            return Int64(Double(bitRatePerChannel * channels) * 3600 / 8)
        case .alac:
            return Int64(Double(Self.pcmBytesPerHour(sampleRate: sampleRate, channels: channels)) * 0.55)
        case .pcm:
            return Self.pcmBytesPerHour(sampleRate: sampleRate, channels: channels)
        }
    }

    static func pcmBytesPerHour(sampleRate: Double, channels: Int, bitsPerSample: Int = 16) -> Int64 {
        Int64(sampleRate) * Int64(max(1, channels)) * Int64(bitsPerSample / 8) * 3600
    }
}

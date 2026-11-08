import Foundation

/// One finished file on disk. The manifest is the source of truth for "what did we
/// actually capture", which is what makes the "every second" claim checkable.
struct SegmentRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let index: Int
    let fileName: String
    let startedAt: Date
    var endedAt: Date?
    var frames: Int64
    var sampleRate: Double
    var channels: Int
    var bitRate: Int
    var codec: String
    var byteSize: Int64
    /// Wall-clock gap between the previous segment's end and this segment's start.
    /// In a healthy rotation this is sub-millisecond.
    var gapBeforeSeconds: Double
    var endReason: String?

    var audioSeconds: Double {
        sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    var wallSeconds: Double {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// A real hole in the capture: an interruption, a route change, an engine restart.
/// Durations are wall clock, not audio clock.
struct GapRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let reason: String

    var seconds: Double { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// Derived accounting for a session. `audioSeconds + gapSeconds` should equal
/// `wallSeconds` to within the length of one audio buffer.
struct CoverageSummary: Equatable {
    var wallSeconds: Double = 0
    var audioSeconds: Double = 0
    var gapSeconds: Double = 0
    var gapCount: Int = 0
    var largestGapSeconds: Double = 0

    var ratio: Double {
        guard wallSeconds > 0 else { return 0 }
        return min(1, audioSeconds / wallSeconds)
    }

    /// Seconds of the session that have no audio behind them, whether or not a gap
    /// record explains them. Non-zero means something was dropped silently.
    var unexplainedSeconds: Double {
        max(0, wallSeconds - audioSeconds - gapSeconds)
    }

    static func compute(segments: [SegmentRecord], gaps: [GapRecord]) -> CoverageSummary {
        var summary = CoverageSummary()
        summary.gapCount = gaps.count
        summary.gapSeconds = gaps.reduce(0) { $0 + $1.seconds }
        summary.largestGapSeconds = gaps.map(\.seconds).max() ?? 0
        summary.audioSeconds = segments.reduce(0) { $0 + $1.audioSeconds }

        guard let first = segments.map(\.startedAt).min() else { return summary }
        let lastEnd = segments.compactMap(\.endedAt).max() ?? Date()
        summary.wallSeconds = max(0, lastEnd.timeIntervalSince(first))
        return summary
    }
}

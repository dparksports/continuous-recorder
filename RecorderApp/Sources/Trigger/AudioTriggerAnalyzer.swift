import Foundation

/// Decides when sound becomes interesting, from a stream of dBFS levels.
///
/// The naive version of this is `level > -40 dBFS`, and it fails the first time the device
/// sits near a fridge, a fan or a road: the room is permanently above the threshold, so the
/// recorder never goes dormant, and the battery dies having recorded a fridge.
///
/// So the threshold is **relative to a slowly-tracked noise floor**, the same idea as the
/// motion classifier's two thresholds: it takes a margin above the floor to open, a smaller
/// margin for a sustained period to close, and the floor itself is frozen while open so a
/// long loud event cannot teach the analyser that loud is normal.
///
/// Pure, time-injected, no audio types — the whole thing is testable with numbers.
struct AudioTriggerAnalyzer {

    struct Configuration {
        /// How far above the floor a sample must sit to open. 12 dB is roughly "noticeably
        /// louder than the room" — a door, a voice, breaking glass.
        var openMarginDB: Double = 12
        /// How far above the floor counts as still-loud once open. Lower than the open
        /// margin so the state does not flicker at the boundary.
        var closeMarginDB: Double = 6
        /// Sustained time above the threshold. One buffer of a bang is not an event.
        var openHoldSeconds: TimeInterval = 0.15
        /// Sustained quiet before closing. Long, because a pause between sentences is not
        /// the end of a conversation.
        var closeHoldSeconds: TimeInterval = 5
        /// Time constant of the floor tracker. 200 s is slow enough to ignore passing noise
        /// and fast enough to follow a room that genuinely changes (a door left open).
        var floorTimeConstant: Double = 200
        /// Floor is clamped to this band so a silent room cannot produce an impossibly low
        /// floor that makes everything look loud.
        var floorRangeDB: ClosedRange<Double> = -80 ... -20
        /// Anything quieter than this is treated as this value; `-inf` has no useful maths.
        var silenceFloorDB: Double = -100
    }

    enum Transition: Equatable {
        case opened(level: Double, floor: Double)
        case closed(peak: Double, duration: TimeInterval)
    }

    var configuration = Configuration()

    private(set) var isOpen = false
    private(set) var noiseFloorDB: Double?
    private(set) var lastLevelDB: Double = -100

    private var aboveSince: Date?
    private var belowSince: Date?
    private var openedAt: Date?
    private var lastSampleAt: Date?
    private var peakSinceOpen: Double = -.infinity

    mutating func ingest(levelDB: Double, at date: Date) -> Transition? {
        let level = max(configuration.silenceFloorDB, levelDB)
        lastLevelDB = level

        let interval = date.timeIntervalSince(lastSampleAt ?? date)
        lastSampleAt = date

        // Freeze the floor while an event is in progress: otherwise a two-minute alarm
        // raises the floor to the alarm and the next quiet minute closes the event.
        if !isOpen {
            updateFloor(level, interval: interval)
        }

        guard let floor = noiseFloorDB else { return nil }
        let openThreshold = floor + configuration.openMarginDB
        let closeThreshold = floor + configuration.closeMarginDB

        if !isOpen {
            guard level >= openThreshold else {
                aboveSince = nil
                return nil
            }
            if aboveSince == nil { aboveSince = date }
            guard let start = aboveSince, date.timeIntervalSince(start) >= configuration.openHoldSeconds else {
                return nil
            }
            isOpen = true
            openedAt = date
            aboveSince = nil
            belowSince = nil
            peakSinceOpen = level
            return .opened(level: level, floor: floor)
        }

        peakSinceOpen = max(peakSinceOpen, level)
        guard level <= closeThreshold else {
            belowSince = nil
            return nil
        }
        if belowSince == nil { belowSince = date }
        guard let start = belowSince, date.timeIntervalSince(start) >= configuration.closeHoldSeconds else {
            return nil
        }

        let peak = peakSinceOpen.isFinite ? peakSinceOpen : level
        let duration = date.timeIntervalSince(openedAt ?? date)
        isOpen = false
        openedAt = nil
        belowSince = nil
        peakSinceOpen = -.infinity
        return .closed(peak: peak, duration: duration)
    }

    /// Forces the event closed — used on shutdown so a session does not end mid-trigger.
    mutating func reset() {
        isOpen = false
        openedAt = nil
        aboveSince = nil
        belowSince = nil
        peakSinceOpen = -.infinity
        lastSampleAt = nil
    }

    private mutating func updateFloor(_ level: Double, interval: TimeInterval) {
        guard let current = noiseFloorDB else {
            noiseFloorDB = clamp(level)
            return
        }

        if level < current {
            // Track downward immediately: a room that got quieter should be believed at once.
            noiseFloorDB = clamp(level)
            return
        }

        let dt = min(max(interval, 0.001), 5)
        let alpha = 1 - exp(-dt / max(configuration.floorTimeConstant, 1))
        noiseFloorDB = clamp(current + (level - current) * alpha)
    }

    private func clamp(_ value: Double) -> Double {
        min(configuration.floorRangeDB.upperBound,
            max(configuration.floorRangeDB.lowerBound, value))
    }
}

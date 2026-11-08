import Foundation

/// One file that will appear in the share window.
struct ShareEntry: Equatable {
    var source: URL
    /// Path relative to the recordings root, mirroring the on-device tree so two sessions
    /// that both contain `hour-00001.mp4` cannot collide.
    var relativePath: String
}

/// What a share window will contain, computed before anything touches the filesystem.
///
/// Pure on purpose: the interesting decisions (which files, what happens past the limit)
/// are testable without a device, a Keychain or a Mac.
struct SharePlan: Equatable {
    var entries: [ShareEntry]
    /// Files dropped because of the limit. Non-zero is surfaced in the UI — silently
    /// truncating an evidence export is worse than refusing it.
    var truncated: Int

    var isEmpty: Bool { entries.isEmpty }

    static func make(files: [URL], root: URL, limit: Int = 500) -> SharePlan {
        let prefix = root.standardizedFileURL.path
        var entries: [ShareEntry] = []

        for file in files {
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            var relative = String(path.dropFirst(prefix.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            entries.append(ShareEntry(source: file, relativePath: relative))
        }

        // Session directories are named `yyyy-MM-dd/HHmmss-xxxx`, so lexicographic order is
        // chronological order. Keeping the suffix keeps the newest evidence when a limit
        // forces a choice.
        entries.sort { $0.relativePath < $1.relativePath }

        if entries.count > limit {
            let dropped = entries.count - limit
            return SharePlan(entries: Array(entries.suffix(limit)), truncated: dropped)
        }
        return SharePlan(entries: entries, truncated: 0)
    }
}

/// A time-boxed window during which the recordings are visible to File Sharing.
struct ShareSession: Equatable {
    var id: UUID
    var openedAt: Date
    var expiresAt: Date
    var directory: URL
    var fileCount: Int
    var byteCount: Int64
    var truncated: Int

    func remaining(at date: Date) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(date))
    }

    func isExpired(at date: Date) -> Bool {
        remaining(at: date) <= 0
    }

    var remainingText: String {
        let seconds = Int(max(0, expiresAt.timeIntervalSinceNow))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

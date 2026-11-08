import Foundation

/// Where recordings live on disk and how much room is left.
///
/// Files go under `Library/Recordings/<yyyy-MM-dd>/<HHmmss>-<id>/` — **not** Documents, which
/// is what File Sharing exposes. Keeping the evidence out of the shared container is what
/// makes the share window meaningful: a Mac can only see the hard links an authenticated
/// session created, and those are removed when the window closes.
///
/// `LSSupportsOpeningDocumentsInPlace` is still set, so the Files app shows the app's
/// Documents folder — which, outside a share window, is empty.
struct FileStore {
    let root: URL

    static func makeDefault() throws -> FileStore {
        let library = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = library.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Earlier builds wrote into Documents, which File Sharing exposes. Move anything
        // found there so nothing is browsable without an authenticated share window.
        migrateLegacyDocumentsCopy(into: root)

        // Recordings must never be shipped to iCloud backup: they are huge, and a backup is
        // one more copy nobody is watching.
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableRoot.setResourceValues(values)

        return FileStore(root: root)
    }

    private static func migrateLegacyDocumentsCopy(into root: URL) {
        guard let documents = try? FileManager.default.url(for: .documentDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: false) else { return }
        let legacy = documents.appendingPathComponent("Recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        let items = (try? FileManager.default.contentsOfDirectory(at: legacy,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let destination = root.appendingPathComponent(item.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.moveItem(at: item, to: destination)
        }
        // Only remove the old container once it is empty of sessions.
        if ((try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    func makeSessionDirectory(at date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = root.appendingPathComponent(formatter.string(from: date), isDirectory: true)

        formatter.dateFormat = "HHmmss"
        let suffix = UUID().uuidString.prefix(4)
        let session = day.appendingPathComponent(
            "\(formatter.string(from: date))-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        return session
    }

    /// Bytes the system says we can still use for "important" writes. This is the
    /// number iOS itself uses before it starts purging caches.
    func freeBytes() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func totalBytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    func allSegmentFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "m4a" || ext == "wav" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}

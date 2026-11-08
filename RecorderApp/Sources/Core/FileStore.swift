import Foundation

/// Where recordings live on disk and how much room is left.
///
/// Files go under `Documents/Recordings/<yyyy-MM-dd>/<HHmmss>-<id>/`. Documents is
/// deliberate: with `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` in
/// Info.plist you can pull recordings off the iPad through Finder or the Files app
/// without a cable-to-Mac ritual.
struct FileStore {
    let root: URL

    static func makeDefault() throws -> FileStore {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Audio must never be shipped to iCloud backup: it is huge and nobody wants it.
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableRoot.setResourceValues(values)

        return FileStore(root: root)
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

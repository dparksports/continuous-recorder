import Foundation

/// Append-only session manifest: `session.json` for the session header, plus one JSON
/// line per segment and per gap. Append-only matters, because a process that dies
/// mid-write loses at most the last line — never the whole index.
final class ManifestStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "com.example.recorderapp.manifest")

    init(directory: URL) {
        self.directory = directory
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        decoder.dateDecodingStrategy = .iso8601
    }

    private var segmentsURL: URL { directory.appendingPathComponent("segments.jsonl") }
    private var gapsURL: URL { directory.appendingPathComponent("gaps.jsonl") }
    private var sessionURL: URL { directory.appendingPathComponent("session.json") }

    // MARK: - Writing

    func beginSession(_ session: SessionRecord) {
        writeSession(session)
    }

    func finishSession(endedAt: Date) {
        guard var session = currentSession() else { return }
        session.endedAt = endedAt
        writeSession(session)
    }

    /// Called from the audio thread on segment close, so it must not block.
    func append(_ segment: SegmentRecord) {
        let url = segmentsURL
        let encoder = self.encoder
        queue.async {
            Self.appendLine(segment, to: url, encoder: encoder)
        }
    }

    func append(_ gap: GapRecord) {
        let url = gapsURL
        let encoder = self.encoder
        queue.async {
            Self.appendLine(gap, to: url, encoder: encoder)
        }
    }

    // MARK: - Reading

    func currentSession() -> SessionRecord? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    func loadSegments() -> [SegmentRecord] {
        readLines(SegmentRecord.self, from: segmentsURL)
    }

    func loadGaps() -> [GapRecord] {
        readLines(GapRecord.self, from: gapsURL)
    }

    // MARK: - Implementation

    private func writeSession(_ session: SessionRecord) {
        do {
            let data = try encoder.encode(session)
            try data.write(to: sessionURL, options: .atomic)
        } catch {
            Log.storage.error("session.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func appendLine<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) {
        do {
            var data = try encoder.encode(value)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Log.storage.error("manifest append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(T.self, from: Data(line))
        }
    }
}

struct SessionRecord: Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var segments: Int = 0
}

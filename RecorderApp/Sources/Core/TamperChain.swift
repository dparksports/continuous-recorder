import CryptoKit
import Foundation

/// One link in the evidence chain. The payload is what gets signed; the signature travels
/// beside it so the payload bytes never change after signing.
struct ChainPayload: Codable, Equatable {
    var index: Int
    var fileName: String
    var relativePath: String
    var byteSize: Int64
    var sha256Hex: String
    var previousHashHex: String
    var recordedAt: Date
    /// Integers, not Doubles: a float's textual form is not reproducible across
    /// languages (`3600` vs `3600.0`), and the signature covers these exact bytes.
    var durationMilliseconds: Int
    var bootID: String
    var monotonicMilliseconds: Int
}

struct ChainLink: Codable, Equatable {
    var payload: ChainPayload
    var signatureBase64: String
    var signerID: String

    var signature: Data? { Data(base64Encoded: signatureBase64) }
}

// MARK: - Canonical encoding

extension ChainPayload {
    static let genesisHash = String(repeating: "0", count: 64)

    /// ISO-8601 with milliseconds, always UTC. Fixed precision matters: a verifier in
    /// another language must be able to reproduce these bytes exactly.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Sorted keys, no escaped slashes, fixed timestamps. Same bytes here, on the server,
    /// and in a Python verifier — which is the whole point of a chain.
    func canonicalBytes() throws -> Data {
        try ChainCoding.encoder().encode(self)
    }

    func hashHex() throws -> String {
        FileDigest.hex(SHA256.hash(data: try canonicalBytes()))
    }
}

enum ChainCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ChainPayload.timestamp(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ChainPayload.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "bad timestamp \(string)")
            }
            return date
        }
        return decoder
    }
}

// MARK: - Hashing

enum FileDigest {
    /// Streaming SHA-256. An hour of 1080p is ~2 GB; never load it into memory.
    static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Writer

/// Appends one signed link per closed media file.
///
/// The guarantee, stated precisely: **given a link and the public key, the file it names
/// has not been modified since it was written, and it followed the link before it.**
/// It does not make files undeletable — deleting the whole directory is trivially possible
/// for anyone with the device. Deleting a *middle* file breaks the chain; deleting the
/// *tail* is only detectable against a copy kept elsewhere, which is why the chain head
/// must be shipped off-device (see Docs/TAMPER-EVIDENCE.md).
final class TamperChain {

    private let directory: URL
    private let signer: LinkSigner
    private let bootID = UUID().uuidString
    private let lock = NSLock()

    private var lastHashHex = ChainPayload.genesisHash
    private var nextIndex = 1

    init(directory: URL, signer: LinkSigner) {
        self.directory = directory
        self.signer = signer
    }

    var chainURL: URL { directory.appendingPathComponent("chain.jsonl") }

    /// Must be called after the media file is closed and finalised, never before: the hash
    /// has to cover the finished container, not a file still being written.
    @discardableResult
    func append(fileAt url: URL,
                relativePath: String,
                durationSeconds: Double,
                at date: Date = Date()) throws -> ChainLink {
        let sha256Hex = try FileDigest.sha256Hex(of: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        lock.lock()
        defer { lock.unlock() }

        let payload = ChainPayload(
            index: nextIndex,
            fileName: url.lastPathComponent,
            relativePath: relativePath,
            byteSize: byteSize,
            sha256Hex: sha256Hex,
            previousHashHex: lastHashHex,
            recordedAt: date,
            durationMilliseconds: Int((durationSeconds * 1000).rounded()),
            bootID: bootID,
            monotonicMilliseconds: Int((ProcessInfo.processInfo.systemUptime * 1000).rounded())
        )

        let canonical = try payload.canonicalBytes()
        let signature = try signer.sign(canonical)

        let link = ChainLink(
            payload: payload,
            signatureBase64: signature.base64EncodedString(),
            signerID: signer.identifier
        )

        lastHashHex = try payload.hashHex()
        nextIndex += 1
        try appendLine(link)
        return link
    }

    func links() -> [ChainLink] {
        guard let data = try? Data(contentsOf: chainURL) else { return [] }
        let decoder = ChainCoding.decoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(ChainLink.self, from: Data(line))
        }
    }

    private func appendLine(_ link: ChainLink) throws {
        var data = try ChainCoding.encoder().encode(link)
        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: chainURL.path) {
            _ = FileManager.default.createFile(atPath: chainURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: chainURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

// MARK: - Verifier

struct ChainReport {
    var linkCount = 0
    var problems: [String] = []
    var warnings: [String] = []

    var isIntact: Bool { problems.isEmpty }
}

enum ChainVerifier {

    /// Structural, cryptographic and (optionally) content verification.
    /// Run this off-device for the authoritative answer; the on-device copy can be
    /// trusted only as a convenience check.
    static func verify(links: [ChainLink],
                       publicKeyX963: Data?,
                       directory: URL? = nil) -> ChainReport {
        var report = ChainReport()
        report.linkCount = links.count

        guard !links.isEmpty else {
            report.problems.append("chain is empty")
            return report
        }

        var previousHash = ChainPayload.genesisHash

        for (offset, link) in links.enumerated() {
            let expected = offset + 1
            if link.payload.index != expected {
                report.problems.append("link \(offset + 1): expected index \(expected), found \(link.payload.index)")
            }
            if link.payload.previousHashHex != previousHash {
                report.problems.append("link \(link.payload.index): previous hash does not match — a link was removed or reordered")
            }
            if link.signerID != "secure-enclave-p256" {
                report.warnings.append("link \(link.payload.index): signed by \(link.signerID), not the Secure Enclave")
            }

            guard let canonical = try? link.payload.canonicalBytes() else {
                report.problems.append("link \(link.payload.index): payload cannot be canonicalised")
                previousHash = ""
                continue
            }

            if let publicKeyX963 {
                if let signature = link.signature {
                    if !ChainSignature.verify(payload: canonical,
                                              signatureDER: signature,
                                              publicKeyX963: publicKeyX963) {
                        report.problems.append("link \(link.payload.index): signature does not verify")
                    }
                } else {
                    report.problems.append("link \(link.payload.index): signature is not valid base64")
                }
            }

            if let directory {
                let url = directory.appendingPathComponent(link.payload.relativePath)
                if !FileManager.default.fileExists(atPath: url.path) {
                    report.problems.append("link \(link.payload.index): file is missing (\(link.payload.relativePath))")
                } else if let actual = try? FileDigest.sha256Hex(of: url) {
                    if actual != link.payload.sha256Hex {
                        report.problems.append("link \(link.payload.index): file content changed since signing")
                    }
                } else {
                    report.problems.append("link \(link.payload.index): file could not be read")
                }
            }

            previousHash = (try? link.payload.hashHex()) ?? ""
        }

        return report
    }
}

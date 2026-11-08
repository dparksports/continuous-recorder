import XCTest
@testable import RecorderApp

final class TamperChainTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(named name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeChain(count: Int) throws -> (TamperChain, SoftwareSigner, [URL]) {
        let signer = SoftwareSigner()
        let chain = TamperChain(directory: directory, signer: signer)
        var files: [URL] = []
        for index in 1...count {
            let url = try makeFile(named: "hour-\(index).mp4", contents: "payload-\(index)")
            try chain.append(fileAt: url, relativePath: url.lastPathComponent, durationSeconds: 3600)
            files.append(url)
        }
        return (chain, signer, files)
    }

    func testIntactChainVerifies() throws {
        let (chain, signer, _) = try makeChain(count: 3)
        let links = chain.links()
        XCTAssertEqual(links.count, 3)

        let report = ChainVerifier.verify(links: links,
                                          publicKeyX963: signer.publicKeyX963,
                                          directory: directory)
        XCTAssertTrue(report.isIntact, "unexpected problems: \(report.problems)")
        XCTAssertEqual(report.linkCount, 3)
        XCTAssertFalse(report.warnings.isEmpty) // software signer is flagged, by design
    }

    func testChangingOneByteIsDetected() throws {
        let (chain, signer, files) = try makeChain(count: 2)
        try Data("tampered".utf8).write(to: files[0])

        let report = ChainVerifier.verify(links: chain.links(),
                                          publicKeyX963: signer.publicKeyX963,
                                          directory: directory)
        XCTAssertFalse(report.isIntact)
        XCTAssertTrue(report.problems.contains { $0.contains("file content changed") },
                      "got \(report.problems)")
    }

    func testRemovingAMiddleLinkBreaksTheChain() throws {
        let (chain, signer, _) = try makeChain(count: 3)
        var links = chain.links()
        links.remove(at: 1)

        let report = ChainVerifier.verify(links: links, publicKeyX963: signer.publicKeyX963)
        XCTAssertFalse(report.isIntact)
        XCTAssertTrue(report.problems.contains { $0.contains("previous hash does not match") },
                      "got \(report.problems)")
    }

    func testEditingThePayloadInvalidatesTheSignature() throws {
        let (chain, signer, _) = try makeChain(count: 2)
        var links = chain.links()
        links[1].payload.recordedAt = Date(timeIntervalSince1970: 0)

        let report = ChainVerifier.verify(links: links, publicKeyX963: signer.publicKeyX963)
        XCTAssertFalse(report.isIntact)
    }

    func testDeletingTheLastLinkIsInvisibleLocally() throws {
        // This is the documented limitation, asserted so nobody "fixes" it by accident:
        // a truncated chain is internally consistent. Only an off-device copy of the head
        // can reveal it.
        let (chain, signer, _) = try makeChain(count: 3)
        var links = chain.links()
        links.removeLast()

        let report = ChainVerifier.verify(links: links, publicKeyX963: signer.publicKeyX963)
        XCTAssertTrue(report.isIntact)
    }

    func testTranscriptSurvivesJSONRoundTrip() throws {
        let (chain, signer, _) = try makeChain(count: 2)
        let links = chain.links()

        let data = try ChainCoding.encoder().encode(links)
        let decoded = try ChainCoding.decoder().decode([ChainLink].self, from: data)

        XCTAssertEqual(decoded, links)
        XCTAssertTrue(ChainVerifier.verify(links: decoded,
                                           publicKeyX963: signer.publicKeyX963,
                                           directory: directory).isIntact)
    }
}

import XCTest
@testable import RecorderApp

final class SharePlanTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)

    private func file(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    func testMirrorsTheOnDeviceTree() {
        let files = [
            file("2026-11-08/093012-abcd/video/hour-00001.mp4"),
            file("2026-11-08/093012-abcd/segments.jsonl"),
            file("2026-11-07/220145-ef01/video/hour-00009.mp4")
        ]
        let plan = SharePlan.make(files: files, root: root, limit: 100)

        XCTAssertEqual(plan.entries.map(\.relativePath), [
            "2026-11-07/220145-ef01/video/hour-00009.mp4",
            "2026-11-08/093012-abcd/segments.jsonl",
            "2026-11-08/093012-abcd/video/hour-00001.mp4"
        ])
        XCTAssertEqual(plan.truncated, 0)
        XCTAssertFalse(plan.isEmpty)
    }

    func testIdenticalFileNamesInDifferentSessionsDoNotCollide() {
        let files = [
            file("2026-11-08/090000-aaaa/video/hour-00001.mp4"),
            file("2026-11-08/100000-bbbb/video/hour-00001.mp4")
        ]
        let plan = SharePlan.make(files: files, root: root, limit: 10)
        let paths = Set(plan.entries.map(\.relativePath))
        XCTAssertEqual(paths.count, 2, "relative paths must stay unique")
    }

    func testFilesOutsideTheRootAreIgnored() {
        let files = [
            file("2026-11-08/093012-abcd/video/hour-00001.mp4"),
            URL(fileURLWithPath: "/tmp/somewhere-else/evil.mp4")
        ]
        let plan = SharePlan.make(files: files, root: root, limit: 10)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertTrue(plan.entries[0].relativePath.hasPrefix("2026-11-08/"))
    }

    func testLimitKeepsTheNewestEvidenceAndReportsTheLoss() {
        // Session folders sort chronologically, so truncation must drop the oldest.
        let files = (1...10).map { day in
            file(String(format: "2026-11-%02d/090000-aaaa/video/hour-00001.mp4", day))
        }
        let plan = SharePlan.make(files: files, root: root, limit: 4)

        XCTAssertEqual(plan.entries.count, 4)
        XCTAssertEqual(plan.truncated, 6)
        XCTAssertTrue(plan.entries.first?.relativePath.hasPrefix("2026-11-07") == true)
    }

    func testEmptyLibraryProducesAnEmptyPlan() {
        let plan = SharePlan.make(files: [], root: root, limit: 10)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.truncated, 0)
    }
}

final class ShareSessionTests: XCTestCase {

    private func session(opened: Date, duration: TimeInterval) -> ShareSession {
        ShareSession(
            id: UUID(),
            openedAt: opened,
            expiresAt: opened.addingTimeInterval(duration),
            directory: URL(fileURLWithPath: "/tmp/share"),
            fileCount: 3,
            byteCount: 1024,
            truncated: 0
        )
    }

    func testRemainingCountsDownAndStopsAtZero() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = session(opened: start, duration: 600)

        XCTAssertEqual(session.remaining(at: start), 600, accuracy: 0.001)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(90)), 510, accuracy: 0.001)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(900)), 0)
    }

    func testExpiryBoundary() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = session(opened: start, duration: 60)

        XCTAssertFalse(session.isExpired(at: start.addingTimeInterval(59)))
        XCTAssertTrue(session.isExpired(at: start.addingTimeInterval(61)))
    }
}

final class EvidenceShareControllerTests: XCTestCase {

    /// The seam exists so the share controller can be driven in tests without a Keychain
    /// prompt; this asserts the contract the controller relies on.
    @MainActor
    func testControllerRefusesWhenNoCredentialIsRegistered() async {
        let controller = EvidenceShareController(
            recordingsRoot: FileManager.default.temporaryDirectory,
            shareRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            authenticator: UnavailableAuthenticator()
        )

        await controller.open()

        XCTAssertFalse(controller.isOpen)
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.lastError?.contains("passcode") == true,
                      "got \(controller.lastError ?? "nil")")
    }

    @MainActor
    func testNoShareDirectorySurvivesWhenNothingWasOpened() {
        let shareRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = EvidenceShareController(
            recordingsRoot: FileManager.default.temporaryDirectory,
            shareRoot: shareRoot,
            authenticator: UnavailableAuthenticator()
        )
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: shareRoot.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }
}

private final class UnavailableAuthenticator: DeviceAuthenticating {
    var methodName: String? { nil }
    var isAvailable: Bool { false }
    func authenticate(reason: String) async -> AuthenticationOutcome { .unavailable }
}

import Combine
import Foundation
import UIKit

/// Gates Mac access to the recordings behind device-owner authentication.
///
/// The mechanism, and why it is not a plist flag: `UIFileSharingEnabled` is read once at
/// launch, so it cannot be switched on after Face ID succeeds. What *can* be gated is the
/// contents. Recordings live in `Library/Recordings`, which File Sharing never exposes.
/// Opening a share window creates **hard links** under `Documents/Share/<stamp>/` — instant
/// even for gigabytes, no extra disk, and unlinking them cannot touch the originals. Close
/// the window and the Mac's view of the evidence disappears; the evidence does not.
///
/// The window closes on expiry, on backgrounding, and when the device locks. Locking while a
/// Mac is mid-copy will abort the transfer — that is the intended trade, and the reason the
/// UI shows a countdown.
@MainActor
final class EvidenceShareController: ObservableObject {

    struct Configuration {
        /// Ten minutes is enough to pull a day of 1080p over Wi-Fi and short enough that a
        /// forgotten window is not an incident.
        var duration: TimeInterval = 600
        /// Guard against linking a year of segments into one folder.
        var fileLimit = 500

        static let `default` = Configuration()
    }

    @Published private(set) var session: ShareSession?
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var methodName: String?

    var isOpen: Bool { session != nil }

    private let authenticator: DeviceAuthenticating
    private let recordingsRoot: URL
    private let shareRoot: URL
    private let configuration: Configuration

    private var expiryTimer: Timer?
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(recordingsRoot: URL,
         shareRoot: URL? = nil,
         authenticator: DeviceAuthenticating = LocalAuthenticator(),
         configuration: Configuration = .default) {
        self.recordingsRoot = recordingsRoot
        self.authenticator = authenticator
        self.configuration = configuration

        let documents = (try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.shareRoot = shareRoot ?? documents.appendingPathComponent("Share", isDirectory: true)

        methodName = authenticator.methodName
        purgeStale()
        observe()
    }

    // MARK: - Open / close

    func open() async {
        guard session == nil, !isAuthenticating else { return }

        guard let method = authenticator.methodName else {
            lastError = """
            This device has no passcode or biometrics set up, so recordings cannot be \
            unlocked for transfer. Set a passcode in Settings to enable sharing.
            """
            return
        }

        methodName = method
        isAuthenticating = true
        let outcome = await authenticator.authenticate(
            reason: "Unlock recorded video so your Mac can copy it"
        )
        isAuthenticating = false

        switch outcome {
        case .success:
            do {
                try buildWindow()
            } catch {
                lastError = error.localizedDescription
            }
        case .cancelled:
            return
        case .failed(let message):
            lastError = message
        case .unavailable:
            lastError = "\(method) is unavailable right now. Unlock the device and try again."
        }
    }

    func close(reason: String) {
        guard let session else { return }

        try? FileManager.default.removeItem(at: session.directory)
        record("share closed (\(reason)): \(session.fileCount) files")

        expiryTimer?.invalidate()
        expiryTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil

        self.session = nil
        secondsRemaining = 0
    }

    /// Removes any window left behind by a crash or a force-quit. Called at launch and before
    /// every new window, so a stale folder can never be the thing a Mac sees.
    func purgeStale() {
        guard session == nil else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: shareRoot,
            includingPropertiesForKeys: nil
        ) else { return }

        for item in items where item.lastPathComponent != ".keep" {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Building the window

    private func buildWindow() throws {
        purgeStale()

        let files = collectFiles()
        let plan = SharePlan.make(files: files, root: recordingsRoot, limit: configuration.fileLimit)
        guard !plan.isEmpty else {
            lastError = "There are no recordings to share yet."
            return
        }

        let stamp = Self.stamp(Date())
        let directory = shareRoot.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var bytes: Int64 = 0
        var linked = 0
        for entry in plan.entries {
            let destination = directory.appendingPathComponent(entry.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: entry.source, to: destination)
                linked += 1
                bytes += Self.size(of: entry.source)
            } catch {
                // A hard link can fail on a full volume or a resource fork oddity; a copy is
                // still correct, just not free.
                if (try? FileManager.default.copyItem(at: entry.source, to: destination)) != nil {
                    linked += 1
                    bytes += Self.size(of: entry.source)
                }
            }
        }

        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let now = Date()
        session = ShareSession(
            id: UUID(),
            openedAt: now,
            expiresAt: now.addingTimeInterval(configuration.duration),
            directory: directory,
            fileCount: linked,
            byteCount: bytes,
            truncated: plan.truncated
        )
        secondsRemaining = Int(configuration.duration)

        scheduleTimers()
        record("share opened: \(linked) files, \(bytes) bytes, truncated \(plan.truncated)")
        Log.storage.notice("share window open at \(directory.path, privacy: .public)")
    }

    private func collectFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: - Timers and lifecycle

    private func scheduleTimers() {
        expiryTimer?.invalidate()
        tickTimer?.invalidate()

        let expiry = Timer.scheduledTimer(withTimeInterval: configuration.duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close(reason: "expired") }
        }
        expiry.tolerance = 1
        expiryTimer = expiry

        let tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick.tolerance = 0.25
        tickTimer = tick
    }

    private func tick() {
        guard let session else { return }
        secondsRemaining = Int(session.remaining(at: Date()))
        if session.isExpired(at: Date()) {
            close(reason: "expired")
        }
    }

    private func observe() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close(reason: "app backgrounded") }
        })

        // Fires when the device locks with a passcode set. The Mac's copy dies with the
        // window; that is deliberate.
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close(reason: "device locked") }
        })
    }

    // MARK: - Access log

    private struct AccessRecord: Codable {
        var at: Date
        var event: String
    }

    private func record(_ message: String) {
        let url = recordingsRoot.appendingPathComponent("share-access.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(AccessRecord(at: Date(), event: message)) else { return }
        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - Helpers

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}

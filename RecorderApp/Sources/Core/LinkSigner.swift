import CryptoKit
import Foundation
import Security

/// Signs a chain link. Two implementations:
///
/// - `SecureEnclaveSigner` — ECDSA P-256, private key generated inside the Secure Enclave,
///   non-exportable, usable only while the device is unlocked after first boot. This is the
///   real one: an attacker who copies the filesystem cannot forge a link, because the key
///   never exists in memory or on disk.
/// - `SoftwareSigner` — CryptoKit key in process memory. Used on the simulator and in unit
///   tests, where the Secure Enclave does not exist. Links signed this way are recorded with
///   `signerID = "software-p256"` so a verifier can refuse them.
protocol LinkSigner: AnyObject {
    var identifier: String { get }
    /// X9.63 uncompressed point (65 bytes), or nil if the key could not be created.
    var publicKeyX963: Data? { get }
    /// DER-encoded ECDSA signature over SHA-256 of `data`.
    func sign(_ data: Data) throws -> Data
}

// MARK: - Secure Enclave

final class SecureEnclaveSigner: LinkSigner {

    enum SignerError: LocalizedError {
        case keyUnavailable(String)
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .keyUnavailable(let message): return "Secure Enclave key unavailable: \(message)"
            case .signingFailed(let message):  return "Secure Enclave signing failed: \(message)"
            }
        }
    }

    let identifier = "secure-enclave-p256"

    private let tag: Data
    private let key: SecKey?
    private(set) var publicKeyX963: Data?

    /// `tag` is the Keychain application tag. Change it to rotate the identity; existing
    /// chains will then verify against the old public key, which is the point.
    init(tag: String = "com.example.recorderapp.chain.signing") {
        self.tag = Data(tag.utf8)
        let key = try? SecureEnclaveSigner.loadOrCreateKey(tag: self.tag)
        self.key = key
        self.publicKeyX963 = key.flatMap(SecureEnclaveSigner.externalPublicKey)
    }

    var isAvailable: Bool { key != nil && publicKeyX963 != nil }

    func sign(_ data: Data) throws -> Data {
        guard let key else { throw SignerError.keyUnavailable("no private key on this device") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            let message = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "unknown"
            throw SignerError.signingFailed(message)
        }
        return signature as Data
    }

    // MARK: - Keychain

    private static func loadOrCreateKey(tag: Data) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
            return item as! SecKey
        }
        return try createKey(tag: tag)
    }

    private static func createKey(tag: Data) throws -> SecKey {
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil
        ) else {
            throw SignerError.keyUnavailable("could not build an access control object")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: accessControl
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "unknown"
            throw SignerError.keyUnavailable(message)
        }
        return key
    }

    private static func externalPublicKey(_ key: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(key) else { return nil }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) else { return nil }
        return data as Data
    }
}

// MARK: - Software (simulator + tests)

final class SoftwareSigner: LinkSigner {
    let identifier = "software-p256"

    private let key: P256.Signing.PrivateKey

    init() {
        key = P256.Signing.PrivateKey()
    }

    var publicKeyX963: Data? { key.publicKey.x963Representation }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

// MARK: - Verification

enum ChainSignature {
    /// Verifies an ECDSA P-256 / SHA-256 signature produced either by the Secure Enclave
    /// (`SecKeyCreateSignature`) or by CryptoKit. Both emit DER, so one path covers both.
    static func verify(payload: Data, signatureDER: Data, publicKeyX963: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureDER) else {
            return false
        }
        return key.isValidSignature(signature, for: payload)
    }
}

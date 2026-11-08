import Foundation
import LocalAuthentication

/// The authentication seam, so the share controller can be tested without a Keychain prompt
/// interrupting the test run.
protocol DeviceAuthenticating: AnyObject {
    /// Human-readable name of what the owner will be asked for, or nil when this device has
    /// no passcode and therefore cannot gate anything.
    var methodName: String? { get }

    var isAvailable: Bool { get }

    func authenticate(reason: String) async -> AuthenticationOutcome
}

enum AuthenticationOutcome: Equatable {
    case success
    case cancelled
    case failed(String)
    case unavailable
}

/// Face ID / Touch ID with the device passcode as fallback — `.deviceOwnerAuthentication`,
/// not `.deviceOwnerAuthenticationWithBiometrics`, because the requirement is "password **or**
/// fingerprint". Swap the policy if you want to refuse the passcode path.
final class LocalAuthenticator: DeviceAuthenticating {

    /// Reuse window for the biometry evaluation. Zero means every unlock prompts, which is
    /// what you want for a kiosk; a small value is kinder in a lab.
    var reusableFor: TimeInterval = 0

    var methodName: String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return nil
        }
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .none:    return "device passcode"
        @unknown default: return "device passcode"
        }
    }

    var isAvailable: Bool { methodName != nil }

    func authenticate(reason: String) async -> AuthenticationOutcome {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"
        if reusableFor > 0 {
            context.touchIDAuthenticationAllowableReuseDuration = reusableFor
        }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set, or biometrics wiped by failed attempts. "If it is registered"
            // resolves here, and the answer is no.
            return .unavailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return success ? .success : .cancelled
        } catch let authError as LAError {
            switch authError.code {
            case .userCancel, .systemCancel, .appCancel:
                return .cancelled
            case .authenticationFailed:
                return .failed("Authentication failed.")
            case .biometryLockout:
                return .failed("Biometrics are locked out. Unlock the device with its passcode, then try again.")
            case .passcodeNotSet, .biometryNotEnrolled, .biometryNotAvailable:
                return .unavailable
            default:
                return .failed(authError.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

import UIKit

/// The honest version of "turn the display off".
///
/// What iOS allows:
/// - `UIScreen.brightness` can be driven to `0`, which parks the backlight at its
///   minimum. That is a real saving — roughly 0.3–0.5 W on an 11-inch iPad Air — but the
///   panel is still lit, still scanned, and still costing you something.
/// - There is no public API that powers the panel down. The only thing that does is
///   locking the device — and locking suspends camera capture, so a video recorder cannot
///   use it.
///
/// What this means in practice:
/// - **Audio-only sessions** should lock the screen. The audio path keeps running under
///   the `audio` background mode, and the panel really does go dark. That is the 118-hour
///   case in Docs/RUNTIME-ESTIMATE.md.
/// - **Video sessions** must stay frontmost. The best available setting is brightness 0,
///   a black UI, no preview layer, and a lower frame rate. Budget ~0.35 W for the panel
///   instead of ~0.55 W at 25%.
///
/// The brightness change is global while the app is active, so it is saved and restored:
/// leaving the device at 0 for the next user would be a nasty surprise.
@MainActor
final class DisplayGovernor {

    private var savedBrightness: CGFloat?
    private var savedIdleTimerState: Bool = false

    var isDimmed: Bool { savedBrightness != nil }

    /// Call when a foreground video session starts.
    func enterSurveillanceMode() {
        guard savedBrightness == nil else { return }
        let screen = UIScreen.main
        savedBrightness = screen.brightness
        savedIdleTimerState = UIApplication.shared.isIdleTimerDisabled

        screen.brightness = 0
        // The screen must not auto-lock during capture — auto-lock would stop the camera.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func exitSurveillanceMode() {
        guard let brightness = savedBrightness else { return }
        UIScreen.main.brightness = brightness
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimerState
        savedBrightness = nil
    }

    /// iOS restores the user's brightness when the app resigns active, but it does not
    /// guarantee it on every path (interruptions, crash). Call this from `scenePhase`
    /// changes so the setting cannot leak.
    func restoreIfNeeded() {
        guard isDimmed else { return }
        if UIApplication.shared.applicationState != .active {
            exitSurveillanceMode()
        }
    }
}

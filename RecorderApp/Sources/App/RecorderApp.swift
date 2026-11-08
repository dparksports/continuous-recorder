import SwiftUI
import UIKit

@main
struct ContinuousRecorderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

/// Minimal delegate: SwiftUI has no equivalent hook for "the process is about to die",
/// and that hook is the last chance to finalise the open audio container.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Battery monitoring is opt-in and costs nothing measurable; without it
        // `batteryLevel` stays -1 and the power governor has no input.
        UIDevice.current.isBatteryMonitoringEnabled = true
        Log.app.notice("launched")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Recording keeps the process alive via the audio background mode, so this is
        // only about logging the transition — no background-task dance needed.
        Log.app.notice("entered background; capture continues")
    }
}

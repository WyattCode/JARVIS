import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Backups left in the temporary folder by a killed run must not linger.
    FilesService.shared.clearLeftovers()
    // The covers kept in memory go with the videos when the local data is cleared.
    LocalData.onCleared = { Task { @MainActor in VideoCover.forget() } }
    // Videos kept for the cover and the player: those not looked at for a week, and the oldest past a size, go.
    DispatchQueue.global(qos: .utility).async { VideoCover.sweep() }
    // A test item an earlier build left in one phone's keychain.
    if BiometricLogin.savedUsername == "selftest" { BiometricLogin.remove() }
    return true
  }
}

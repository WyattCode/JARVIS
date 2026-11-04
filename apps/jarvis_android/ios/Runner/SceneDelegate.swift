import UIKit

/// The app's one window: the sign-in or the chat, decided by the store (`NativeAppRootViewController`).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    // What shows wherever nothing is drawn yet (a rotation, the first frame): the app's colour, never white.
    window.backgroundColor = UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
        : UIColor(red: 249 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
    }
    // The light or dark the person chose, known before anything is read: the window starts in it, so that applying it later does
    // not flash the app's first frames.
    switch UserDefaults.standard.string(forKey: "jarvis.theme") {
    case "light": window.overrideUserInterfaceStyle = .light
    case "dark": window.overrideUserInterfaceStyle = .dark
    default: break
    }
    self.window = window
    #if DEBUG
      if NativeChatPreview.install(on: window) { return window.makeKeyAndVisible() }
    #endif
    window.rootViewController = NativeApp.makeRoot() ?? UIViewController()
    window.makeKeyAndVisible()
  }
}

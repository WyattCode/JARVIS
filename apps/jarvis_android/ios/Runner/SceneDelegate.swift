import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

}

/// The app's one view controller. Wherever Flutter has not drawn yet (a rotation, the first frame) the app's own colour
/// shows, never the storyboard's white.
final class JarvisViewController: FlutterViewController {
  private static let background = UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
      : UIColor(red: 249 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // What shows wherever Flutter has not drawn yet (a rotation, the first frame): the app's colour, never white.
    view.backgroundColor = Self.background
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    view.window?.backgroundColor = Self.background
  }
}

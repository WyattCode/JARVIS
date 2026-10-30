import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audio = AudioBridge()
  private let vault = VaultBridge()
  private let files = FilesBridge()
  private let duo = DuoLayoutBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Native channels shared with the Android build: ai.jarvis.app/{audio,audio-events,vault,files}.
    // ai.jarvis.app/layout is intentionally absent; the Dart side only calls it on Android.
    // ai.jarvis.app/duo{,-events} is iOS-only: iPhone Duo vertical-bar edge and reserved regions.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "JarvisNative") else { return }
    let messenger = registrar.messenger()
    audio.register(with: messenger)
    vault.register(with: messenger)
    files.register(with: messenger)
    duo.register(with: messenger)
    duo.start()
    // The window follows the app's own light/dark choice ("light", "dark", or "system" for the device's).
    FlutterMethodChannel(name: "ai.jarvis.app/appearance", binaryMessenger: messenger).setMethodCallHandler {
      call, result in
      guard call.method == "set" else { return result(FlutterMethodNotImplemented) }
      let style: UIUserInterfaceStyle =
        switch call.arguments as? String {
        case "dark": .dark
        case "light": .light
        default: .unspecified
        }
      DispatchQueue.main.async {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
          for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
        result(nil)
      }
    }
    registrar.register(DuoRailFactory(messenger: messenger), withId: "ai.jarvis.app/duo-rail")
  }
}

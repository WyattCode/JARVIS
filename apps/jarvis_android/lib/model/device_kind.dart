import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone is: one that folds, or a straight one. The iOS app treats the
/// two differently all through (the drawer, the columns, the welcome page, the
/// call page), and decides it from the system, not from the shape of the
/// window: a straight phone in landscape is wide, a foldable's outer display
/// is nearly square, and neither says what the device is.
class DeviceKind {
  /// True on a folding phone, false on a straight one, null while it is not
  /// known (before the probe has answered, in tests, on other platforms): the
  /// layout then falls back to guessing from the window's shape.
  static bool? foldable;

  static const _channel = MethodChannel('cc.odn.jarvis/layout');

  /// Asks the system once. A folding phone has a hinge-angle sensor.
  static Future<void> probe() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      foldable = await _channel.invokeMethod<bool>('foldable');
    } on MissingPluginException {
      // No Android window (a test): the layout guesses from the window.
    } on PlatformException {
      // The same: a wrong guess is better than a failed start.
    }
  }

  @visibleForTesting
  static void reset() => foldable = null;
}

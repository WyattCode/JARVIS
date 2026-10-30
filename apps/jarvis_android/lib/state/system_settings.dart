import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'attachments.dart';

/// Opens this app's page in the system settings (e.g. to allow the microphone). False when the platform cannot.
Future<bool> openAppSettings() async {
  try {
    return await NativeFiles.channel.invokeMethod<bool>('openAppSettings') ??
        false;
  } on MissingPluginException {
    // A native side without the method: carry on with the platform's own way below.
  } on PlatformException {
    return false;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      return await launchUrl(Uri.parse('app-settings:'));
    } catch (_) {
      return false;
    }
  }
  return false;
}

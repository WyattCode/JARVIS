import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart' show JarvisTransport;
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/vault.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'c2_support.dart';
import 'support.dart';
import 'voice_support.dart';

/// A speech engine whose preview clip arrives when the test says so.
class PreviewApi extends SpeechApi {
  final clip = Completer<Uint8List>();
  int previews = 0;
  @override
  Future<Uint8List> preview(VoiceInfo voice, String model) {
    previews++;
    return clip.future;
  }
}

/// A microphone that was refused.
class DeniedAudio extends FakeAudio {
  @override
  Future<bool> microphonePermission() async => false;
}

/// Every haptic the page asks for, by type.
List<String> recordHaptics(WidgetTester t) {
  final calls = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String);
      }
      return null;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

/// A saved file that cannot be read: the controller starts read-only.
class UnreadableVault extends MemoryVault {
  @override
  Future<String?> read() async => throw Exception('cannot decrypt');
}

Future<JarvisController> pumpSettings3(
  WidgetTester t, {
  Size size = const Size(402, 874),
  EdgeInsets insets = const EdgeInsets.only(top: 62, bottom: 34),
  DuoLayout layout = DuoLayout.none,
  double scale = 1,
  Brightness brightness = Brightness.light,
  JarvisTransport? api,
  Future<bool> Function()? onLogoutAndClear,
  Vault? vault,
}) async {
  sizeWindow(t, size, insets);
  final c = JarvisController(
    api ?? SpeechApi(),
    vault ?? MemoryVault(),
    audioDevice: FakeAudio(),
  );
  await c.initialize();
  await c.login('user', 'test');
  await t.pumpWidget(
    withLayout(
      layout,
      appHost(
        SettingsPage(controller: c, onLogoutAndClear: onLogoutAndClear),
        scale: scale,
        brightness: brightness,
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

/// Ends a test that changed settings: a pending save timer needs the tree gone first.
Future<void> end(WidgetTester t, JarvisController c) async {
  await t.pumpWidget(const SizedBox());
  c.dispose();
}

/// Scrolls the settings page until [text] is on screen, clear of the frosted bar and the home indicator.
Future<void> reveal(WidgetTester t, String text) async {
  await t.scrollUntilVisible(
    find.text(text),
    300,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('settings-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  final height = t.view.physicalSize.height / t.view.devicePixelRatio;
  final r = t.getRect(find.text(text));
  final scroll = find.byKey(const Key('settings-scroll'));
  if (r.top < 160) {
    await t.drag(scroll, Offset(0, 200 - r.top));
  } else if (r.bottom > height - 140) {
    await t.drag(scroll, Offset(0, height - 160 - r.bottom));
  }
  await t.pump();
}

/// Half-folded in landscape, the content starts right of the crease.
const rightPane = (left: 495.5, right: 867.0);

Rect dialogSurface(WidgetTester t) => t.getRect(
  find
      .descendant(of: find.byType(AlertDialog), matching: find.byType(Material))
      .first,
);

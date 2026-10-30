import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'duo_rail_test.dart' show pumpHome;
import 'support.dart';

void main() {
  testWidgets(
    'a straight iPhone: settings run under the home indicator with a soft fade',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpHome(
          t,
          DuoLayout.none,
          size: const Size(440, 956),
          insets: const EdgeInsets.only(top: 62, bottom: 34),
        );
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        addTearDown(c.dispose);
        unawaited(
          t
              .state<NavigatorState>(find.byType(Navigator).first)
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(controller: c),
                ),
              ),
        );
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(t.getRect(find.byKey(const Key('settings-scroll'))).bottom, 956);
        expect(find.byKey(const Key('soft-bottom-edge')), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

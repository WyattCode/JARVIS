import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/startup_scene.dart';
import 'package:jarvis_android/ui/login_art.dart';

import 'support.dart';

void main() {
  test(
    'Dark defaults migrate once, and explicit theme choices persist',
    () async {
      final vault = MemoryVault()
        ..value = jsonEncode({
          'version': 1,
          'theme': 'system',
          'conversations': [],
          'settings': {},
        });
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      expect(c.theme, 'dark');
      for (final theme in ['system', 'light', 'dark']) {
        c.setTheme(theme);
        await c.save();
        final restored = JarvisController(FakeApi(), vault);
        await restored.initialize();
        expect(restored.theme, theme);
        restored.dispose();
      }
      c.dispose();
    },
  );
  testWidgets(
    'Startup waits for readiness and reveals content without a timer delay',
    (t) async {
      Future<void> show(bool ready, {bool reduced = false}) {
        return t.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: StartupGate(
                ready: ready,
                child: const Scaffold(body: Text('READY')),
              ),
            ),
          ),
        );
      }

      await show(false);
      expect(find.byType(LoginScene), findsOneWidget);
      expect(find.text('READY'), findsNothing);
      await show(true);
      expect(find.text('READY'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull);
      await show(false, reduced: true);
      await show(true, reduced: true);
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(find.text('READY'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
}

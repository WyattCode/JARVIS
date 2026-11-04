import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/startup_scene.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  testWidgets(
    'Launch reactor survives flight and lands exactly, with no duplicate',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      Future<void> show(bool ready) => t.pumpWidget(
        MaterialApp(
          home: StartupGate(
            ready: ready,
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.only(left: 24, top: 80),
                child: SizedBox(
                  width: 300,
                  height: 250,
                  child: StartupReactorLanding(),
                ),
              ),
            ),
          ),
        ),
      );
      await show(false);
      final state = t.state(find.byType(LoginScene));
      final start = t.getRect(find.byType(LoginScene));
      await show(true);
      await t.pump();
      await t.pump(const Duration(milliseconds: 450));
      expect(find.byType(LoginScene), findsOneWidget);
      expect(identical(state, t.state(find.byType(LoginScene))), isTrue);
      final midpoint = t.getRect(find.byType(LoginScene));
      expect(midpoint.top, lessThan(start.top));
      expect(midpoint.top, greaterThan(80));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump();
      expect(find.byType(LoginScene), findsOneWidget);
      expect(identical(state, t.state(find.byType(LoginScene))), isTrue);
      expect(
        t.getRect(find.byType(LoginScene)),
        const Rect.fromLTWH(24, 80, 300, 250),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}

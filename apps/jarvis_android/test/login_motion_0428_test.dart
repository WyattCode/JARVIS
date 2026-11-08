import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Cover IME keeps reactor alive and form motion continuous in both directions',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(425, 623);
      t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
      t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
      await t.pump();
      final scene = t.state(find.byType(LoginScene));
      final fields = find.byType(TextField);
      final original = t.getSize(fields.first);
      final button = find.widgetWithText(FilledButton, '登录');
      for (final opening in [true, false]) {
        t.view.viewInsets = FakeViewPadding(bottom: opening ? 284 : 0);
        t.view.padding = FakeViewPadding(top: 46, bottom: opening ? 0 : 20);
        await t.pump();
        var previous = t.getRect(button).bottom;
        for (var frame = 0; frame < 40; frame++) {
          await t.pump(const Duration(milliseconds: 8));
          expect(
            identical(scene, t.state(find.byType(LoginScene))),
            isTrue,
            reason: 'Reactor must not restart at a visibility threshold',
          );
          expect(t.getSize(fields.first), original);
          final bottom = t.getRect(button).bottom;
          expect(
            (bottom - previous).abs(),
            lessThan(32),
            reason: 'No one-frame jump',
          );
          previous = bottom;
          expect(t.takeException(), isNull);
        }
        final before = t.getRect(button).bottom;
        await t.pump(const Duration(milliseconds: 300));
        expect(
          t.getRect(button).bottom,
          closeTo(before, .1),
          reason: 'No second move after keyboard settles',
        );
      }
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

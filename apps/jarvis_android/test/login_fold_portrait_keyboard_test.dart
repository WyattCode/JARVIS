import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Unfolded portrait login stays above IME without shrinking fields',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetPadding);
      for (final size in [const Size(608, 860), const Size(720, 1000)]) {
        t.view.physicalSize = size;
        t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
        t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
        t.view.viewInsets = FakeViewPadding.zero;
        final c = JarvisController(FakeApi(), MemoryVault());
        await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
        await t.pump(const Duration(milliseconds: 500));
        final fields = find.byType(TextField);
        final closedSize = t.getSize(fields.first);
        await t.enterText(fields.first, 'portrait-user');
        for (final inset in [284.0, 360.0]) {
          t.view.viewInsets = FakeViewPadding(bottom: inset);
          t.view.padding = const FakeViewPadding(top: 46);
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
          final button = find.widgetWithText(FilledButton, '登录');
          final gap = size.height - inset - t.getRect(button).bottom;
          expect(
            gap,
            inInclusiveRange(12, 28),
            reason: '$size keyboard=$inset gap=$gap',
          );
          expect(t.getSize(fields.first), closedSize);
          expect(
            t.widget<TextField>(fields.first).controller!.text,
            'portrait-user',
          );
          expect(t.takeException(), isNull);
        }
        t.view.viewInsets = FakeViewPadding.zero;
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
}

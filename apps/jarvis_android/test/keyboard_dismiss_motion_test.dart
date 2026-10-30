import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Fold composer follows IME once and does not move again when navigation padding is restored late',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetViewInsets);
      for (final size in [const Size(425, 623), const Size(860, 608)]) {
        t.view.physicalSize = size;
        t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        t.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        t.view.viewInsets = FakeViewPadding.zero;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        final composer = find.byKey(const Key('composer-frame'));
        final closed = t.getBottomLeft(composer).dy;
        t.view.padding = const FakeViewPadding(top: 24);
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        await t.pump();
        await t.pump();
        var previous = t.getBottomLeft(composer).dy;
        for (final inset in [
          250.0,
          200.0,
          150.0,
          100.0,
          60.0,
          30.0,
          10.0,
          0.0,
        ]) {
          t.view.viewInsets = FakeViewPadding(bottom: inset);
          await t.pump(const Duration(milliseconds: 16));
          final bottom = t.getBottomLeft(composer).dy;
          expect(
            bottom,
            greaterThanOrEqualTo(previous - .1),
            reason: '$size IME $inset must not reverse direction',
          );
          previous = bottom;
        }
        final atImeEnd = t.getBottomLeft(composer).dy;
        t.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        await t.pump(const Duration(milliseconds: 16));
        expect(
          t.getBottomLeft(composer).dy,
          closeTo(atImeEnd, .1),
          reason:
              '$size navigation padding must not trigger a second displacement',
        );
        expect(t.getBottomLeft(composer).dy, closeTo(closed, .1));
        await t.pump(const Duration(milliseconds: 300));
        expect(t.getBottomLeft(composer).dy, closeTo(closed, .1));
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
}

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
  testWidgets(
    'Tall phone keeps aligned sides, a raised resting composer and a real scroll viewport above keyboard',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      t.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
      t.view.padding = const FakeViewPadding(top: 32, bottom: 24);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final frame = find.byKey(const Key('composer-frame'));
      var rect = t.getRect(frame);
      expect(rect.left, closeTo(400 - rect.right, .1));
      expect(869 - rect.bottom, closeTo(rect.left + 7, .1));
      expect(869 - rect.bottom, closeTo(24 * .8 + 7, .1));
      final firstCard = t.getRect(find.byKey(const ValueKey('starter-0')));
      final secondCard = t.getRect(find.byKey(const ValueKey('starter-1')));
      expect(firstCard.left, closeTo(rect.left, .1));
      expect(secondCard.right, closeTo(rect.right, .1));
      final scroll = Scrollable.of(
        t.element(find.byKey(const ValueKey('starter-0'))),
      ).position;
      final before = scroll.viewportDimension;
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      t.view.padding = const FakeViewPadding(top: 32);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      rect = t.getRect(frame);
      final afterCard = t.getRect(find.byKey(const ValueKey('starter-0')));
      expect(
        afterCard.width,
        closeTo(firstCard.width, .1),
        reason: 'keyboard must not reshape suggestion cards',
      );
      expect(afterCard.height, closeTo(firstCard.height, .1));
      expect(afterCard.left, closeTo(rect.left, .1));
      expect(569 - rect.bottom, closeTo(rect.left, .1));
      expect(scroll.viewportDimension, lessThan(before));
      expect(scroll.maxScrollExtent, greaterThan(100));
      await t.drag(
        find.descendant(
          of: find.byType(ChatPanel),
          matching: find.byType(SingleChildScrollView),
        ),
        const Offset(0, -200),
      );
      await t.pump();
      expect(scroll.pixels, greaterThan(0));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

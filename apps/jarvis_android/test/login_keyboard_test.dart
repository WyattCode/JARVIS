import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Slab phone login retains input, grows keyboard hero and keeps button near IME',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(436, 948);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
      expect(find.byType(LoginBrandMark), findsOneWidget);
      final hero = find.byKey(const ValueKey('login-reactor-size'));
      final original = t.getSize(hero).height;
      final subtitle = find.byKey(const ValueKey('login-subtitle'));
      final subtitleHeight = t.getSize(subtitle).height;
      expect(
        t.getTopLeft(find.byKey(const ValueKey('login-brand-row'))).dy,
        lessThanOrEqualTo(16),
      );
      await t.enterText(find.byType(TextField).first, 'Wyatt');
      t.view.viewInsets = const FakeViewPadding(bottom: 400);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      final midway = t.getSize(hero).height;
      expect(t.getSize(subtitle).height, closeTo(subtitleHeight, .1));
      expect(t.getRect(subtitle).bottom, lessThan(548));
      expect(t.getRect(subtitle).top, greaterThanOrEqualTo(0));
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      final finalHeight = t.getSize(hero).height;
      expect(t.getSize(subtitle).height, closeTo(subtitleHeight, .1));
      expect(midway, lessThan(original));
      expect(midway, greaterThan(finalHeight));
      expect(finalHeight, greaterThan(150));
      final button = find.widgetWithText(FilledButton, '登录');
      final gap = 548 - t.getBottomRight(button).dy;
      expect(gap, inInclusiveRange(8, 20));
      expect(
        t.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Wyatt',
      );
      expect(t.takeException(), isNull);
      t.view.viewInsets = FakeViewPadding.zero;
      await t.pump();
      var previousY = t.getTopLeft(button).dy;
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
        final y = t.getTopLeft(button).dy;
        expect(
          y,
          greaterThanOrEqualTo(previousY - .5),
          reason: 'IME close must follow one direction',
        );
        previousY = y;
      }
      final finishedY = t.getTopLeft(button).dy;
      await t.pump(const Duration(milliseconds: 300));
      expect(
        t.getTopLeft(button).dy,
        closeTo(finishedY, .1),
        reason: 'No second movement after viewport settles',
      );
      expect(t.getSize(hero).height, closeTo(original, .1));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

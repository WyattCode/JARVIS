import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  Widget scene(ReactorMode mode) => MaterialApp(
    home: Center(
      child: SizedBox(width: 240, height: 190, child: LoginScene(mode: mode)),
    ),
  );
  ReactorPainter painter(WidgetTester t) => t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<ReactorPainter>()
      .single;

  testWidgets(
    'a mode change mid-blend starts from the energy shown right now',
    (t) async {
      await t.pumpWidget(scene(ReactorMode.idle));
      await t.pumpWidget(scene(ReactorMode.speaking));
      await t.pump();
      await t.pump(const Duration(milliseconds: 225));
      final midway = painter(t).currentEnergy;
      expect(
        midway,
        greaterThan(ReactorPainter.energyOf(ReactorMode.idle) + .1),
      );
      expect(midway, lessThan(1));

      // Back to listening before the blend finished: no jump to the speaking level.
      await t.pumpWidget(scene(ReactorMode.listening));
      expect(painter(t).transition.value, 0);
      expect(painter(t).currentEnergy, closeTo(midway, .02));

      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(
        painter(t).currentEnergy,
        closeTo(ReactorPainter.energyOf(ReactorMode.listening), .001),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a settled scene blends from its own level, rapid changes stay continuous',
    (t) async {
      await t.pumpWidget(scene(ReactorMode.thinking));
      expect(
        painter(t).currentEnergy,
        ReactorPainter.energyOf(ReactorMode.thinking),
      );
      var last = painter(t).currentEnergy;
      final modes = [
        ReactorMode.speaking,
        ReactorMode.idle,
        ReactorMode.listening,
        ReactorMode.speaking,
      ];
      for (final mode in modes) {
        await t.pumpWidget(scene(mode));
        expect(painter(t).currentEnergy, closeTo(last, .02));
        await t.pump();
        await t.pump(const Duration(milliseconds: 120));
        last = painter(t).currentEnergy;
      }
      await t.pump(const Duration(seconds: 1));
      expect(painter(t).currentEnergy, 1);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reduced motion jumps straight to the new level', (t) async {
    Widget reduced(ReactorMode mode) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: scene(mode),
    );
    await t.pumpWidget(reduced(ReactorMode.idle));
    await t.pumpWidget(reduced(ReactorMode.speaking));
    await t.pump();
    expect(painter(t).currentEnergy, 1);
    await t.pumpWidget(const SizedBox());
  });
}

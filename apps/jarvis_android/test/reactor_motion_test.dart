import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/login_art.dart';

void main() {
  test('All reactor states loop without a visible phase reset', () async {
    for (final mode in ReactorMode.values) {
      Future<ui.Image> frame(double phase) async {
        final recorder = ui.PictureRecorder();
        ReactorPainter(
          motion: AlwaysStoppedAnimation(phase),
          transition: const AlwaysStoppedAnimation(1),
          mode: mode,
          dark: true,
        ).paint(Canvas(recorder), const Size(240, 190));
        final picture = recorder.endRecording();
        final image = await picture.toImage(240, 190);
        picture.dispose();
        return image;
      }

      final first = await frame(0), last = await frame(1);
      final a = (await first.toByteData())!.buffer.asUint8List();
      final b = (await last.toByteData())!.buffer.asUint8List();
      var sum = 0;
      for (var i = 0; i < a.length; i++) {
        sum += (a[i] - b[i]).abs();
      }
      expect(sum / a.length, lessThan(.15), reason: mode.name);
      first.dispose();
      last.dispose();
    }
  });
  testWidgets('Reduced motion freezes reactor across state changes', (t) async {
    Future<void> show(ReactorMode mode, bool reduced) => t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: SizedBox(
            width: 240,
            height: 190,
            child: LoginScene(mode: mode),
          ),
        ),
      ),
    );
    ReactorPainter painter() => t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<ReactorPainter>()
        .single;
    await show(ReactorMode.idle, false);
    await t.pump(const Duration(milliseconds: 300));
    final before = painter().motion.value;
    await show(ReactorMode.speaking, true);
    await t.pump(const Duration(seconds: 1));
    expect(painter().motion.value, before);
    expect(painter().transition.value, 1);
    await show(ReactorMode.listening, false);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 500));
    expect(painter().motion.value, isNot(before));
    expect(painter().mode, ReactorMode.listening);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
  });
}

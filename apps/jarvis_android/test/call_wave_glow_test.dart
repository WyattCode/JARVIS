import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/call_wave_glow.dart';

/// The light of the call is a wave along an edge, not a box.
void main() {
  const size = Size(400, 800);
  const cyan = Color(0xff8fdceb);
  final boundary = GlobalKey();

  Future<void> show(
    WidgetTester t, {
    required bool fromTop,
    required double intensity,
    required double level,
    bool animations = false,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: !animations),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: Colors.black,
              child: SizedBox.expand(
                child: CallWaveGlow(
                  fromTop: fromTop,
                  color: cyan,
                  intensity: intensity,
                  level: level,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  /// The red channel at (x, y): the page is black, so any light is above 0.
  Future<int> light(WidgetTester t, int x, int y) async {
    late ByteData data;
    await t.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    return data.getUint8((y * size.width.toInt() + x) * 4);
  }

  testWidgets('with sound the light stands up from the bottom edge', (t) async {
    await show(t, fromTop: false, intensity: .5, level: 1);
    expect(await light(t, 200, 795), greaterThan(8));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('it is not boxed: nothing is lit far from its own edge', (
    t,
  ) async {
    await show(t, fromTop: false, intensity: .62, level: 1);
    // The far (top) half of the screen is dark everywhere.
    for (final x in [0, 100, 200, 300, 399]) {
      expect(await light(t, x, 10), 0, reason: 'x=$x');
      expect(await light(t, x, 300), 0, reason: 'x=$x');
    }
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('it runs to both sides of the screen, with no end in view', (
    t,
  ) async {
    await show(t, fromTop: false, intensity: .5, level: 1);
    final left = await light(t, 0, 790);
    final middle = await light(t, 200, 790);
    final right = await light(t, 399, 790);
    expect(left, greaterThan(8));
    expect(right, greaterThan(8));
    // Not a cloud that thins out to the sides: the sides are as bright as
    // the middle to within a swell's difference.
    expect(left, greaterThan(middle * .35));
    expect(right, greaterThan(middle * .35));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('JARVIS\'s light hangs from the top edge', (t) async {
    await show(t, fromTop: true, intensity: .5, level: 1);
    expect(await light(t, 200, 4), greaterThan(8));
    expect(await light(t, 200, 795), 0);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('louder sound reaches farther than a faint one', (t) async {
    await show(t, fromTop: false, intensity: .5, level: .1);
    final quiet = await light(t, 200, 800 - 200);
    await show(t, fromTop: false, intensity: .5, level: 1);
    final loud = await light(t, 200, 800 - 200);
    expect(loud, greaterThan(quiet));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no brightness, no light', (t) async {
    await show(t, fromTop: false, intensity: 0, level: 1);
    expect(await light(t, 200, 795), 0);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('it moves only while there is sound, then lets the screen rest', (
    t,
  ) async {
    await show(t, fromTop: false, intensity: .5, level: 1, animations: true);
    await t.pump(const Duration(milliseconds: 100));
    // With sound it keeps asking for frames.
    expect(t.binding.hasScheduledFrame, isTrue);
    await show(t, fromTop: false, intensity: .1, level: 0, animations: true);
    // The sound dies away; after a while nothing is drawn any more.
    for (var i = 0; i < 300; i++) {
      await t.pump(const Duration(milliseconds: 33));
    }
    expect(t.binding.hasScheduledFrame, isFalse);
    await t.pumpWidget(const SizedBox());
  });
}

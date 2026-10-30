import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/startup_scene.dart';

import 'support.dart';

void main() {
  // iOS accessibility sizes reach ~3.1x, which overlapped the fixed-height
  // header and clipped the composer toolbar; Android's system maximum is ~2.0x.
  Future<double> scaledTen(WidgetTester t, double systemScale) async {
    t.platformDispatcher.textScaleFactorTestValue = systemScale;
    addTearDown(t.platformDispatcher.clearAllTestValues);
    // JarvisApp owns and disposes its controller.
    final c = JarvisController(FakeApi(), MemoryVault());
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(milliseconds: 100));
    return MediaQuery.textScalerOf(t.element(find.byType(StartupGate)))
        .scale(10);
  }

  testWidgets('Text scale up to the Android maximum is left untouched', (
    t,
  ) async {
    expect(await scaledTen(t, 1.0), closeTo(10, 0.01));
    expect(await scaledTen(t, 1.5), closeTo(15, 0.01));
    expect(await scaledTen(t, 2.0), closeTo(20, 0.01));
  });

  testWidgets(
    'iOS: extreme accessibility text scale is capped for the layouts',
    (t) async {
      expect(await scaledTen(t, 3.1), closeTo(24, 0.01));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('Android: the system text scale is never clamped (unchanged)', (
    t,
  ) async {
    expect(await scaledTen(t, 3.1), closeTo(31, 0.01));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'b2_support.dart';
import 'support.dart';

/// Like [pumpDevice], with the optional hooks of [JarvisHome] that the app wires up.
Future<JarvisController> pumpWired(
  WidgetTester t,
  Device device, {
  double keyboard = 0,
  double scale = 1,
  bool dark = false,
  TargetPlatform platform = TargetPlatform.iOS,
  void Function(JarvisController)? seed,
  FakeApi? api,
  void Function(MediaTask task)? onCancelTask,
  Future<void> Function()? openSettings,
  VoidCallback? onContinue,
  bool Function()? offline,
  VoidCallback? onRetry,
  bool highContrast = false,
  bool accessibleNavigation = false,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = device.size;
  final safe = device.safe;
  t.view.padding = FakeViewPadding(
    left: safe.left,
    top: safe.top,
    right: safe.right,
    bottom: keyboard > 0 ? 0 : safe.bottom,
  );
  t.view.viewPadding = FakeViewPadding(
    left: safe.left,
    top: safe.top,
    right: safe.right,
    bottom: safe.bottom,
  );
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  t.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(
        highContrast: highContrast,
        accessibleNavigation: accessibleNavigation,
      );
  addTearDown(() {
    t.view.resetDevicePixelRatio();
    t.view.resetPhysicalSize();
    t.view.resetPadding();
    t.view.resetViewPadding();
    t.view.resetViewInsets();
    t.platformDispatcher.clearTextScaleFactorTestValue();
    t.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });
  final c = JarvisController(api ?? FakeApi(), MemoryVault());
  await c.initialize();
  addTearDown(c.dispose);
  seed?.call(c);
  await t.pumpWidget(
    DuoLayoutScope(
      layout: ValueNotifier(device.layout),
      child: MaterialApp(
        theme: ThemeData(
          platform: platform,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        home: JarvisHome(
          controller: c,
          onCancelTask: onCancelTask,
          openSettings: openSettings,
          onContinue: onContinue,
          offline: offline,
          onRetry: onRetry,
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 400));
  return c;
}

/// A connected controller: sending is possible.
void connected(JarvisController c) => c
  ..authenticated = true
  ..model = 'test-model';

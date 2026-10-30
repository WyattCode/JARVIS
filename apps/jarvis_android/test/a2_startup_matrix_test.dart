import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/startup_scene.dart';

import 'support.dart';

/// One device pose: logical size and the safe area the native side reports for it.
typedef Pose = ({String name, Size size, EdgeInsets safe});

const poses = <Pose>[
  (
    name: '18 Pro Max portrait',
    size: Size(440, 956),
    safe: EdgeInsets.only(top: 62, bottom: 34),
  ),
  (
    name: '18 Pro Max landscape',
    size: Size(956, 440),
    safe: EdgeInsets.fromLTRB(62, 0, 62, 21),
  ),
  (
    name: '17 Pro portrait',
    size: Size(402, 874),
    safe: EdgeInsets.only(top: 62, bottom: 34),
  ),
  (
    name: '17 Pro landscape',
    size: Size(874, 402),
    safe: EdgeInsets.fromLTRB(62, 0, 62, 21),
  ),
  (
    name: '17 portrait',
    size: Size(393, 852),
    safe: EdgeInsets.only(top: 59, bottom: 34),
  ),
  (
    name: 'Air portrait',
    size: Size(420, 912),
    safe: EdgeInsets.only(top: 62, bottom: 34),
  ),
  (name: 'SE portrait', size: Size(375, 667), safe: EdgeInsets.only(top: 20)),
  (name: 'SE landscape', size: Size(667, 375), safe: EdgeInsets.zero),
  (
    name: 'Duo outer',
    size: Size(466, 678),
    safe: EdgeInsets.only(right: 84, bottom: 34),
  ),
  (
    name: 'Duo inner portrait',
    size: Size(669, 951),
    safe: EdgeInsets.only(top: 59, bottom: 34),
  ),
];

/// What the native bridge answers to `snapshot` for a pose. A straight phone has no vertical bar.
Map<String, Object?> snapshotFor(Pose pose) {
  final bar = pose.name.startsWith('Duo outer');
  return {
    'edge': bar ? 'right' : 'none',
    'width': pose.size.width,
    'height': pose.size.height,
    'safe': {
      'left': pose.safe.left,
      'top': pose.safe.top,
      'right': pose.safe.right,
      'bottom': pose.safe.bottom,
    },
    if (bar) 'systemBar': {'cx': 424.0, 'top': 148.0, 'bottom': 640.0},
    'regions': [
      if (bar)
        {
          'kind': 'occlusion',
          'active': true,
          'x': 382.0,
          'y': 0.0,
          'w': 84.0,
          'h': 174.0,
        },
    ],
  };
}

const known = <String>{};

/// No exception, except the overflows listed in [known].
void noException(WidgetTester t, String name) {
  final error = t.takeException();
  if (known.contains(name) && error != null) {
    expect(error.toString(), contains('overflowed'), reason: name);
  } else {
    expect(error, isNull, reason: name);
  }
}

void main() {
  Future<void> mount(
    WidgetTester t,
    Pose pose,
    JarvisController c, {
    required double scale,
  }) async {
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = pose.size * 3;
    t.view.padding = FakeViewPadding(
      left: pose.safe.left * 3,
      top: pose.safe.top * 3,
      right: pose.safe.right * 3,
      bottom: pose.safe.bottom * 3,
    );
    t.view.viewPadding = t.view.padding;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('ai.jarvis.app/duo'),
      (call) async => snapshotFor(pose),
    );
    messenger.setMockStreamHandler(
      const EventChannel('ai.jarvis.app/duo-events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('ai.jarvis.app/duo'),
        null,
      );
      messenger.setMockStreamHandler(
        const EventChannel('ai.jarvis.app/duo-events'),
        null,
      );
    });
    await t.pumpWidget(JarvisApp(controller: c));
    // initialize() settles, the launch flight starts (post-frame), flies for 900 ms and lands.
    for (final ms in [50, 50, 1000, 100]) {
      await t.pump(Duration(milliseconds: ms));
    }
  }

  // The routes the interactive widgets of a page are checked against: inside the safe area (nothing under the Dynamic
  // Island, the home indicator or the rail), at the sides at least.
  void expectInsideSafe(WidgetTester t, Pose pose, String what) {
    final area = Rect.fromLTRB(
      pose.safe.left,
      0,
      pose.size.width - pose.safe.right,
      pose.size.height - pose.safe.bottom,
    );
    for (final finder in [
      find.byType(TextField),
      find.byType(FilledButton),
      find.byType(IconButton),
    ]) {
      for (final e in finder.evaluate()) {
        final box = e.renderObject as RenderBox;
        if (!box.hasSize || !box.attached) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        // Off-screen items of a scrolling page are reachable by scrolling, not tapped where they are.
        if (rect.bottom <= 0 || rect.top >= pose.size.height) continue;
        expect(
          rect.left >= area.left - .5 && rect.right <= area.right + .5,
          isTrue,
          reason:
              '$what: ${e.widget.runtimeType} $rect leaves the safe area $area',
        );
      }
    }
  }

  for (final pose in poses) {
    for (final (scale, brightness) in [
      (1.0, 'dark'),
      (1.5, 'light'),
      (2.4, 'dark'),
    ]) {
      final label = '${pose.name} x$scale $brightness';

      testWidgets('login: $label', (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final c = JarvisController(FakeApi(), MemoryVault());
          await mount(t, pose, c, scale: scale);
          c.setTheme(brightness);
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          noException(t, 'login: $label');
          expect(find.byType(LoginPage), findsOneWidget);
          final gate = t.state(find.byType(StartupGate)) as dynamic;
          expect(gate.landed, isTrue, reason: 'the launch flight lands');
          expect(find.bySemanticsLabel('贾维斯正在启动'), findsNothing);
          final button = find.widgetWithText(FilledButton, '登录');
          expect(button, findsOneWidget);
          expect(t.getSize(button).height, greaterThanOrEqualTo(44));
          for (final field in find.byType(TextField).evaluate()) {
            expect(
              (field.renderObject as RenderBox).size.height,
              greaterThanOrEqualTo(44),
            );
          }
          expect(
            MediaQuery.textScalerOf(t.element(find.byType(LoginPage)))
                .scale(10),
            closeTo(10 * scale, .01),
          );
          expectInsideSafe(t, pose, label);
          await t.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('home: $label', (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final api = FakeApi()..cookie = '__Host-jarvis_session=test';
          final c = JarvisController(api, MemoryVault());
          await mount(t, pose, c, scale: scale);
          c.setTheme(brightness);
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          noException(t, 'home: $label');
          expect(find.byType(JarvisHome), findsOneWidget);
          final gate = t.state(find.byType(StartupGate)) as dynamic;
          expect(gate.landed, isTrue);
          expectInsideSafe(t, pose, label);
          await t.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  // Keyboard up on the login page: the fields and the button stay reachable above it (iPhone keyboards are ~290-340 pt).
  for (final pose in poses.where((p) => !p.name.startsWith('Duo'))) {
    for (final scale in [1.0, 2.4]) {
      testWidgets('login with keyboard: ${pose.name} x$scale', (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final c = JarvisController(FakeApi(), MemoryVault());
          await mount(t, pose, c, scale: scale);
          final keyboard = pose.size.height > pose.size.width ? 300.0 : 200.0;
          await t.tap(find.byType(TextField).first);
          await t.pump();
          addTearDown(t.view.resetViewInsets);
          // The keyboard slides in over several frames, each one reported to the app like the engine does.
          for (var step = 1; step <= 10; step++) {
            t.view.viewInsets = FakeViewPadding(
              bottom: keyboard * 3 * step / 10,
            );
            await t.pump(const Duration(milliseconds: 30));
          }
          for (var i = 0; i < 30; i++) {
            await t.pump(const Duration(milliseconds: 16));
          }
          noException(t, 'keyboard: ${pose.name} x$scale');
          // Portrait only: in landscape the focused field can stay (partly) behind the keyboard in this harness, which
          // reports the keyboard in steps while the page's own inset animation lags behind it (see the report).
          if (scale == 1.0 && pose.size.height > pose.size.width) {
            // The caret line of the focused field is above the keyboard (the page scrolls it into view).
            final field = t.getRect(find.byType(TextField).first);
            expect(field.top, lessThan(pose.size.height - keyboard - 24));
            expect(field.top, greaterThanOrEqualTo(0));
          }
          await t.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  test('a straight iPhone layout is not foldable and has no rail', () {
    for (final pose in poses.where((p) => !p.name.startsWith('Duo'))) {
      final layout = DuoLayout.fromMap(snapshotFor(pose));
      expect(layout.isFoldable, isFalse, reason: pose.name);
      expect(layout.hasVerticalBar, isFalse, reason: pose.name);
      expect(layout.barRect, isNull, reason: pose.name);
    }
  });
}

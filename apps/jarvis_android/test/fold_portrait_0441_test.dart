import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/model/adaptive_layout.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Expanded portrait suggestions and composer share a shared iOS portrait proportions',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      for (final size in [const Size(608, 860), const Size(720, 1000)]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        final frame = t.getRect(find.byKey(const Key('composer-frame'))),
            left = t.getRect(find.byKey(const ValueKey('starter-0'))),
            right = t.getRect(find.byKey(const ValueKey('starter-1')));
        expect(frame.width, closeTo((size.width - 32) * .76, .1));
        expect(left.height, greaterThanOrEqualTo(78));
        expect(right.height, closeTo(left.height, .1));
        expect(frame.center.dx, closeTo(size.width / 2, .1));
        expect(left.left, closeTo(frame.left, .1));
        expect(right.right, closeTo(frame.right, .1));
        await t.enterText(find.byType(TextField).last, '保留草稿');
        t.view.viewInsets = const FakeViewPadding(bottom: 260);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        // With the keyboard up the box is wider: 17 from each side, not 32, and
        // without the narrowing of the upright inner display (as on iOS).
        expect(
          t.getRect(find.byKey(const Key('composer-frame'))).width,
          closeTo(size.width - 17, .1),
        );
        expect(c.current.draft, '保留草稿');
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
        t.view.viewInsets = FakeViewPadding.zero;
      }
    },
  );
  testWidgets('Cover, slab and expanded landscape retain their frame widths', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    for (final size in [
      const Size(425, 623),
      const Size(436, 948),
      const Size(860, 608),
    ]) {
      t.view.physicalSize = size;
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final width = t.getRect(find.byKey(const Key('composer-frame'))).width;
      final expected = size.width == 425
          ? size.width - 32
          : size.width == 436
          ? size.width - 20
          : (size.width -
                    AdaptiveLayout.forWindow(
                      size.width,
                      size.height,
                    ).sidebarWidth -
                    32) *
                .9215;
      expect(width, closeTo(expected, .1));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
  testWidgets(
    'Portrait large text remains scrollable with separated avatar and suggestions',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(608, 860);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: JarvisHome(controller: c),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      final last = find.byKey(const ValueKey('starter-3'));
      await t.ensureVisible(last);
      await t.pump();
      expect(last.hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

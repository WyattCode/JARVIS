import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Inner landscape uses shared columns with sidebar open and closed',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [const Size(860, 608), const Size(1080, 760)]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        final before = t.getRect(find.byKey(const Key('composer-frame')));
        final chatBefore = t.getRect(find.byType(ChatPanel));
        await t.tap(find.byTooltip('收起会话'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        final after = t.getRect(find.byKey(const Key('composer-frame')));
        final chatAfter = t.getRect(find.byType(ChatPanel));
        expect(before.width, closeTo((chatBefore.width - 32) * .9215, .1));
        expect(after.width, closeTo((chatAfter.width - 32) * .6984, .1));
        expect(after.center.dx, closeTo(size.width / 2, .1));
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
  testWidgets(
    'Expired login stays visible without adding scroll height on the cover',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [const Size(425, 623), const Size(360, 560)]) {
        t.view.physicalSize = size;
        final c = JarvisController(FakeApi(), MemoryVault());
        await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
        await t.pump();
        final scroll = Scrollable.of(t.element(find.byType(TextField).first))
            .position;
        final extent = scroll.maxScrollExtent;
        c.error = '登录已过期，请重新登录';
        await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
        await t.pump();
        final error = t.getRect(find.text('登录已过期，请重新登录'));
        expect(error.top, greaterThanOrEqualTo(0));
        expect(error.bottom, lessThan(size.height));
        expect(scroll.maxScrollExtent, closeTo(extent, .1));
        expect(find.text('登录已过期，请重新登录'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
  testWidgets(
    'Fold open sidebar shares a header axis, matching card edges and current conversation title',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final brand = t.getRect(find.byKey(const ValueKey('sidebar-brand-row')));
      final header = t.getRect(find.byKey(const ValueKey('chat-header-row')));
      expect(brand.center.dy, closeTo(header.center.dy, .1));
      final frame = t.getRect(find.byKey(const Key('composer-frame')));
      final left = t.getRect(find.byKey(const ValueKey('starter-0')));
      final right = t.getRect(find.byKey(const ValueKey('starter-1')));
      expect(left.left, closeTo(frame.left, .1));
      expect(right.right, closeTo(frame.right, .1));
      final heading = find.byKey(const ValueKey('chat-heading-line'));
      expect(
        find.descendant(of: heading, matching: find.text(c.current.title)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: heading, matching: find.text('JARVIS')),
        findsNothing,
      );
      c.rename(c.current.id, '项目规划');
      await t.pump();
      expect(
        find.descendant(of: heading, matching: find.text('项目规划')),
        findsOneWidget,
      );
      final scroll = Scrollable.of(
        t.element(find.byKey(const ValueKey('starter-0'))),
      ).position;
      expect(scroll.physics.shouldAcceptUserOffset(scroll), isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Outer welcome scroll viewport follows keyboard so clipped cards remain reachable',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(425, 623);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final scroll = Scrollable.of(
        t.element(find.byKey(const ValueKey('starter-0'))),
      ).position;
      final before = scroll.viewportDimension;
      t.view.viewInsets = const FakeViewPadding(bottom: 284);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
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

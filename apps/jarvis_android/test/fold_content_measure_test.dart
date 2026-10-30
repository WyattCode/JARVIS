import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Inner landscape keeps the composer and starters width when sidebar closes',
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
        final before = t.getRect(find.byType(Composer));
        final chatBefore = t.getRect(find.byType(ChatPanel));
        await t.tap(find.byTooltip('收起会话'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        final after = t.getRect(find.byType(Composer));
        final chatAfter = t.getRect(find.byType(ChatPanel));
        expect(after.width, closeTo(before.width, .1));
        expect(chatAfter.width, closeTo(chatBefore.width, .1));
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
}

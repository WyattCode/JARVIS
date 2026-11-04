import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Fold welcome keeps identity and both lines in all postures; cover landscape yields cards',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetPadding);
      for (final size in [
        const Size(425, 623),
        const Size(623, 425),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
        t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
        t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        final identity = find.byKey(const Key('welcome-identity'));
        final greeting = find.byKey(const Key('welcome-greeting'));
        final hint = find.byKey(const Key('welcome-hint'));
        expect(identity.hitTestable(), findsOneWidget, reason: '$size');
        expect(greeting.hitTestable(), findsOneWidget, reason: '$size');
        expect(hint.hitTestable(), findsOneWidget, reason: '$size');
        final pane = t.getRect(find.byType(ChatPanel));
        for (final f in [identity, greeting, hint]) {
          final r = t.getRect(f);
          expect(r.top, greaterThanOrEqualTo(pane.top));
          expect(r.bottom, lessThanOrEqualTo(pane.bottom + .1));
        }
        if (size == const Size(623, 425)) {
          expect(t.getRect(identity).right, lessThan(t.getRect(hint).left));
        } else {
          expect(t.getRect(identity).bottom, lessThan(t.getRect(greeting).top));
          expect(
            t.getRect(identity).center.dx,
            closeTo(t.getRect(greeting).center.dx, .1),
          );
        }
        expect(
          find.byKey(const ValueKey('starter-0')),
          size == const Size(623, 425) ? findsNothing : findsOneWidget,
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
}

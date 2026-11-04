import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/startup_scene.dart';

import 'support.dart';

void viewport(WidgetTester t, Size size) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  t.view.viewPadding = const FakeViewPadding(top: 46, bottom: 20);
  t.view.padding = const FakeViewPadding(top: 46, bottom: 20);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetViewPadding);
  addTearDown(t.view.resetPadding);
}

void main() {
  testWidgets(
    'One live welcome animation survives rotation, unfolding and dock reparenting',
    (t) async {
      viewport(t, const Size(425, 623));
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          home: StartupGate(ready: true, child: JarvisHome(controller: c)),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 1200));
      await t.pump();
      c.newConversation();
      c.current.draft = '保留草稿';
      await t.pump();
      Finder scene() => find.descendant(
        of: find.byKey(const Key('welcome-identity')),
        matching: find.byType(LoginScene),
      );
      final state = t.state(scene());
      for (final size in [
        const Size(623, 425),
        const Size(608, 860),
        const Size(860, 608),
        const Size(425, 623),
      ]) {
        t.view.physicalSize = size;
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(
          t.state(scene()),
          same(state),
          reason: '$size retains controller and random profile',
        );
        expect(c.current.draft, '保留草稿');
        expect(t.takeException(), isNull);
      }
      c.newConversation();
      await t.pump();
      expect(
        t.state(scene()),
        isNot(same(state)),
        reason: 'Only new conversation gets a fresh identity',
      );
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Sidebar animation and drag keep card typography and height constant',
    (t) async {
      viewport(t, const Size(760, 608));
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final card = find.byKey(const ValueKey('starter-0'));
      final height = t.getSize(card).height;
      final title = find.descendant(
        of: card,
        matching: find.text(c.starters.first.title),
      );
      final font = t.widget<Text>(title).style!.fontSize;
      for (final tooltip in ['收起会话', '展开会话']) {
        await t.tap(find.byTooltip(tooltip));
        await t.pump();
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 16));
          expect(t.getSize(card).height, closeTo(height, .01));
          expect(t.widget<Text>(title).style!.fontSize, font);
          expect(t.takeException(), isNull);
        }
      }
      final gesture = await t.startGesture(
        t.getCenter(find.byKey(const Key('pane-grip'))),
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-12, 0));
        await t.pump(const Duration(milliseconds: 16));
        expect(t.getSize(card).height, closeTo(height, .01));
        expect(t.widget<Text>(title).style!.fontSize, font);
      }
      await gesture.up();
      await t.pump(const Duration(milliseconds: 400));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'support.dart';
import 'voice_support.dart';

class StatusApi extends FakeApi {
  @override
  Future<Map<String, dynamic>> toolsStatus() async => {
    'data': [
      {'name': '模型状态 · 长名称不会侵入系统安全区', 'state': 'ready'},
    ],
  };
}

Widget motionHost(JarvisController c, {bool reduced = false}) => MaterialApp(
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh')],
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      systemGestureInsets: const EdgeInsets.symmetric(horizontal: 24),
    ),
    child: child!,
  ),
  home: JarvisHome(controller: c),
);

void main() {
  testWidgets(
    'Grip follows drag, snaps closed and reopens without losing draft',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.setDraft('拖动时保留');
      await t.pumpWidget(motionHost(c));
      await t.pump();
      final pane = find.byKey(const Key('docked-sidebar'));
      final grip = find.byKey(const Key('pane-grip'));
      final width = t.getSize(pane).width;
      final gesture = await t.startGesture(t.getCenter(grip));
      await gesture.moveBy(const Offset(-25, 0));
      await t.pump();
      await gesture.moveBy(const Offset(-80, 0));
      await t.pump();
      expect(t.getSize(pane).width, inExclusiveRange(0, width));
      await gesture.moveBy(const Offset(-200, 0));
      await gesture.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(t.getSize(pane).width, 0);
      expect(grip.hitTestable(), findsOneWidget);
      expect(t.getRect(grip).left, 0);
      expect(t.getRect(find.byKey(const Key('split-content'))).left, 0);
      await t.drag(grip, const Offset(300, 0));
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(t.getSize(pane).width, width);
      final canceled = await t.startGesture(t.getCenter(grip));
      await canceled.moveBy(const Offset(-100, 0));
      await t.pump();
      await canceled.cancel();
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(t.getSize(pane).width, width);
      await t.tap(grip);
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(t.getSize(pane).width, 0);
      expect(c.current.draft, '拖动时保留');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Portrait drawer opens by edge swipe and dismisses outside or back',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(608, 860);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.setDraft('竖屏保持');
      await t.pumpWidget(motionHost(c));
      await t.pump();
      await t.dragFrom(const Offset(1, 300), const Offset(300, 0));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('new-conversation')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is PopScope && !widget.canPop,
        ),
        findsOneWidget,
      );
      await t.tapAt(const Offset(550, 400));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('new-conversation')).hitTestable(),
        findsNothing,
      );
      await t.tap(find.byTooltip('展开会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.binding.handlePopRoute();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('new-conversation')).hitTestable(),
        findsNothing,
      );
      expect(c.current.draft, '竖屏保持');
      await t.tap(find.byTooltip('展开会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      t.view.physicalSize = const Size(860, 608);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is PopScope && !widget.canPop,
        ),
        findsNothing,
      );
      t.view.physicalSize = const Size(608, 860);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('new-conversation')).hitTestable(),
        findsNothing,
      );
      expect(find.byTooltip('展开会话').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Collapsed sidebar leaves no selected-tile ink on the chat canvas',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.messages.add(ChatMessage('assistant', '已有回复'));
      await t.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const Key('ink-canvas'),
            child: JarvisHome(controller: c),
          ),
        ),
      );
      await t.pump();
      final tile = find.byType(ListTile).first;
      final rect = t.getRect(tile);
      final point = Offset(rect.left + 6, rect.center.dy);
      final background = Theme.of(t.element(tile)).colorScheme.surface;
      await t.tap(find.byTooltip('收起会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      // The grip overlays the full-width content instead of reserving a rail.
      expect(t.getRect(find.byKey(const Key('pane-grip'))).left, 0);
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('ink-canvas')),
      );
      final pixel = await t.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final index = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        final color = Color.fromARGB(
          data.getUint8(index + 3),
          data.getUint8(index),
          data.getUint8(index + 1),
          data.getUint8(index + 2),
        );
        image.dispose();
        return color;
      });
      expect(pixel, background);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Status page respects display side insets in all four fold profiles',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      t.view.padding = const FakeViewPadding(left: 32, right: 32, bottom: 24);
      t.view.viewPadding = const FakeViewPadding(
        left: 32,
        right: 32,
        bottom: 24,
      );
      final c = JarvisController(StatusApi(), MemoryVault());
      await c.initialize();
      for (final size in [
        const Size(425, 623),
        const Size(623, 425),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        t.view.physicalSize = size;
        await t.pumpWidget(MaterialApp(home: StatusPage(controller: c)));
        await t.pump();
        final row = t.getRect(find.byType(ListTile));
        expect(row.left, greaterThanOrEqualTo(32));
        expect(row.right, lessThanOrEqualTo(size.width - 32));
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Docked sidebar animates without losing drafts or exposing hidden controls',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.messages.add(ChatMessage('assistant', '已有回复'));
      c.setDraft('保持草稿');
      await t.pumpWidget(motionHost(c));
      await t.pump();
      final panel = find.byKey(const Key('docked-sidebar'));
      final initialWidth = t.getSize(panel).width;
      await t.tap(find.byTooltip('收起会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 70));
      final midWidth = t.getSize(panel).width;
      expect(midWidth, greaterThan(0));
      expect(midWidth, lessThan(initialWidth));
      expect(
        find.byKey(const Key('new-conversation')).hitTestable(),
        findsNothing,
      );
      await t.pump(const Duration(milliseconds: 200));
      expect(t.getSize(panel).width, 0);
      await t.tap(find.byTooltip('展开会话'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 70));
      expect(
        find.byKey(const Key('new-conversation')).hitTestable(),
        findsNothing,
      );
      await t.pump(const Duration(milliseconds: 200));
      expect(t.getSize(panel).width, initialWidth);
      expect(c.current.draft, '保持草稿');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Call transition reverses on quick reopen and excludes the hidden view',
    (t) async {
      final c = JarvisController(
        FakeApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      c.current.messages.add(ChatMessage('assistant', '已有回复'));
      await t.pumpWidget(motionHost(c));
      await t.pump();
      c.voice.expand();
      await t.pump();
      await t.pump(const Duration(milliseconds: 90));
      final callState = t.state(find.byType(VoicePage));
      c.voice.minimize();
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      expect(find.byTooltip('结束语音通话').hitTestable(), findsNothing);
      c.voice.expand();
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      expect(identical(callState, t.state(find.byType(VoicePage))), true);
      c.voice.minimize();
      await t.pump();
      await t.pump(const Duration(milliseconds: 220));
      expect(find.byType(VoicePage), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'Reduced motion completes sidebar and call transitions immediately',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(
        FakeApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      c.current.messages.add(ChatMessage('assistant', '已有回复'));
      await t.pumpWidget(motionHost(c, reduced: true));
      await t.pump();
      await t.tap(find.byTooltip('收起会话'));
      await t.pump();
      expect(t.getSize(find.byKey(const Key('docked-sidebar'))).width, 0);
      c.voice.expand();
      await t.pump();
      expect(find.byType(VoicePage), findsOneWidget);
      c.voice.minimize();
      await t.pump();
      expect(find.byType(VoicePage), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('Restored maximum microphone sensitivity stays in slider range', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.settings.threshold = .2;
    await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
    await t.pump();
    expect(
      t.widget<Slider>(find.byKey(const Key('threshold-slider'))).value,
      1,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets(
    'Rename keeps its text controller alive through the exit animation',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await c.login('Wyatt', 'test');
      c.current.messages.add(ChatMessage('assistant', '已有回复'));
      await t.pumpWidget(motionHost(c));
      await t.pump();
      await t.tap(find.byTooltip('会话操作').first);
      await t.pumpAndSettle();
      await t.tap(find.text('重命名').last);
      await t.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await t.enterText(field, '内屏验收');
      await t.tap(find.text('保存'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 30));
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
      expect(c.current.title, '内屏验收');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/startup_scene.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/voice_mode_selector.dart';

import 'support.dart';
import 'voice_support.dart';

Future<void> frames(WidgetTester t, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets(
    'Real navigation safe area cannot produce an opposite jump on IME close',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      t.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
      t.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
      await t.enterText(find.byType(TextField).first, 'Audit');
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      t.view.padding = const FakeViewPadding(top: 28);
      await t.pump();
      await frames(t);
      final button = find.widgetWithText(FilledButton, '登录');
      var y = t.getTopLeft(button).dy;
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      await t.pump();
      expect(t.getTopLeft(button).dy, closeTo(y, .1));
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
        final next = t.getTopLeft(button).dy;
        expect(next, greaterThanOrEqualTo(y - .5));
        y = next;
      }
      final end = y;
      await t.pump(const Duration(milliseconds: 300));
      expect(t.getTopLeft(button).dy, closeTo(end, .1));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Expanded landscape keeps its form state and focus through IME and rotation',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
      await t.enterText(find.byType(TextField).first, 'Audit');
      await frames(t);
      final field = t.state(find.byType(EditableText).first);
      t.view.viewInsets = const FakeViewPadding(bottom: 250);
      await t.pump();
      await frames(t);
      expect(find.byKey(const ValueKey('login-reactor-size')), findsNothing);
      expect(
        t
            .widget<EditableText>(find.byType(EditableText).first)
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(
        identical(field, t.state(find.byType(EditableText).first)),
        isTrue,
      );
      expect(
        t.getBottomRight(find.widgetWithText(FilledButton, '登录')).dy,
        lessThanOrEqualTo(358.5),
      );

      t.view.physicalSize = const Size(608, 860);
      await t.pump();
      await frames(t);
      expect(
        identical(field, t.state(find.byType(EditableText).first)),
        isTrue,
      );
      expect(
        t
            .widget<EditableText>(find.byType(EditableText).first)
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Cached-session home uses one moving reactor; new conversations remain fresh',
    (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      Future<void> show(bool ready) => t.pumpWidget(
        MaterialApp(
          home: StartupGate(
            ready: ready,
            child: ListenableBuilder(
              listenable: c,
              builder: (_, _) => JarvisHome(controller: c),
            ),
          ),
        ),
      );
      await show(false);
      final original = t.state(find.byType(LoginScene));
      await show(true);
      await t.pump();
      await frames(t, 25);
      expect(find.byType(LoginScene), findsOneWidget);
      expect(identical(original, t.state(find.byType(LoginScene))), isTrue);
      await frames(t, 45);
      expect(find.byType(LoginScene), findsOneWidget);
      expect(identical(original, t.state(find.byType(LoginScene))), isTrue);
      c.current.messages.add(ChatMessage('user', '先聊一句'));
      c.newConversation();
      await t.pump();
      expect(find.byType(LoginScene), findsOneWidget);
      expect(identical(original, t.state(find.byType(LoginScene))), isFalse);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Large text switches mode controls to full-width rows; accessible recording starts and ends',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(320, 700);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(
        FakeApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      c.voice.ready = true;
      final semantics = t.ensureSemantics();
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              accessibleNavigation: true,
            ),
            child: child!,
          ),
          home: VoicePage(controller: c),
        ),
      );
      expect(find.byType(VoiceModeSelector), findsOneWidget);
      expect(
        t.getTopLeft(find.byKey(const ValueKey('voice-mode-vad'))).dy,
        greaterThan(
          t.getBottomRight(find.byKey(const ValueKey('voice-mode-ptt'))).dy,
        ),
      );
      final target = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '按住说话',
      );
      final node = t.getSemantics(target);
      expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.tap,
          viewId: t.view.viewId,
          nodeId: node.id,
        ),
      );
      await t.pump();
      expect(c.voice.held, isTrue);
      final endNode = t.getSemantics(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == '松开发送',
        ),
      );
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.tap,
          viewId: t.view.viewId,
          nodeId: endNode.id,
        ),
      );
      await t.pump();
      expect(c.voice.held, isFalse);
      expect(t.takeException(), isNull);
      semantics.dispose();
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

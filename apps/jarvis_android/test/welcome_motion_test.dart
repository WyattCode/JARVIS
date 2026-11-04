import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Tall phone standby reactor stays high and independent of hint length',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 900);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      Widget screen(String hint) => MaterialApp(
        home: Padding(
          padding: const EdgeInsets.all(20),
          child: VoiceIdentityStage(
            compact: false,
            windowHeight: 900,
            identity: 'stable',
            status: '已就绪',
            hint: hint,
            mode: ReactorMode.idle,
            onTap: () {},
            transcript: const SizedBox(),
          ),
        ),
      );
      await t.pumpWidget(screen('按住说话'));
      final before = t.getRect(find.byType(CoreAvatar));
      expect(before.top, lessThan(100));
      await t.pumpWidget(screen('麦克风暂时不可用，请恢复语音后继续对话。' * 8));
      await t.pump(const Duration(milliseconds: 600));
      expect(t.getRect(find.byType(CoreAvatar)), before);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Voice reactor retains one animation while moving to the transcript corner',
    (t) async {
      final compact = ValueNotifier(false);
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: ValueListenableBuilder(
              valueListenable: compact,
              builder: (_, value, _) => VoiceIdentityStage(
                compact: value,
                windowHeight: 800,
                identity: 'call',
                status: '正在聆听',
                hint: '按住说话',
                mode: ReactorMode.idle,
                onTap: () {},
                transcript: const Text('对话内容'),
              ),
            ),
          ),
        ),
      );
      final avatar = find.byType(CoreAvatar),
          opening = t.getRect(avatar),
          state = t.state(find.byType(LoginScene));
      compact.value = true;
      await t.pump();
      expect(t.getRect(avatar).width, closeTo(opening.width, .1));
      await t.pump(const Duration(milliseconds: 180));
      final middle = t.getRect(avatar);
      expect(middle.width, lessThan(opening.width));
      expect(middle.width, greaterThan(84));
      await t.pump(const Duration(milliseconds: 320));
      expect(t.getRect(avatar).width, closeTo(84, .1));
      expect(identical(state, t.state(find.byType(LoginScene))), true);
      expect(find.byType(LoginScene), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      compact.dispose();
    },
  );
  testWidgets(
    'Empty chat keeps its welcome composition stationary while only the composer lifts',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      final avatar = find.byType(CoreAvatar),
          start = t.getRect(avatar),
          state = t.state(find.byType(LoginScene));
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pump();
      expect(t.getRect(avatar).width, closeTo(start.width, .1));
      await t.pump(const Duration(milliseconds: 120));
      final middle = t.getRect(avatar).width;
      await t.pump(const Duration(milliseconds: 180));
      final end = t.getRect(avatar).width;
      expect(middle, closeTo(start.width, .1));
      expect(end, closeTo(start.width, .1));
      expect(t.getRect(avatar).top, closeTo(start.top, .1));
      expect(identical(state, t.state(find.byType(LoginScene))), true);
      t.view.viewInsets = FakeViewPadding.zero;
      await t.pump();
      expect(t.getRect(avatar).width, closeTo(end, .1));
      await t.pump(const Duration(milliseconds: 260));
      expect(t.getRect(avatar).width, closeTo(start.width, .1));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Welcome stays in place on outer, inner landscape and short landscape keyboards',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      for (final size in [
        const Size(425, 623),
        const Size(860, 608),
        const Size(623, 425),
      ]) {
        t.view.physicalSize = size;
        t.view.viewInsets = FakeViewPadding.zero;
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
        await t.pump();
        final avatar = find.byType(CoreAvatar);
        final before = avatar.evaluate().isEmpty ? null : t.getRect(avatar);
        t.view.viewInsets = const FakeViewPadding(bottom: 250);
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        if (before == null) {
          expect(avatar, findsNothing);
          expect(find.byKey(const ValueKey('starter-0')), findsOneWidget);
        } else {
          final after = t.getRect(avatar);
          expect(after.width, closeTo(before.width, .1));
          expect(after.top, closeTo(before.top, .1), reason: '$size');
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
}

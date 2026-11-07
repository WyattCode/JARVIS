import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/follow_scroll.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';

import 'foldable_test.dart' show host;
import 'support.dart';
import 'voice_support.dart';

void main() {
  test('Assistant expression follows text, playback and completion, excluding microphone and preview', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.session.held = true;
    expect(h.session.expressing, false);
    h.session.held = false;
    h.event({
      'type': 'response.created',
      'response': {'id': 'r'},
    });
    expect(h.session.expressing, false);
    h.event({
      'type': 'response.text.delta',
      'item_id': 'bot',
      'response_id': 'r',
      'delta': '你好',
    });
    expect(h.session.expressing, true);
    h.audio.output.add({'type': 'playback', 'active': true});
    h.audio.output.add({'type': 'playback', 'active': false});
    expect(h.session.status, '正在准备语音');
    expect(h.session.expressing, true);
    h.event({
      'type': 'response.done',
      'response': {'id': 'r', 'status': 'completed'},
    });
    expect(h.session.expressing, false);
    h.audio.output.add({'type': 'playback', 'active': true});
    expect(h.session.expressing, true);
    h.session.previewing = true;
    expect(h.session.expressing, false);
    h.session.previewing = false;
    await h.session.interrupt();
    expect(h.session.expressing, false);
    await h.close();
  });
  testWidgets(
    'Native Back closes a menu before the page; new user message resumes tail following',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await c.login('Audit', 'test');
      c.current.messages.addAll(
        List.generate(
          40,
          (i) => ChatMessage(
            i.isEven ? 'user' : 'assistant',
            '消息$i\n历史阅读测试。\n保留位置。',
          ),
        ),
      );
      await t.pumpWidget(host(c));
      await t.pumpAndSettle();
      for (final tooltip in ['会话操作', '更多操作', '选择思考深度']) {
        await t.tap(find.byTooltip(tooltip).first);
        await t.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsWidgets);
        expect(
          await Navigator.of(t.element(find.byType(JarvisHome))).maybePop(),
          true,
        );
        await t.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.byType(JarvisHome), findsOneWidget);
      }
      final list = find.descendant(
        of: find.byType(ChatPanel),
        matching: find.byType(ListView),
      );
      final scroll =
          t.widget<ListView>(list).controller! as FollowScrollController;
      await t.drag(list, const Offset(0, 300));
      await t.pumpAndSettle();
      final reading = scroll.offset;
      c.current.messages.add(ChatMessage('assistant', '后台回复继续'));
      c.notifyDraftSuggestion();
      await t.pump();
      await t.pump();
      expect(scroll.offset, closeTo(reading, .1));
      c.current.messages.add(ChatMessage('user', '新的问题'));
      c.notifyDraftSuggestion();
      await t.pump();
      await t.pump();
      expect(scroll.position.extentAfter, closeTo(0, .1));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Tall phone compact reactor and both labels are larger without crowding the transcript',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 869),
              disableAnimations: true,
            ),
            child: VoiceIdentityStage(
              compact: true,
              windowHeight: 869,
              identity: 'tall',
              status: '正在说话',
              hint: '随时可以打断我',
              mode: ReactorMode.speaking,
              onTap: () {},
              transcript: const SizedBox(key: Key('body')),
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.widget<CoreAvatar>(find.byType(CoreAvatar)).size, 120);
      expect(t.widget<Text>(find.text('正在说话')).style!.fontSize, 18);
      expect(t.widget<Text>(find.text('随时可以打断我')).style!.fontSize, 14);
      expect(t.getSize(find.byKey(const Key('body'))).height, greaterThan(500));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}

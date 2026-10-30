import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'support.dart';
import 'voice_support.dart';

class LayoutApi extends VoiceApi {
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo(
      'chat',
      'Chat',
      metadata: {
        'jarvis': {
          'voice_effort_models': {'high': 'chat--high'},
        },
      },
    ),
    ModelInfo(
      'speech',
      'Drama 3',
      kind: 'speech',
      defaultVoice: 'Atlas',
      voices: const [
        VoiceInfo('Atlas', 'Atlas', 'A clear, steady voice'),
        VoiceInfo('Mae', 'Mae', 'A warm, expressive voice'),
      ],
    ),
  ];
}

Widget host(Widget child, {double scale = 1}) => MaterialApp(
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh')],
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);
Future<void> settleTask(WidgetTester t, Future<void> task) async {
  var done = false;
  Object? error;
  task.then(
    (_) {
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 100 && !done; i++) {
    await t.pump();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(done, true);
  if (error != null) throw error!;
}

void main() {
  testWidgets('Reasoning expansion does not read the chat scroll offset', (
    t,
  ) async {
    final c = JarvisController(
      LayoutApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    final message = ChatMessage('assistant', '文件已读');
    c.current.messages.add(message);
    final bucket = PageStorageBucket();
    Widget screen() => host(
      Scaffold(
        body: PageStorage(
          bucket: bucket,
          child: ChatPanel(controller: c),
        ),
      ),
    );
    await t.pumpWidget(screen());
    await t.pump();
    final list = find.byKey(PageStorageKey('messages-${c.current.id}'));
    // A previous scroll/route transition already stored a double here.
    bucket.writeState(t.element(list), 120.0);
    message.reasoning = '检查附件内容';
    await t.pumpWidget(screen());
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    await t.tap(find.text('思考过程'));
    await t.pumpAndSettle();
    expect(find.text('检查附件内容'), findsOneWidget);
    expect(bucket.readState(t.element(list)), 120.0);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Full-screen voice excludes background chat from accessibility', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final c = JarvisController(
      LayoutApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    await c.login('user', 'test');
    await t.pumpWidget(host(JarvisHome(controller: c)));
    await t.pump();
    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == '语音对话' || node.getSemanticsData().tooltip == '语音对话',
      ),
      findsOneWidget,
    );
    await settleTask(t, c.voice.start(c.current));
    await t.pump();
    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == '语音对话' || node.getSemanticsData().tooltip == '语音对话',
      ),
      findsNothing,
    );
    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == '结束语音通话' ||
            node.getSemanticsData().tooltip == '结束语音通话',
      ),
      findsOneWidget,
    );
    c.voice.minimize();
    await t.pump();
    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == '语音对话' || node.getSemanticsData().tooltip == '语音对话',
      ),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
    await settleTask(t, c.voice.stop());
    c.dispose();
    semantics.dispose();
  });

  testWidgets(
    'Voice picker applies the chosen voice without restarting or leaving partial output generating',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(360, 600);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(
        LayoutApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      await c.login('user', 'test');
      await t.runAsync(() => c.voice.start(c.current));
      c.voice.handle({
        'type': 'session.updated',
        'session': {
          'speech_model': 'speech',
          'voice': 'Atlas',
          'model': 'chat--high',
          'reasoning': true,
        },
      });
      c.voice.handle({
        'type': 'response.created',
        'response': {'id': 'old'},
      });
      c.voice.handle({
        'type': 'response.audio_transcript.delta',
        'response_id': 'old',
        'item_id': 'old-item',
        'delta': '先前说到这里',
      });
      await t.pumpWidget(host(VoicePage(controller: c), scale: 1.5));
      await t.pump();
      await t.tap(find.text('Atlas'));
      await t.pumpAndSettle();
      expect(find.text('选择音色'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('Mae'));
      await t.pump(const Duration(milliseconds: 250));
      expect(c.settings.voices['speech'], 'Mae');
      expect(c.voice.active, true);
      expect(c.voice.ready, false);
      expect(c.current.messages.last.status, 'interrupted');
      c.voice.handle({
        'type': 'session.updated',
        'session': {
          'speech_model': 'speech',
          'voice': 'Mae',
          'model': 'chat--high',
          'reasoning': true,
        },
      });
      expect(c.voice.ready, true);
      Navigator.of(t.element(find.text('选择音色'))).pop();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => c.voice.stop());
      c.dispose();
    },
  );

  testWidgets(
    'Voice controls and transcript remain visible across fold profiles, errors and large text',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final api = LayoutApi(), audio = FakeAudio();
      final c = JarvisController(api, MemoryVault(), audioDevice: audio);
      await c.initialize();
      await c.login('user', 'test');
      await t.runAsync(() => c.voice.start(c.current));
      c.voice.handle({
        'type': 'session.updated',
        'session': {
          'speech_model': 'speech',
          'voice': 'Atlas',
          'model': 'chat--high',
          'reasoning': true,
        },
      });
      c.current.tasks.add(
        MediaTask(id: 'task', kind: 'video', prompt: '测试作品', args: {}),
      );
      c.voice.lastYou = '这是一段较长的用户语音转写，用来检查外屏和展开屏的文字显示。';
      c.voice.lastBot = List.filled(20, '这是逐步输出的回复，文字应当滚动显示。').join();
      for (final size in [
        const Size(425, 623),
        const Size(623, 425),
        const Size(608, 860),
        const Size(860, 608),
        const Size(360, 540),
      ]) {
        t.view.physicalSize = size;
        for (final scale in [1.0, 1.5]) {
          c.voice.error = '麦克风暂时被其他应用占用，请恢复语音后继续对话';
          await t.pumpWidget(host(VoicePage(controller: c), scale: scale));
          await t.pump();
          expect(t.takeException(), isNull, reason: '$size/$scale');
          final hold = t.getRect(find.byKey(const Key('voice-talk')));
          expect(hold.bottom, lessThanOrEqualTo(size.height));
          expect(hold.height, greaterThanOrEqualTo(48));
          expect(
            t.getRect(find.byKey(const Key('voice-transcript'))).height,
            greaterThan(24),
          );
          expect(find.byTooltip('结束语音通话').hitTestable(), findsOneWidget);
        }
      }
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => c.voice.stop());
      c.dispose();
    },
  );
  testWidgets('Settings stay scrollable on a narrow screen with large text', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 540);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(
      LayoutApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    await c.login('user', 'test');
    await t.pumpWidget(host(SettingsPage(controller: c), scale: 1.5));
    await t.pump();
    expect(t.takeException(), isNull);
    await t.scrollUntilVisible(
      find.text('回声抑制'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(t.takeException(), isNull);
    await t.scrollUntilVisible(
      find.text('退出登录'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

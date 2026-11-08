import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'foldable_test.dart' show host;
import 'support.dart';
import 'voice_layout_test.dart' show LayoutApi;
import 'voice_support.dart' show FakeAudio;

import 'package:jarvis_android/ui/settings_page.dart';

void main() {
  testWidgets('Large accessibility text leaves a usable voice transcript', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 176,
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 540),
                textScaler: TextScaler.linear(2.5),
                disableAnimations: true,
              ),
              child: VoiceIdentityStage(
                compact: true,
                windowHeight: 540,
                identity: 'audit',
                status: '需要恢复语音',
                hint: '麦克风暂时被其他应用占用，请恢复语音后继续对话',
                mode: ReactorMode.idle,
                onTap: () {},
                minimumTranscriptExtent: 112,
                transcript: const SingleChildScrollView(
                  key: Key('readable-transcript'),
                  child: Text('测试正文'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      t.getSize(find.byKey(const Key('readable-transcript'))).height,
      greaterThan(72),
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'A conversation row is 58 high and held, it offers rename and delete',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(860, 608);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await c.login('Audit', 'test');
      await t.pumpWidget(host(c));
      await t.pump();
      expect(
        t
            .getSize(
              find.byKey(ValueKey('conversation-surface-${c.current.id}')),
            )
            .height,
        closeTo(58, .1),
      );
      await openConversationMenu(t);
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('Voice messages respect the same font preference as chat', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.settings.messageFontSize = 24;
    c.voice.lastYou = '测试提问';
    c.voice.lastBot = '测试回答';
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 869),
            disableAnimations: true,
          ),
          child: VoicePage(controller: c),
        ),
      ),
    );
    await t.pump();
    // What you said is in a pill; the reply is the lit text. Both use the
    // chat's font size.
    final you = t.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('voice-you')),
        matching: find.byType(Text),
      ),
    );
    expect(you.data, '测试提问');
    expect(you.style?.fontSize, 24);
    final bot = t
        .widgetList<RichText>(
          find.descendant(
            of: find.byKey(const Key('voice-transcript')),
            matching: find.byType(RichText),
          ),
        )
        .last;
    expect(bot.text.toPlainText(), '测试回答');
    final sizes = <double?>[];
    bot.text.visitChildren((span) {
      if (span is TextSpan && span.text != null) {
        sizes.add(span.style?.fontSize);
      }
      return true;
    });
    expect(sizes, isNotEmpty);
    expect(sizes.every((s) => s == 24), true);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Voice rows expose and update the selected choice', (t) async {
    final c = JarvisController(
      LayoutApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await c.initialize();
    await c.login('Audit', 'test');
    await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
    await t.pump();
    await t.ensureVisible(find.text('Atlas'));
    await t.pump();
    expect(
      t.widget<ListTile>(find.widgetWithText(ListTile, 'Atlas')).selected,
      true,
    );
    await t.ensureVisible(find.text('Mae'));
    await t.pump();
    await t.tap(find.text('Mae'));
    await t.pump();
    expect(
      t.widget<ListTile>(find.widgetWithText(ListTile, 'Mae')).selected,
      true,
    );
    expect(
      t.widget<ListTile>(find.widgetWithText(ListTile, 'Atlas')).selected,
      false,
    );
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

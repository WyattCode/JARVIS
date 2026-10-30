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
    'Conversation menu has round targets and conversation row is 58 while the new-chat button stays 53',
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
        t.getSize(find.byKey(const Key('new-conversation'))).height,
        closeTo(53, .1),
      );
      final list = find.byKey(const Key('conversation-list'));
      final tile = find
          .descendant(of: list, matching: find.byType(ListTile))
          .first;
      expect(t.getSize(tile).height, closeTo(58, .1));
      final button = t.widget<IconButton>(
        find
            .byWidgetPredicate((w) => w is IconButton && w.tooltip == '会话操作')
            .first,
      );
      expect(button.style!.shape!.resolve({}), isA<CircleBorder>());
      await t.tap(find.byTooltip('会话操作').first);
      await t.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, '重命名'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, '删除'), findsOneWidget);
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
    final text = t
        .widgetList<SelectableText>(find.byType(SelectableText))
        .where((w) => w.data?.contains('测试') == true)
        .toList();
    expect(text.length, 2);
    expect(text.every((w) => w.style?.fontSize == 24), true);
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
    // Clear of the frosted chip bar at the top of the page.
    await t.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, 150),
    );
    await t.pump();
    expect(
      t.widget<ListTile>(find.widgetWithText(ListTile, 'Atlas')).selected,
      true,
    );
    await t.ensureVisible(find.text('Mae'));
    // Clear of the frosted chip bar at the top of the page.
    await t.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, 150),
    );
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

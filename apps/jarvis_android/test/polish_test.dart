import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/markdown_style.dart';

import 'support.dart';

void main() {
  testWidgets('a new message fades in; history and rebuilds do not replay', (
    t,
  ) async {
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = const Size(1179, 2556);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    addTearDown(c.dispose);
    c.conversations.clear();
    c.conversations.add(Conversation('p', title: 'probe'));
    c.selectedId = 'p';
    c.current.messages.addAll([
      ChatMessage('user', '历史一'),
      ChatMessage('user', '历史二'),
    ]);
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump(const Duration(milliseconds: 400));

    double opacityOf(String text) => t
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.text(text),
            matching: find.byType(FadeTransition),
          ),
        )
        .map((f) => f.opacity.value)
        .reduce((a, b) => a < b ? a : b);

    expect(opacityOf('历史二'), 1);
    c.current.messages.add(ChatMessage('user', '新消息'));
    c.notifyListeners();
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    expect(opacityOf('新消息'), lessThan(1), reason: '刚到的消息渐显');
    expect(opacityOf('历史二'), 1, reason: '历史不重播动画');
    await t.pump(const Duration(milliseconds: 700));
    expect(opacityOf('新消息'), 1);
    // A later rebuild (for example streaming into another message) never replays it.
    c.notifyListeners();
    await t.pump();
    expect(opacityOf('新消息'), 1);
  });

  testWidgets('code block: the copy button confirms in place', (t) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CodeBlock(code: 'print(1);', language: 'dart'),
        ),
      ),
    );
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    await t.tap(find.text('复制'));
    await t.pump(const Duration(milliseconds: 200));
    expect(copied, ['print(1);']);
    expect(find.text('已复制'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('复制'), findsOneWidget);
  });
}

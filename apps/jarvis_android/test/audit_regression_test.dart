import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/sidebar_split.dart';

import 'support.dart';
import 'voice_support.dart';

void main() {
  testWidgets(
    'Edge grip exclusion clears when another route covers the split',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      const channel = MethodChannel('cc.odn.jarvis/layout');
      final calls = <MethodCall>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: SidebarSplit(
              width: 240,
              visible: false,
              duration: Duration.zero,
              onChanged: (_) {},
              content: const SizedBox.expand(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await t.pump();
      final rect = List<int>.from(calls.last.arguments as List);
      expect(rect[0], 0);
      expect(rect[2], 48);
      expect(rect[3] - rect[1], 80);
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await t.pumpAndSettle();
      expect(calls.last.arguments, isEmpty);
      navigator.currentState!.pop();
      await t.pumpAndSettle();
      expect(calls.last.arguments, hasLength(4));
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(calls.last.arguments, isEmpty);
    },
  );
  testWidgets('Unsupported Markdown image URLs cannot crash the chat view', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.current.messages.add(
      ChatMessage(
        'assistant',
        '![image](data:image/png;base64,AAAA)\n\n![other](//outside.example/image.png)',
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPanel(controller: c)),
      ),
    );
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('图片地址不可用'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'other'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  test(
    'An active voice owner survives deletion until the call stops',
    () async {
      final c = JarvisController(
        CatalogVoiceApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      await c.login('Wyatt', 'test');
      c.settings.speechModel = 'speech';
      c.settings.voices['speech'] = 'Atlas';
      final owner = c.current;
      try {
        await c.voice.start(owner);
        expect(c.voice.active, true);
        c.voice.minimize();
        c.newConversation();
        expect(c.deleteConversation(owner.id), isNull);
        expect(c.conversations, contains(owner));
        final other = c.current;
        expect(c.deleteConversation(other.id), same(other));
        await c.voice.stop();
        expect(c.deleteConversation(owner.id), same(owner));
      } finally {
        await c.voice.stop();
        c.dispose();
      }
    },
  );

  testWidgets('Grip tracks the pointer and supports keyboard activation', (
    t,
  ) async {
    bool visible = true;
    await t.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) {
            return Scaffold(
              body: SidebarSplit(
                width: 240,
                visible: visible,
                duration: const Duration(milliseconds: 200),
                onChanged: (value) => update(() => visible = value),
                content: const SizedBox.expand(),
                child: const SizedBox.expand(),
              ),
            );
          },
        ),
      ),
    );
    final grip = find.byKey(const Key('pane-grip'));
    expect(t.getSize(grip).width, greaterThanOrEqualTo(48));
    final drag = await t.startGesture(t.getCenter(grip));
    await drag.moveBy(const Offset(-30, 0));
    await t.pump();
    final before = t.getCenter(grip);
    await drag.moveBy(const Offset(-40, 0));
    await t.pump();
    expect(t.getCenter(grip).dx - before.dx, closeTo(-40, .1));
    await drag.cancel();
    await t.pumpAndSettle();
    Focus.of(t.element(grip)).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pumpAndSettle();
    expect(visible, false);
    final content = t.getRect(find.byKey(const Key('split-content')));
    expect(content.left, 0);
    expect(content.right, t.view.physicalSize.width / t.view.devicePixelRatio);
    expect(t.getRect(grip).left, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(visible, true);
  });

  testWidgets(
    'Send reflects empty drafts and keeps stop available during generation',
    (t) async {
      final api = FakeApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('Wyatt', 'test');
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) =>
                  Composer(controller: c, keyboardVisible: false),
            ),
          ),
        ),
      );
      IconButton button(String tooltip) => t.widget<IconButton>(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip),
      );
      expect(find.byTooltip('发送'), findsNothing);
      expect(button('语音对话').onPressed, isNotNull);
      await t.enterText(find.byKey(const Key('chat-input')), '  ');
      await t.pump();
      expect(find.byTooltip('发送'), findsNothing);
      expect(button('语音对话').onPressed, isNotNull);
      await t.enterText(find.byKey(const Key('chat-input')), '你好');
      await t.pump();
      expect(button('发送').onPressed, isNotNull);
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      expect(button('停止当前回复').onPressed, isNotNull);
      await t.tap(find.byTooltip('停止当前回复'));
      await t.pump();
      expect(find.byTooltip('发送'), findsNothing);
      expect(button('语音对话').onPressed, isNotNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

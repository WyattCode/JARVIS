import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

class BlockingVault extends MemoryVault {
  Completer<void>? gate;
  @override
  Future<void> write(String value) async {
    await gate?.future;
    await super.write(value);
  }
}

void main() {
  test('Reply controls finish before a slow encrypted save', () async {
    final api = FakeApi();
    final vault = BlockingVault();
    final c = JarvisController(api, vault);
    await c.initialize();
    await c.login('Wyatt', 'test');
    c.setDraft('test');
    final send = c.send();
    await Future<void>.delayed(Duration.zero);
    var sawCompletion = false;
    c.addListener(() {
      if (!c.isGenerating(c.current.id) &&
          c.current.messages.last.text == 'OK') {
        sawCompletion = true;
      }
    });
    vault.gate = Completer<void>();
    try {
      final stream = api.streams.values.single;
      stream.add(const ChatDelta(text: 'OK', done: true));
      await stream.close();
      await Future<void>.delayed(Duration.zero);
      expect(sawCompletion, true);
    } finally {
      vault.gate!.complete();
      await send;
      c.dispose();
    }
  });
  test(
    'A burst of stream deltas keeps all content with one scheduled refresh',
    () async {
      final api = FakeApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('Wyatt', 'test');
      c.setDraft('test');
      final send = c.send();
      await Future<void>.delayed(Duration.zero);
      var notifications = 0;
      c.addListener(() => notifications++);
      final stream = api.streams.values.single;
      for (var i = 0; i < 200; i++) {
        stream.add(const ChatDelta(text: '文', reasoning: '思'));
      }
      await Future<void>.delayed(Duration.zero);
      expect(c.current.messages.last.text, List.filled(200, '文').join());
      expect(notifications, 0);
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(notifications, 1);
      stream.add(const ChatDelta(done: true));
      await stream.close();
      await send;
      expect(c.current.messages.last.reasoning, List.filled(200, '思').join());
      expect(c.isGenerating(c.current.id), false);
      expect(notifications, 2);
      c.dispose();
    },
  );

  testWidgets(
    'Router is unchanged by chat updates; theme and login remain reactive',
    (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump();
      expect(find.byType(LoginPage), findsOneWidget);
      final login = c.login('Wyatt', 'test');
      await t.pump();
      await login;
      await t.pump();
      expect(find.byType(JarvisHome), findsOneWidget);
      final shell = t.widget<MaterialApp>(find.byType(MaterialApp));
      for (var i = 0; i < 100; i++) {
        c.notifyDraftSuggestion();
      }
      await t.pump();
      expect(
        identical(shell, t.widget<MaterialApp>(find.byType(MaterialApp))),
        true,
      );
      c.setTheme('dark');
      await t.pump();
      final themed = t.widget<MaterialApp>(find.byType(MaterialApp));
      expect(themed.themeMode, ThemeMode.dark);
      expect(identical(shell.theme, themed.theme), true);
      expect(identical(shell.darkTheme, themed.darkTheme), true);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Four starters form two equal rows and keep their own prompts', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 600);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    for (final scale in [1.0, 1.5]) {
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 600),
              disableAnimations: true,
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(body: ChatPanel(controller: c)),
          ),
        ),
      );
      await t.pump();
      final rects = [
        for (var i = 0; i < 4; i++)
          t.getRect(find.byKey(ValueKey('starter-$i'))),
      ];
      expect(rects[0].width, rects[1].width);
      expect(rects[0].top, rects[1].top);
      expect(rects[2].top, rects[3].top);
      expect(rects[2].top, greaterThan(rects[0].bottom));
      expect(rects.every((r) => r.height >= 48), true);
      await t.tap(find.byKey(const ValueKey('starter-2')));
      // A starter's prompt goes after what is written (on its own line).
      expect(c.current.draft, endsWith(c.starters[2].prompt));
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Attachment-only message has no empty text field', (t) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.current.messages.add(
      ChatMessage(
        'user',
        '',
        attachments: [
          Attachment(
            id: 'text',
            name: 'note.txt',
            mime: 'text/plain',
            kind: 'document',
            text: 'hello',
          ),
        ],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPanel(controller: c)),
      ),
    );
    await t.pump();
    expect(find.text('note.txt'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

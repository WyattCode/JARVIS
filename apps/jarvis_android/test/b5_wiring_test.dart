import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'b2_support.dart';
import 'b3_support.dart';
import 'support.dart';

void main() {
  test(
    'cancelling a running media task frees the conversation again',
    () async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final task = MediaTask(
        id: 't1',
        kind: 'video',
        prompt: '一只猫',
        args: const {},
        status: 'in_progress',
      );
      c.current.tasks.add(task);
      expect(task.pending, isTrue);
      await c.cancelMediaTask(task);
      expect(task.pending, isFalse);
      expect(task.status, 'interrupted');
      expect(task.error, '已取消');
      c.dispose();
    },
  );

  testWidgets('the first message asks about AI data use once', (t) async {
    final api = FakeApi();
    final c = await pumpWired(
      t,
      straightPhones.first,
      api: api,
      seed: connected,
    );
    await t.enterText(find.byKey(const Key('chat-input')), '你好');
    await t.pump();
    await t.tap(find.byTooltip('发送'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('同意'), findsOneWidget);
    // Declining sends nothing.
    await t.tap(find.text('暂不'));
    await t.pump(const Duration(milliseconds: 400));
    expect(c.current.messages, isEmpty);
    expect(c.settings.aiNoticeAccepted, isFalse);
    // Agreeing sends, and the notice is remembered.
    await t.tap(find.byTooltip('发送'));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.text('同意'));
    await t.pump(const Duration(milliseconds: 400));
    expect(c.settings.aiNoticeAccepted, isTrue);
    expect(c.current.messages.where((m) => m.role == 'user'), isNotEmpty);
    await t.pump(const Duration(seconds: 2));
  });
}

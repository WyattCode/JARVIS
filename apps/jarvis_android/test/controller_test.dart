import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';

void main() {
  test(
    'Switching and creating conversations does not cancel another generation',
    () async {
      final api = FakeApi(), vault = MemoryVault();
      final state = JarvisController(api, vault);
      await state.initialize();
      await state.login('Wyatt', 'not-a-real-password');
      final firstId = state.current.id;
      state.setDraft('first');
      final a = state.send();
      await Future<void>.delayed(Duration.zero);
      final streamA = api.streams.values.single;
      state.newConversation();
      final secondId = state.current.id;
      state.setDraft('second');
      final b = state.send();
      await Future<void>.delayed(Duration.zero);
      final streamB = api.streams.values.last;
      streamA.add(const ChatDelta(text: '第一轮回复'));
      streamB.add(const ChatDelta(reasoning: '第二轮思考', text: '第二轮回复'));
      streamA.add(const ChatDelta(done: true));
      streamB.add(const ChatDelta(done: true));
      await streamA.close();
      await streamB.close();
      await Future.wait([a, b]);
      expect(
        state.conversations
            .firstWhere((c) => c.id == firstId)
            .messages
            .last
            .text,
        '第一轮回复',
      );
      expect(
        state.conversations
            .firstWhere((c) => c.id == secondId)
            .messages
            .last
            .text,
        '第二轮回复',
      );
      expect(api.cancelled, isEmpty);
      expect(state.effort, 'high');
      state.dispose();
    },
  );
  test('Cancel and resend use distinct request IDs', () async {
    final api = FakeApi();
    final c = JarvisController(api, MemoryVault());
    await c.initialize();
    await c.login('Wyatt', 'test');
    c.setDraft('first');
    final first = c.send();
    await Future<void>.delayed(Duration.zero);
    final firstRequest = api.streams.keys.single;
    c.cancel(c.current.id);
    c.setDraft('retry');
    final second = c.send();
    await Future<void>.delayed(Duration.zero);
    final secondRequest = api.streams.keys.last;
    expect(secondRequest, isNot(firstRequest));
    c.cancel(c.current.id);
    await Future.wait([first, second]);
    expect(api.cancelled, [firstRequest, secondRequest]);
    c.dispose();
  });
  test(
    'Persist reasoning, selected conversation and drafts; never save password',
    () async {
      final vault = MemoryVault();
      final state = JarvisController(FakeApi(), vault);
      await state.initialize();
      await state.login('Wyatt', 'password-must-never-be-saved');
      state.setDraft('保留的草稿');
      state.setEffort('medium');
      await state.save();
      expect(vault.value, isNot(contains('password-must-never-be-saved')));
      final restored = JarvisController(FakeApi(), vault);
      await restored.initialize();
      expect(restored.current.draft, '保留的草稿');
      expect(restored.effort, 'medium');
      expect(jsonDecode(vault.value!)['version'], 1);
      state.dispose();
      restored.dispose();
    },
  );
  test('A stream closing without terminal delta preserves partial output and marks interruption', () async {
    final api = FakeApi();
    final state = JarvisController(api, MemoryVault());
    await state.initialize();
    await state.login('Wyatt', 'test');
    state.setDraft('你好');
    final future = state.send();
    await Future<void>.delayed(Duration.zero);
    final stream = api.streams.values.single;
    stream.add(const ChatDelta(text: '尚未完成'));
    await stream.close();
    await future;
    expect(state.current.messages.last.text, '尚未完成');
    expect(state.current.messages.last.status, 'interrupted');
    state.dispose();
  });
  test('Background stream errors stay attached to their own reply', () async {
    final api = FakeApi();
    final c = JarvisController(api, MemoryVault());
    await c.initialize();
    await c.login('Wyatt', 'test');
    c.setDraft('后台请求');
    final source = c.current;
    final job = c.send();
    await Future<void>.delayed(Duration.zero);
    final stream = api.streams.values.single;
    c.newConversation();
    stream.addError(Exception('simulated disconnect'));
    await stream.close();
    await job;
    expect(c.error, isNull);
    expect(c.current.messages, isEmpty);
    expect(source.messages.last.error, contains('连接中断'));
    c.dispose();
  });
  test(
    'Process restoration marks unfinished generation as interrupted',
    () async {
      final vault = MemoryVault()
        ..value = jsonEncode({
          'version': 1,
          'selectedId': 'saved',
          'conversations': [
            {
              'id': 'saved',
              'messages': [
                {'role': 'assistant', 'text': '半句', 'status': 'generating'},
              ],
            },
          ],
        });
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      expect(c.current.messages.single.status, 'interrupted');
      c.dispose();
    },
  );
}

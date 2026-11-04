import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';

class SlowCatalogApi extends FakeApi {
  final delayed = Completer<List<ModelInfo>>();
  bool slow = false;
  @override
  Future<List<ModelInfo>> models() => slow ? delayed.future : super.models();
}

class SlowSkillApi extends FakeApi {
  final delayed = Completer<Map<String, dynamic>>();
  bool slow = false;
  @override
  Future<Map<String, dynamic>> modelSkill() async =>
      slow ? await delayed.future : {'enabled': false, 'text': ''};
}

class ManagementApi extends FakeApi {
  final histories = <List<Map<String, dynamic>>>[];
  final invoked = <String>[];
  @override
  Future<Map<String, dynamic>> modelSkill() async => {
    'enabled': true,
    'text': 'Use the server-provided model manager.',
  };
  @override
  Stream<ChatDelta> chat(
    String requestId,
    String model,
    String effort,
    List<Map<String, dynamic>> messages, {
    ChatOptions options = const ChatOptions(),
  }) async* {
    expect(
      options.tools.map((t) => t['function']['name']),
      contains('list_models'),
    );
    histories.add(messages);
    if (histories.length == 1) {
      yield const ChatDelta(
        toolDeltas: [ToolDelta(0, 'list1', 'list_models', '{}')],
        finishReason: 'tool_calls',
        done: true,
      );
    } else {
      yield const ChatDelta(text: '模型状态已查到。', done: true);
    }
  }

  @override
  Future<String> modelTool(
    String requestId,
    String name,
    Map<String, dynamic> args,
  ) async {
    invoked.add(name);
    return '{"result":"ready"}';
  }
}

void main() {
  test(
    'A delayed model catalog cannot restore authentication after logout',
    () async {
      final api = SlowCatalogApi();
      final state = JarvisController(api, MemoryVault());
      await state.initialize();
      await state.login('Wyatt', 'test');
      api.slow = true;
      final load = state.connect();
      await Future<void>.delayed(Duration.zero);
      await state.logout();
      api.delayed.complete([ModelInfo('late', 'Late')]);
      await load;
      expect(state.authenticated, false);
      expect(api.cookie, isNull);
      state.dispose();
    },
  );
  test(
    'A delayed failed skill lookup cannot restore authentication after logout',
    () async {
      final api = SlowSkillApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('Wyatt', 'test');
      api.slow = true;
      final load = c.connect();
      await Future<void>.delayed(Duration.zero);
      await c.logout();
      api.delayed.completeError(Exception('offline'));
      await load;
      expect(c.authenticated, false);
      expect(api.cookie, isNull);
      c.dispose();
    },
  );
  test(
    'Model manager continuation preserves tool provenance in the next request',
    () async {
      final api = ManagementApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('Wyatt', 'test');
      c.setDraft('当前有哪些模型？');
      await c.send();
      expect(api.invoked, ['list_models']);
      expect(api.histories.length, 2);
      final result = api.histories.last
          .where((m) => m['role'] == 'tool')
          .single;
      expect(result['tool_call_id'], 'list1');
      expect(result['content'], contains('ready'));
      expect(c.current.messages.last.text, '模型状态已查到。');
      expect(c.isGenerating(c.current.id), false);
      c.dispose();
    },
  );
  test('Restored ASR options are normalized to actual selectable values', () {
    final s = ChatSettings()
      ..restore({'language': 'xx-invalid', 'waitMs': 777});
    expect(s.language, '');
    expect(s.waitMs, 800);
  });
}

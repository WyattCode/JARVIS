import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/model/text_clip.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/local_data.dart';
import 'package:jarvis_android/state/vault.dart';

import 'support.dart';

class CountingConversation extends Conversation {
  CountingConversation(super.id, {super.title});
  int encoded = 0;
  @override
  Map<String, Object?> toJson() {
    encoded++;
    return super.toJson();
  }
}

/// Unreadable until the user starts fresh, like a vault whose file cannot be decrypted.
class BlockedVault extends MemoryVault implements UnreadableKeeper {
  bool kept = false;
  @override
  Future<String?> read() async {
    if (!kept) throw Exception('cannot decrypt');
    return value;
  }

  @override
  Future<void> keepUnreadable() async {
    kept = true;
  }
}

class ModelToolApi extends FakeApi {
  final called = <String>[];
  @override
  Future<Map<String, dynamic>> modelSkill() async => {
    'enabled': true,
    'text': '模型管理',
  };
  @override
  Future<String> modelTool(
    String requestId,
    String name,
    Map<String, dynamic> args,
  ) async {
    called.add(name);
    return '{"ok":true}';
  }
}

Attachment image(String id) =>
    Attachment(id: id, name: '$id.jpg', mime: 'image/jpeg', kind: 'image');

void main() {
  group('titles are cut between characters', () {
    Future<JarvisController> ready() async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await c.login('a', 'b');
      return c;
    }

    Future<String> titleFor(String text) async {
      final c = await ready();
      c.setDraft(text);
      final sent = c.send();
      await Future<void>.delayed(Duration.zero);
      final title = c.current.title;
      c.cancel(c.current.id);
      await sent;
      c.dispose();
      return title;
    }

    test(
      'an emoji on the 24th character is kept whole or dropped whole',
      () async {
        final title = await titleFor('${'a' * 23}😀 and more text after it');
        expect(title, '${'a' * 23}😀…');
        expect(wellFormed(title), title);
        // The same cut one character earlier lands before the emoji.
        expect(await titleFor('${'a' * 24}😀'), '${'a' * 24}…');
      },
    );

    test(
      'a family emoji (several code points) counts as one character',
      () async {
        final title = await titleFor('${'b' * 23}👨‍👩‍👧‍👦tail');
        expect(title, '${'b' * 23}👨‍👩‍👧‍👦…');
      },
    );

    test('line breaks and runs of blanks collapse into one line', () async {
      expect(await titleFor('  第一行\n\n第二行\t\t第三行  \n'), '第一行 第二行 第三行');
    });

    testWidgets('a boundary title renders without an exception', (t) async {
      final title = tidyTitle('${'c' * 23}😀😀😀');
      await t.pumpWidget(MaterialApp(home: Text(title)));
      expect(t.takeException(), isNull);
    });

    test('a title saved cut in half is repaired on load', () async {
      final vault = MemoryVault();
      final broken = '${'d' * 23}\ud83d…';
      vault.value = jsonEncode({
        'version': 1,
        'conversations': [
          (Conversation(
            'x',
            title: broken,
          )..messages.add(ChatMessage('user', 'hi'))).toJson(),
        ],
        'selectedId': 'x',
      });
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      final title = c.conversations.single.title;
      expect(wellFormed(title), title);
      expect(title, startsWith('d' * 23));
      c.dispose();
    });

    test('the transcription prompt is cut between characters too', () {
      final s = ChatSettings()
        ..restore({'transcriptionPrompt': '${'p' * 499}😀😀'});
      expect(s.transcriptionPrompt, '${'p' * 499}😀');
      expect(wellFormed(s.transcriptionPrompt), s.transcriptionPrompt);
    });
  });

  group('server urls with null entries', () {
    test('a saved task drops them instead of failing later', () {
      final task = MediaTask.fromJson({
        'id': 't',
        'kind': 'image',
        'urls': ['/a.png', null, 3, '/b.png'],
      });
      expect(task.urls, ['/a.png', '/b.png']);
      expect(task.urls, isA<List<String>>());
      // A lazy cast would only throw here, long after loading.
      expect(task.urls.map((u) => u.length).toList(), [6, 6]);
    });

    test('a voice job result with null urls is cleaned', () async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.voiceTask(c.current, {
        'type': 'localrouter.job.done',
        'job_id': 'j',
        'status': 'completed',
        'kind': 'image',
        'urls': [null, '/v1/files/x.png'],
      });
      expect(c.current.tasks.single.urls, ['/v1/files/x.png']);
      c.dispose();
    });
  });

  group('drafts are saved cheaply', () {
    test('typing re-encodes only the conversation being typed in', () async {
      final vault = MemoryVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      final many = [
        for (var i = 0; i < 30; i++)
          CountingConversation('c$i', title: '历史$i')
            ..messages.add(ChatMessage('user', '第$i条')),
      ];
      c.conversations.addAll(many);
      c.select('c3');
      await c.save();
      expect(many.every((m) => m.encoded == 1), isTrue);
      for (final m in many) {
        m.encoded = 0;
      }

      c.setDraft('正在输入');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(many[3].encoded, 1);
      expect(many.where((m) => m.encoded > 0), [many[3]]);
      final saved = jsonDecode(vault.value!) as Map<String, dynamic>;
      final list = saved['conversations'] as List;
      expect(list, hasLength(31));
      expect(list.firstWhere((j) => j['id'] == 'c3')['draft'], '正在输入');
      expect(list.firstWhere((j) => j['id'] == 'c4')['title'], '历史4');

      // Anything that is not a draft re-encodes everything again.
      c.rename('c5', '改名');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(many.every((m) => m.encoded >= 1), isTrue);
      final renamed = jsonDecode(vault.value!)['conversations'] as List;
      expect(renamed.firstWhere((j) => j['id'] == 'c5')['title'], '改名');
      c.dispose();
    });

    test(
      'a draft typed after a streamed reply still saves that reply',
      () async {
        final vault = MemoryVault();
        final api = FakeApi();
        final c = JarvisController(api, vault);
        await c.initialize();
        await c.login('a', 'b');
        c.setDraft('你好');
        final sent = c.send();
        await Future<void>.delayed(Duration.zero);
        api.streams.values.single
          ..add(const ChatDelta(text: '回复内容'))
          ..add(const ChatDelta(done: true));
        await api.streams.values.single.close();
        await sent;
        c.setDraft('下一条');
        await Future<void>.delayed(const Duration(milliseconds: 650));
        final conv = (jsonDecode(vault.value!)['conversations'] as List).first;
        expect(conv['draft'], '下一条');
        expect((conv['messages'] as List).last['text'], '回复内容');
        c.dispose();
      },
    );
  });

  group('after "start fresh" the preserved attachments are not collected', () {
    test('the orphan sweep stays off, this run and the next', () async {
      final vault = BlockedVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      expect(c.storageReadOnly, isTrue);
      await c.startFresh();
      await c.blobs.put('kept-by-evidence', Uint8List.fromList([1]));
      c.wipeConversations();
      await c.save();
      expect(await c.blobs.list(), ['kept-by-evidence']);
      c.dispose();

      // Next launch: the new state file loads, and still nothing is deleted.
      final again = JarvisController(FakeApi(), vault, blobs: c.blobs);
      await again.initialize();
      again.wipeConversations();
      await again.save();
      await Future<void>.delayed(Duration.zero);
      expect(await again.blobs.list(), ['kept-by-evidence']);
      again.dispose();
    });

    test('without a start-fresh, orphans are still collected', () async {
      final vault = MemoryVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.blobs.put('orphan', Uint8List.fromList([1]));
      c.wipeConversations();
      await c.save();
      expect(await c.blobs.list(), isEmpty);
      c.dispose();
    });
  });

  group('signing out', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('a3_logout');
      debugTempRoot = root;
    });
    tearDown(() {
      debugTempRoot = null;
      root.deleteSync(recursive: true);
    });

    Future<void> seedCache() async {
      for (final name in cachedMediaFolders) {
        await File('${root.path}/$name/x.bin').create(recursive: true);
      }
    }

    test('keeps conversations and settings, clears cached media', () async {
      final vault = MemoryVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.login('a', 'b');
      c.changeSettings((s) => s.apiKey = 'sk-test');
      c.setDraft('留着');
      await c.blobs.put('att', Uint8List.fromList([1]));
      c.current.messages.add(
        ChatMessage('user', '图', attachments: [image('att')]),
      );
      await seedCache();
      await c.logout();
      expect(c.conversations.single.messages.single.text, '图');
      expect(c.settings.apiKey, 'sk-test');
      expect(await c.blobs.list(), ['att']);
      for (final name in cachedMediaFolders) {
        expect(Directory('${root.path}/$name').listSync(), isEmpty);
      }
      c.dispose();
    });

    test('a start after a kill empties what was left in the cache', () async {
      sweepStaleMediaOnStart = true;
      addTearDown(() => sweepStaleMediaOnStart = false);
      await seedCache();
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      for (final name in cachedMediaFolders) {
        expect(Directory('${root.path}/$name').listSync(), isEmpty);
      }
      c.dispose();
    });

    test('clearLocalData erases everything on the device', () async {
      final vault = MemoryVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.login('a', 'b');
      c.changeSettings((s) => s.apiKey = 'sk-test');
      await c.blobs.put('att', Uint8List.fromList([1]));
      c.current.messages.add(
        ChatMessage('user', '图', attachments: [image('att')]),
      );
      await seedCache();
      expect(await c.clearLocalData(), isTrue);
      expect(c.authenticated, isFalse);
      expect(c.conversations.single.messages, isEmpty);
      expect(c.settings.apiKey, isEmpty);
      expect(c.api.cookie, isNull);
      expect(await c.blobs.list(), isEmpty);
      final saved = jsonDecode(vault.value!) as Map<String, dynamic>;
      expect(saved['cookie'], isNull);
      expect(saved['settings']['apiKey'], '');
      expect(jsonEncode(saved), isNot(contains('"att"')));
      for (final name in cachedMediaFolders) {
        expect(Directory('${root.path}/$name').listSync(), isEmpty);
      }
      c.dispose();
    });

    test('clearLocalData leaves an unreadable saved file alone', () async {
      final c = JarvisController(FakeApi(), BlockedVault());
      await c.initialize();
      c.authenticated = true;
      c.current.messages.add(ChatMessage('user', '留着'));
      await seedCache();
      expect(c.storageReadOnly, isTrue);
      expect(await c.clearLocalData(), isFalse);
      // Nothing was signed out or erased: the UI must not show a result that did not happen.
      expect(c.authenticated, isTrue);
      expect(c.current.messages.single.text, '留着');
      c.dispose();
    });
  });

  group('model management needs the user to agree', () {
    Future<(JarvisController, ModelToolApi)> run(
      Future<bool> Function(String)? confirm,
      String tool,
      String args,
    ) async {
      final api = ModelToolApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('a', 'b');
      c.confirmToolCall = confirm;
      c.setDraft('把大模型卸掉');
      final sent = c.send();
      await Future<void>.delayed(Duration.zero);
      final stream = api.streams.values.first;
      stream
        ..add(
          ChatDelta(
            toolDeltas: [ToolDelta(0, 'call1', tool, args)],
            finishReason: 'tool_calls',
          ),
        )
        ..add(const ChatDelta(done: true));
      await stream.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The next round reuses the request id, so it replaced the first stream; end it.
      api.streams.values.single
        ..add(const ChatDelta(text: '好', done: true))
        ..close();
      await sent;
      return (c, api);
    }

    test(
      'without a confirmation hook the changing tools are refused',
      () async {
        final (c, api) = await run(null, 'unload_model', '{"model":"big"}');
        expect(api.called, isEmpty);
        final result = c.current.messages
            .expand((m) => m.toolResults.values)
            .single;
        expect(result, contains('未执行'));
        c.dispose();
      },
    );

    test('a declined question is not executed, an accepted one is', () async {
      final asked = <String>[];
      final (c, api) = await run(
        (a) async {
          asked.add(a);
          return false;
        },
        'load_model',
        '{"model":"big"}',
      );
      expect(asked, ['加载模型 big']);
      expect(api.called, isEmpty);
      c.dispose();

      final (c2, api2) = await run(
        (a) async => true,
        'unload_model',
        '{"model":"big"}',
      );
      expect(api2.called, ['unload_model']);
      c2.dispose();
    });

    test('read-only calls and dry runs never ask', () async {
      final (c, api) = await run(
        (a) async => throw StateError('must not ask'),
        'list_models',
        '{}',
      );
      expect(api.called, ['list_models']);
      c.dispose();
      final (c2, api2) = await run(
        (a) async => throw StateError('must not ask'),
        'reserve_for',
        '{"model":"big","dry_run":true}',
      );
      expect(api2.called, ['reserve_for']);
      c2.dispose();
    });
  });

  test(
    'http media on a foreign host is refused, https and own host allowed',
    () {
      final api = JarvisApi(Uri.parse('https://jarvis.test'));
      expect(
        () => api.mediaUri('http://cdn.example/a.png'),
        throwsA(isA<JarvisException>()),
      );
      expect(api.mediaUri('https://cdn.example/a.png').host, 'cdn.example');
      expect(api.mediaUri('/v1/files/a.png').origin, 'https://jarvis.test');
      // Old absolute addresses of our own files are re-pointed at the service.
      expect(
        api.mediaUri('http://old-worker/v1/files/a.png').origin,
        'https://jarvis.test',
      );
      api.close();
    },
  );
}

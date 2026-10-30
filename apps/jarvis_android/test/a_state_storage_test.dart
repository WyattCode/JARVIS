import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/backup.dart';
import 'package:jarvis_android/state/blobs.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/vault.dart';

import 'support.dart';

class KeepingVault extends MemoryVault implements UnreadableKeeper {
  int kept = 0;
  @override
  Future<void> keepUnreadable() async {
    kept++;
  }
}

class FlakyVault extends MemoryVault {
  bool failing = true;
  @override
  Future<void> write(String value) async {
    if (failing) throw Exception('disk full');
    await super.write(value);
  }
}

class ThrowingReadVault extends MemoryVault {
  @override
  Future<String?> read() async => throw Exception('keychain locked');
}

/// Blob store whose reads/writes can be held back to interleave other work.
class GatedBlobs extends MemoryBlobs {
  Completer<void>? getGate, putGate;
  final getStarted = Completer<void>();
  @override
  Future<Uint8List> get(String id) async {
    if (!getStarted.isCompleted) getStarted.complete();
    await getGate?.future;
    return super.get(id);
  }

  @override
  Future<void> put(String id, Uint8List value) async {
    await putGate?.future;
    await super.put(id, value);
  }
}

class JobApi extends FakeApi {
  @override
  Future<Map<String, dynamic>> jobStatus(String id) async =>
      throw const JarvisException('登录已过期', unauthorized: true);
}

class StuckJobApi extends FakeApi {
  int asked = 0;
  @override
  Future<Map<String, dynamic>> jobStatus(String id) async {
    asked++;
    return {'status': 'running', 'progress': 10};
  }
}

class SlowModelsApi extends FakeApi {
  final gate = Completer<List<ModelInfo>>();
  @override
  Future<List<ModelInfo>> models() => gate.future;
}

Attachment image(String id) =>
    Attachment(id: id, name: '$id.jpg', mime: 'image/jpeg', kind: 'image');

Future<String> savedState({List<Conversation>? conversations}) async {
  final vault = MemoryVault();
  final c = JarvisController(FakeApi(), vault);
  await c.initialize();
  await c.login('user', 'test');
  if (conversations != null) {
    c.conversations
      ..clear()
      ..addAll(conversations);
    c.select(conversations.first.id);
  }
  await c.save();
  c.dispose();
  return vault.value!;
}

void main() {
  group('unreadable saved state is never overwritten', () {
    test('a file that does not parse leaves live state untouched and blocks saving', () async {
      final good = jsonDecode(await savedState()) as Map<String, dynamic>;
      good['settings'] = {'apiKey': 'key-from-file'};
      good['conversations'] = [
        {'id': 7, 'messages': 'broken'},
      ];
      final raw = jsonEncode(good);
      final vault = KeepingVault()..value = raw;
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      expect(c.storageReadOnly, isTrue);
      expect(c.storageError, contains('原文件未删除'));
      expect(
        c.settings.apiKey,
        isEmpty,
        reason: 'nothing of the bad file is half-applied',
      );
      expect(c.conversations, hasLength(1));
      c.setDraft('新的草稿');
      await c.save();
      expect(vault.value, raw);
      expect(c.initialized, isTrue);
      c.dispose();
    });

    test('a vault that cannot be read also blocks saving until the user starts fresh', () async {
      final vault = ThrowingReadVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.save();
      expect(vault.value, isNull);
      expect(c.storageReadOnly, isTrue);
      c.dispose();
    });

    test(
      'starting fresh keeps the old file aside, then saving works again',
      () async {
        final vault = KeepingVault()..value = '{"version":2}';
        final c = JarvisController(FakeApi(), vault);
        await c.initialize();
        await c.save();
        expect(vault.value, '{"version":2}');
        await c.startFresh();
        expect(vault.kept, 1);
        expect(c.storageReadOnly, isFalse);
        expect(c.storageError, isNull);
        expect(jsonDecode(vault.value!)['version'], 1);
        c.dispose();
      },
    );

    test('nothing is deleted from the attachment folder while the state is unreadable', () async {
      final blobs = MemoryBlobs();
      await blobs.put('orphan', Uint8List.fromList([1]));
      final c = JarvisController(
        FakeApi(),
        MemoryVault()..value = 'not json',
        blobs: blobs,
      );
      await c.initialize();
      await pumpEventQueue();
      expect(await blobs.list(), ['orphan']);
      c.dispose();
    });
  });

  test(
    'storageError from a failed save clears once a later save succeeds',
    () async {
      final vault = FlakyVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.save();
      expect(c.storageError, contains('保存失败'));
      expect(c.persistFailed, isTrue);
      vault.failing = false;
      await c.save();
      expect(c.storageError, isNull);
      expect(c.persistFailed, isFalse);
      c.dispose();
    },
  );

  test('importing reports a failed save instead of claiming success', () async {
    final vault = FlakyVault()..failing = false;
    final c = JarvisController(FakeApi(), vault);
    await c.initialize();
    vault.failing = true;
    final backup = utf8.encode(
      jsonEncode({
        'version': 3,
        'files': [],
        'conversations': [
          Conversation('x', messages: [ChatMessage('user', '你好')]).toJson(),
        ],
      }),
    );
    await expectLater(
      c.importBackup(Uint8List.fromList(backup)),
      throwsA(isA<JarvisException>()),
    );
    c.dispose();
  });

  test(
    'initialize opens the UI before the connection attempt finishes',
    () async {
      final signedIn = await savedState();
      final api = SlowModelsApi();
      final c = JarvisController(api, MemoryVault()..value = signedIn);
      final done = c.initialize();
      await pumpEventQueue();
      expect(c.initialized, isTrue);
      expect(c.connecting, isTrue);
      api.gate.complete([ModelInfo('m', 'M')]);
      await done;
      expect(c.authenticated, isTrue);
      c.dispose();
    },
  );

  group('regenerate', () {
    Future<JarvisController> build({bool signedIn = true}) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      if (signedIn) await c.login('user', 'test');
      c.current.messages
        ..add(ChatMessage('user', '问题'))
        ..add(ChatMessage('assistant', '回答'));
      return c;
    }

    test('does not replace a draft or pending attachments', () async {
      final c = await build();
      c.current.draft = '写到一半';
      await c.regenerate();
      expect(c.current.draft, '写到一半');
      expect(c.current.messages.any((m) => m.hidden), isFalse);
      expect(c.error, contains('未发送'));
      c.current.draft = '';
      c.current.pendingAttachments.add(image('p'));
      await c.regenerate();
      expect(c.current.pendingAttachments.single.id, 'p');
      expect(c.current.messages.any((m) => m.hidden), isFalse);
      c.dispose();
    });

    test('hides nothing when sending cannot start', () async {
      final c = await build(signedIn: false);
      expect(c.authenticated, isFalse);
      await c.regenerate();
      expect(c.current.messages.any((m) => m.hidden), isFalse);
      expect(c.current.draft, isEmpty);
      c.dispose();
    });
  });

  group('newConversation', () {
    test('selects the empty conversation instead of adding another', () async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final first = c.current;
      expect(c.newConversation(), same(first));
      expect(c.conversations, hasLength(1));
      first.draft = '  ';
      expect(c.newConversation(), same(first));
      first.draft = '草稿';
      final second = c.newConversation();
      expect(second, isNot(same(first)));
      expect(c.conversations, hasLength(2));
      expect(c.current, same(second));
      c.dispose();
    });

    test('a conversation with messages or attachments is not reused', () async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.current.pendingAttachments.add(image('a'));
      c.newConversation();
      expect(c.conversations, hasLength(2));
      c.current.messages.add(ChatMessage('user', '你好'));
      c.newConversation();
      expect(c.conversations, hasLength(3));
      c.dispose();
    });
  });

  group('attachments that are gone', () {
    test(
      'a missing blob becomes a placeholder, not a broken conversation',
      () async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await c.blobs.put('here', Uint8List.fromList([1, 2]));
        c.current.messages.add(
          ChatMessage(
            'user',
            '看图',
            attachments: [image('here'), image('lost')],
          ),
        );
        final payload = await c.messagePayload(c.current);
        final parts = payload.last['content'] as List;
        expect(parts.where((p) => p['type'] == 'image_url'), hasLength(1));
        expect(parts.any((p) => '${p['text']}'.contains('不可用')), isTrue);
        c.dispose();
      },
    );

    test('sending still works and reports no connection loss', () async {
      final api = FakeApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('user', 'test');
      c.current.messages.add(
        ChatMessage('user', '旧图', attachments: [image('lost')]),
      );
      c.setDraft('继续');
      final sent = c.send();
      await pumpEventQueue();
      api.streams.values.single
        ..add(const ChatDelta(text: '好', done: true))
        ..close();
      await sent;
      expect(c.current.messages.last.error, isNull);
      expect(c.current.messages.last.text, '好');
      c.dispose();
    });
  });

  group('backup export', () {
    test(
      'survives conversations changing while attachments are read',
      () async {
        final blobs = GatedBlobs();
        final c = JarvisController(FakeApi(), MemoryVault(), blobs: blobs);
        await c.initialize();
        await blobs.put('a', Uint8List.fromList([1]));
        await blobs.put('b', Uint8List.fromList([2]));
        c.current.messages.add(
          ChatMessage('user', '一', attachments: [image('a'), image('b')]),
        );
        blobs.getGate = Completer<void>();
        final export = c.exportBackup();
        await blobs.getStarted.future;
        c.conversations.insert(0, Conversation('late'));
        c.conversations.removeLast();
        blobs.getGate!.complete();
        final root = jsonDecode(utf8.decode(await export));
        expect(root['conversations'], hasLength(1));
        expect(root['files'], hasLength(2));
        c.dispose();
      },
    );

    test(
      'a missing file is skipped and reported; the backup still imports',
      () async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await c.blobs.put('ok', Uint8List.fromList([9]));
        c.current.messages.add(
          ChatMessage('user', '图', attachments: [image('ok'), image('gone')]),
        );
        final bytes = await c.exportBackup();
        expect(c.backupSkipped, ['gone']);
        final root = jsonDecode(utf8.decode(bytes));
        expect(root['files'], hasLength(1));
        expect(root['missing_files'], ['gone']);
        final second = JarvisController(FakeApi(), MemoryVault());
        await second.initialize();
        expect(await second.importBackup(bytes), 1);
        c.dispose();
        second.dispose();
      },
    );
  });

  group('attachment files are collected', () {
    JarvisController build(BlobStore blobs) {
      final c = JarvisController(FakeApi(), MemoryVault(), blobs: blobs);
      return c;
    }

    test(
      'removing a pending attachment deletes its file after the next save',
      () async {
        final blobs = MemoryBlobs();
        final c = build(blobs);
        await c.initialize();
        await c.addAttachment(c.current, image('a'), Uint8List.fromList([1]));
        expect(await blobs.list(), ['a']);
        c.removeAttachment('a');
        await c.save();
        expect(await blobs.list(), isEmpty);
        c.dispose();
      },
    );

    test(
      'a deleted conversation keeps its files until the undo window has passed',
      () async {
        final blobs = MemoryBlobs();
        final c = build(blobs);
        await c.initialize();
        await blobs.put('a', Uint8List.fromList([1]));
        final owner = c.current;
        owner.messages.add(ChatMessage('user', '图', attachments: [image('a')]));
        c.newConversation();
        final removed = c.deleteConversation(owner.id)!;
        await c.save();
        expect(await blobs.list(), ['a']);
        c.restoreConversation(removed);
        await c.save();
        expect(await blobs.list(), ['a']);
        c.undoWindow = Duration.zero;
        c.deleteConversation(owner.id);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await c.save();
        expect(await blobs.list(), isEmpty);
        c.dispose();
      },
    );

    test(
      'wiping all conversations deletes their files but not those in flight',
      () async {
        final blobs = MemoryBlobs();
        final c = build(blobs);
        await c.initialize();
        await blobs.put('a', Uint8List.fromList([1]));
        await blobs.put('importing', Uint8List.fromList([2]));
        c.current.messages.add(
          ChatMessage('user', '图', attachments: [image('a')]),
        );
        c.holdBlobs(['importing']);
        expect(c.wipeConversations(), isTrue);
        await c.save();
        expect(await blobs.list(), ['importing']);
        c.releaseBlobs(['importing']);
        c.dispose();
      },
    );

    test('an attachment whose conversation disappears mid-write leaves no file behind', () async {
      final blobs = GatedBlobs()..putGate = Completer<void>();
      final c = build(blobs);
      await c.initialize();
      final owner = c.current;
      final adding = c.addAttachment(
        owner,
        image('a'),
        Uint8List.fromList([1]),
      );
      await pumpEventQueue();
      c.conversations.remove(owner);
      c.newConversation();
      blobs.putGate!.complete();
      await adding;
      expect(await blobs.list(), isEmpty);
      c.dispose();
    });

    test('files nothing refers to are cleared when the app starts', () async {
      final blobs = MemoryBlobs();
      await blobs.put('kept', Uint8List.fromList([1]));
      await blobs.put('orphan', Uint8List.fromList([2]));
      final owner = Conversation(
        'c',
        messages: [
          ChatMessage('user', '图', attachments: [image('kept')]),
        ],
      );
      final vault = MemoryVault()
        ..value = await savedState(conversations: [owner]);
      final restored = JarvisController(FakeApi(), vault, blobs: blobs);
      await restored.initialize();
      await pumpEventQueue();
      expect(await blobs.list(), ['kept']);
      restored.dispose();
    });
  });

  testWidgets('an expired session found while polling a voice job signs out', (
    t,
  ) async {
    final c = JarvisController(JobApi(), MemoryVault());
    await c.initialize();
    await c.login('user', 'test');
    final owner = c.current;
    c.voiceTask(owner, {
      'type': 'call',
      'call_id': 'call_1',
      'name': 'generate_image',
      'arguments': '{"prompt":"猫"}',
    });
    c.voiceTask(owner, {'type': 'localrouter.job.created', 'job_id': 'job_1'});
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(c.authenticated, isFalse);
    expect(c.connectionError, contains('过期'));
    expect(owner.tasks.single.status, 'interrupted');
    c.dispose();
  });

  test('a voice job the server never finishes is given up on', () async {
    final api = StuckJobApi();
    final c = JarvisController(api, MemoryVault());
    await c.initialize();
    await c.login('user', 'test');
    c.voicePollInterval = const Duration(milliseconds: 10);
    c.voicePollDeadline = const Duration(milliseconds: 120);
    final owner = c.current;
    c.voiceTask(owner, {
      'type': 'call',
      'call_id': 'call_1',
      'name': 'generate_image',
      'arguments': '{"prompt":"猫"}',
    });
    c.voiceTask(owner, {'type': 'localrouter.job.created', 'job_id': 'job_1'});
    final task = owner.tasks.single;
    expect(task.pending, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(api.asked, greaterThan(0));
    expect(task.status, 'interrupted');
    expect(task.error, contains('等待时间过长'));
    // Nothing keeps the conversation from being deleted any more.
    expect(task.pending, isFalse);
    final asked = api.asked;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.asked, asked, reason: 'polling stopped');
    c.dispose();
  });
}

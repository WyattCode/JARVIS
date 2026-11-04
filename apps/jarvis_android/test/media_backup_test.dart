import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/backup.dart';

import 'support.dart';

class MediaApi extends FakeApi {
  final media = Completer<List<String>>();
  int generations = 0;
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('chat', 'Chat'),
    ModelInfo(
      'video',
      'Video',
      kind: 'video',
      metadata: {
        'limits': {'max_seconds': 5},
      },
    ),
  ];
  @override
  Future<List<String>> generate(
    String requestId,
    String kind,
    Map<String, dynamic> args, {
    String? resumeJobId,
    void Function(String)? onJob,
    void Function(double)? onProgress,
  }) {
    generations++;
    onJob?.call('video_1');
    return media.future;
  }
}

void main() {
  test('Tool streaming hands off to a media task without locking chat or injecting a receipt', () async {
    final api = MediaApi();
    final state = JarvisController(api, MemoryVault());
    await state.initialize();
    await state.login('Wyatt', 'test');
    state.setDraft('生成视频');
    final job = state.send();
    await Future<void>.delayed(Duration.zero);
    final stream = api.streams.values.single;
    stream.add(
      const ChatDelta(
        toolDeltas: [
          ToolDelta(0, 'call1', 'generate_video', '{"prompt":"兔子",'),
        ],
      ),
    );
    stream.add(
      const ChatDelta(
        toolDeltas: [ToolDelta(0, '', '', '"seconds":3}')],
        finishReason: 'tool_calls',
      ),
    );
    stream.add(const ChatDelta(done: true));
    await stream.close();
    await job;
    final owner = state.current;
    expect(owner.tasks.single.pending, true);
    expect(state.isGenerating(owner.id), false);
    expect(api.generations, 1);
    state.setDraft('再聊别的话题');
    final next = state.send();
    await Future<void>.delayed(Duration.zero);
    final second = api.streams.values.last;
    second.add(const ChatDelta(text: '继续聊天', done: true));
    await second.close();
    await next;
    final count = owner.messages.length;
    state.newConversation();
    api.media.complete(['/v1/videos/video_1/content']);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(owner.tasks.single.status, 'completed');
    expect(owner.messages.length, count);
    expect(state.current.messages, isEmpty);
    expect(owner.messages.where((m) => m.text.contains('job_id')), isEmpty);
    state.dispose();
  });
  test('An incomplete tool call is never executed', () async {
    final api = MediaApi(), c = JarvisController(api, MemoryVault());
    await c.initialize();
    await c.login('Wyatt', 'test');
    c.setDraft('做视频');
    final job = c.send();
    await Future<void>.delayed(Duration.zero);
    final stream = api.streams.values.single;
    stream.add(
      const ChatDelta(
        toolDeltas: [ToolDelta(0, 'bad', 'generate_video', '{"prompt":')],
      ),
    );
    await stream.close();
    await job;
    expect(api.generations, 0);
    expect(c.current.tasks, isEmpty);
    c.dispose();
  });
  test('Web v2 PDF text and attachment bytes survive import and native export without secrets', () async {
    final state = JarvisController(FakeApi(), MemoryVault());
    await state.initialize();
    await state.login('Wyatt', 'test');
    state.settings.apiKey = 'private-api-key-must-not-export';
    final backup = {
      'version': 2,
      'files': [
        {
          'id': 'file1',
          'data': 'data:application/pdf;base64,${base64Encode([1, 2, 3])}',
          'text': 'PDF正文',
        },
      ],
      'conversations': [
        {
          'id': 'web',
          'title': '旧会话',
          'msgs': [
            {
              'role': 'user',
              'text': '分析附件',
              'attachments': [
                {'id': 'file1', 'name': 'a.pdf', 'kind': 'document'},
              ],
            },
            {'role': 'assistant', 'text': '旧回复'},
          ],
        },
      ],
    };
    expect(
      await state.importBackup(
        Uint8List.fromList(utf8.encode(jsonEncode(backup))),
      ),
      1,
    );
    expect(state.current.messages.first.attachments.single.text, 'PDF正文');
    expect(
      (await state.messagePayload(state.current)).toString(),
      contains('PDF正文'),
    );
    final saved = await state.exportBackup(), raw = utf8.decode(saved);
    expect(raw, isNot(contains('private-api-key-must-not-export')));
    expect(raw, isNot(contains('__Host-jarvis_session')));
    final second = JarvisController(FakeApi(), MemoryVault());
    await second.initialize();
    await second.importBackup(saved);
    expect(second.current.title, '旧会话');
    expect(
      await second.blobs.get(
        second.current.messages.first.attachments.single.id,
      ),
      [1, 2, 3],
    );
    state.dispose();
    second.dispose();
  });
  test('Malformed backup cannot replace existing conversations', () async {
    final state = JarvisController(FakeApi(), MemoryVault());
    await state.initialize();
    final old = state.current.id;
    final backup = {
      'version': 2,
      'files': [],
      'conversations': [
        {
          'id': 'broken',
          'msgs': [
            {
              'role': 'user',
              'attachments': [
                {'id': 'missing', 'name': 'x', 'kind': 'image'},
              ],
            },
          ],
        },
      ],
    };
    await expectLater(
      state.importBackup(Uint8List.fromList(utf8.encode(jsonEncode(backup)))),
      throwsA(anything),
    );
    expect(state.conversations.length, 1);
    expect(state.current.id, old);
    state.dispose();
  });
  test('Picture input uses owned bytes and files stay with their original conversation', () async {
    final state = JarvisController(FakeApi(), MemoryVault());
    await state.initialize();
    final owner = state.current;
    state.newConversation();
    final attachment = Attachment(
      id: 'image1',
      name: 'a.jpg',
      mime: 'image/jpeg',
      kind: 'image',
    );
    await state.addAttachment(owner, attachment, Uint8List.fromList([1, 2, 3]));
    expect(state.current.pendingAttachments, isEmpty);
    expect(owner.pendingAttachments.single.id, 'image1');
    owner.messages.add(
      ChatMessage('user', '看图', attachments: owner.pendingAttachments),
    );
    final payload = await state.messagePayload(owner);
    expect(
      payload.last['content'].toString(),
      contains('data:image/jpeg;base64,AQID'),
    );
    state.dispose();
  });
}

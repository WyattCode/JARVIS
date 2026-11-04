import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../model/conversation.dart';
import '../model/media.dart';
import '../net/jarvis_api.dart';
import 'jarvis_controller.dart';

extension JarvisBackup on JarvisController {
  Future<Uint8List> exportBackup() async {
    final files = <Map<String, dynamic>>[], ids = <String>{};
    for (final c in conversations) {
      for (final a in [
        ...c.pendingAttachments,
        ...c.messages.expand((m) => m.attachments),
      ]) {
        if (!ids.add(a.id)) continue;
        final bytes = await blobs.get(a.id);
        files.add({
          'id': a.id,
          'data': 'data:${a.mime};base64,${base64Encode(bytes)}',
        });
      }
    }
    // Deliberately exclude account cookies, API keys and other authentication material.
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 3,
          'app': 'jarvis-android',
          'exported_at': DateTime.now().toUtc().toIso8601String(),
          'conversations': conversations.map((c) => c.toJson()).toList(),
          'files': files,
        }),
      ),
    );
  }

  Future<int> chooseImport() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '贾维斯会话备份',
          extensions: ['json'],
          mimeTypes: ['application/json'],
        ),
      ],
    );
    if (file == null) return 0;
    if (await file.length() > 128 * 1024 * 1024) {
      throw const JarvisException('备份超过128MB，请分批导入');
    }
    return importBackup(await file.readAsBytes());
  }

  Future<int> importBackup(Uint8List input) async {
    if (input.length > 128 * 1024 * 1024) throw const JarvisException('备份过大');
    final root = jsonDecode(utf8.decode(input)) as Map<String, dynamic>;
    if (![2, 3].contains(root['version'])) {
      throw const JarvisException('不是支持的贾维斯备份');
    }
    final raw = root['conversations'];
    if (raw is! List || raw.length > 10000) {
      throw const JarvisException('备份会话格式无效');
    }
    final prefix = 'import_${DateTime.now().microsecondsSinceEpoch}_';
    final textById = <String, String>{};
    final remap = <String, String>{},
        mimeById = <String, String>{},
        data = <String, Uint8List>{};
    String id(String old) =>
        remap.putIfAbsent(old, () => '$prefix${remap.length}');
    for (final f in root['files'] as List? ?? []) {
      if (f is! Map || f['id'] is! String || f['data'] is! String) {
        throw const JarvisException('附件备份格式无效');
      }
      final url = f['data'] as String, comma = url.indexOf(',');
      if (comma < 0 ||
          !url.startsWith('data:') ||
          !url.substring(0, comma).endsWith(';base64')) {
        throw const JarvisException('附件编码无效');
      }
      final bytes = base64Decode(url.substring(comma + 1));
      if (bytes.length > 20 * 1024 * 1024) {
        throw const JarvisException('备份中的单个附件过大');
      }
      final key = id(f['id'] as String);
      data[key] = bytes;
      if (f['text'] is String) textById[key] = f['text'] as String;
      mimeById[key] = url.substring(5, comma - 7);
    }
    Attachment attachment(Map a) {
      final key = id(a['id'] as String);
      if (!data.containsKey(key)) throw const JarvisException('备份缺少附件数据');
      return Attachment(
        id: key,
        name: a['name'] as String? ?? '附件',
        mime: mimeById[key] ?? 'application/octet-stream',
        kind: a['kind'] as String? ?? 'document',
        text: a['text'] as String? ?? textById[key],
        size: data[key]!.length,
      );
    }

    final imported = <Conversation>[];
    for (final value in raw) {
      final j = Map<String, dynamic>.from(value as Map);
      final native = j.containsKey('messages');
      if (native) {
        // Rewrite only owned blob/conversation identities, preserving message references and task records.
        final copy = jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
        copy['id'] = id('conversation_${j['id']}');
        for (final a in copy['attachments'] as List? ?? []) {
          a['id'] = id(a['id'] as String);
          if (!data.containsKey(a['id'])) throw const JarvisException('备份缺少附件');
        }
        for (final m in copy['messages'] as List) {
          for (final a in m['attachments'] as List? ?? []) {
            a['id'] = id(a['id'] as String);
            if (!data.containsKey(a['id'])) {
              throw const JarvisException('备份缺少附件');
            }
          }
        }
        final c = Conversation.fromJson(copy);
        for (final t in c.tasks.where((t) => t.pending)) {
          t.status = 'interrupted';
          t.error = '导入的任务不会自动重发，请检查原任务';
        }
        imported.add(c);
      } else {
        final c = Conversation(
          id('conversation_${j['id']}'),
          title: j['title'] as String? ?? '导入的会话',
          draft: j['draft'] as String? ?? '',
          named: j['named'] as bool? ?? false,
        );
        for (final a in j['pendingAttachments'] as List? ?? []) {
          if (a['loading'] == true) continue;
          c.pendingAttachments.add(attachment(a as Map));
        }
        for (final value in j['msgs'] as List? ?? []) {
          final m = Map<String, dynamic>.from(value as Map);
          if (m['gone'] == true || m['partial'] == true) continue;
          if (m['role'] == 'tool') {
            final kind = m['kind'] == 'video' ? 'video' : 'image';
            final media = m['media'] as List? ?? [];
            final args = Map<String, dynamic>.from(m['args'] as Map? ?? {});
            final task = MediaTask(
              id: id('task_${m['id']}'),
              kind: kind,
              prompt: (args['prompt'] ?? m['text'] ?? '') as String,
              args: args,
              callId: m['callId'] as String?,
              jobId: m['jobId'] as String?,
              status: media.isNotEmpty ? 'completed' : 'interrupted',
              urls: media.map((x) => x['url'] as String).where((url) {
                try {
                  api.mediaUri(url);
                  return true;
                } catch (_) {
                  return false;
                }
              }).toList(),
              error: media.isEmpty ? '导入的任务不会自动重发，请检查原任务' : null,
            );
            c.tasks.add(task);
            c.messages.add(ChatMessage('tool', task.prompt, taskId: task.id));
            continue;
          }
          final role = ['user', 'assistant'].contains(m['role'])
              ? m['role'] as String
              : 'system';
          c.messages.add(
            ChatMessage(
              role,
              m['text'] as String? ?? '',
              reasoning: m['reasoning'] as String? ?? '',
              status: m['streaming'] == true || m['interrupted'] == true
                  ? 'interrupted'
                  : 'complete',
              attachments: (m['attachments'] as List? ?? [])
                  .map((a) => attachment(a as Map))
                  .toList(),
              calls: (m['calls'] as List? ?? [])
                  .map(
                    (call) => ToolCall.fromJson(
                      Map<String, dynamic>.from(call as Map),
                    ),
                  )
                  .toList(),
            ),
          );
        }
        imported.add(c);
      }
    }
    // Validate the complete document before changing visible conversation state.
    for (final entry in data.entries) {
      await blobs.put(entry.key, entry.value);
    }
    installImported(imported);
    await save();
    return imported.length;
  }

  String diagnostics() => const JsonEncoder.withIndent('  ').convert({
    'app': 'Jarvis Android',
    'time': DateTime.now().toUtc().toIso8601String(),
    'server': api.endpoint.origin,
    'model': model,
    'reasoning_effort': effort,
    'authenticated': authenticated,
    'api_key_present': settings.apiKey.isNotEmpty,
    'conversations': conversations.length,
    'active_text_requests': conversations
        .where((c) => isGenerating(c.id))
        .length,
    'media_tasks': conversations
        .expand((c) => c.tasks)
        .map(
          (t) => {'kind': t.kind, 'status': t.status, 'progress': t.progress},
        )
        .toList(),
    'voice': {
      'active': voice.active,
      'ready': voice.ready,
      'status': voice.status,
      'speech_model': settings.speechModel,
      'selected_voice': settings.voices[settings.speechModel],
      'language': settings.language,
      'mode': settings.voiceMode,
      'captured_pcm_bytes': voice.capturedPcmBytes,
      'sent_pcm_bytes': voice.sentPcmBytes,
      'received_pcm_bytes': voice.receivedPcmBytes,
      'buffered_frames': voice.bufferedFrames,
      'playback_rate': voice.playbackRate,
    },
    'error': error,
    'storage_error': storageError,
  });
}

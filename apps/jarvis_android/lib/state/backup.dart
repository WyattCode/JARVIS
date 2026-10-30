import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../model/conversation.dart';
import '../model/media.dart';
import '../net/jarvis_api.dart';
import 'attachments.dart';
import 'jarvis_controller.dart';
import 'local_data.dart';

String backupPlatformName() =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';

/// The `app` field of a backup. Old backups say `jarvis-android` even on iOS; import never looks at it.
String backupAppName() => 'jarvis-${backupPlatformName().toLowerCase()}';

/// The sizes export and import agree on. A backup file never exceeds [importBytes], so every file export produces is one
/// import accepts. Export aims for [partBytes], well below it: import holds the text, the parsed document and the decoded
/// files at once, a few times the file size.
class BackupLimits {
  static int importBytes = 128 * 1024 * 1024;
  static int partBytes = 64 * 1024 * 1024;
  static const attachmentBytes = 20 * 1024 * 1024;
}

/// What [JarvisBackup.exportBackupFiles] wrote: [files] are numbered parts (one when everything fits), each a complete
/// backup of whole conversations that imports on its own. Delete [folder] when done.
class BackupExport {
  BackupExport(this.folder, this.files);
  final Directory folder;
  final List<File> files;
  Future<void> dispose() async {
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (_) {
      return;
    }
  }
}

class _BackupTooLarge extends JarvisException {
  const _BackupTooLarge() : super('备份文件超过导入上限，请删除部分带附件的会话后再导出');
}

/// Counts what goes into a part's file and keeps the writer from queueing the whole file in memory.
class _PartWriter {
  _PartWriter(this.sink, this.limit);
  final IOSink sink;
  final int limit;
  int written = 0, _unflushed = 0;
  Future<void> add(String text) async {
    final bytes = utf8.encode(text);
    written += bytes.length;
    if (written > limit) throw const _BackupTooLarge();
    sink.add(bytes);
    _unflushed += bytes.length;
    if (_unflushed > 1024 * 1024) {
      _unflushed = 0;
      await sink.flush();
    }
  }
}

extension JarvisBackup on JarvisController {
  /// Writes the backup to files, streaming: only one attachment is in memory at a time. Conversations are grouped into
  /// parts of about [BackupLimits.partBytes]; a conversation is never split, so each part imports by itself. A single
  /// conversation too big for any file to import makes this throw, naming it, so nothing unimportable is produced.
  Future<BackupExport> exportBackupFiles() async {
    // Frozen now: reading blobs awaits, and the conversations may change meanwhile.
    final snapshot = conversations.map((c) => c.toJson()).toList();
    final encoded = [for (final c in snapshot) jsonEncode(c)];
    final perConversation = <List<String>>[];
    final sizes = <String, int>{}, mimes = <String, String>{};
    for (final c in snapshot) {
      final ids = <String>[];
      for (final a in [
        ...(c['attachments'] as List),
        ...(c['messages'] as List).expand(
          (m) => (m as Map)['attachments'] as List,
        ),
      ]) {
        final id = a['id'] as String;
        if (!mimes.containsKey(id)) {
          mimes[id] = a['mime'] as String;
          sizes[id] = (a['size'] as num?)?.toInt() ?? 0;
        }
        if (!ids.contains(id)) ids.add(id);
      }
      perConversation.add(ids);
    }
    // A recorded size of 0 is an old record: measure it rather than trust it.
    for (final id in sizes.keys.where((id) => sizes[id] == 0)) {
      try {
        sizes[id] = (await blobs.get(id)).length;
      } catch (_) {
        sizes[id] = 0;
      }
    }
    int cost(int i, Iterable<String> ids) =>
        utf8.encode(encoded[i]).length +
        ids.fold(
          0,
          (n, id) => n + (sizes[id]! + 2) ~/ 3 * 4 + 200 + mimes[id]!.length,
        );

    final groups = <List<int>>[];
    var used = 0;
    for (var i = 0; i < snapshot.length; i++) {
      final own = cost(i, perConversation[i]);
      if (groups.isEmpty || used + own > BackupLimits.partBytes) {
        groups.add([]);
        used = 0;
      }
      groups.last.add(i);
      used += own;
    }
    if (groups.isEmpty) groups.add([]);

    backupSkipped = [];
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final folder = await tempFolder('jarvis-backup')
        .create(recursive: true)
        .then((d) => Directory('${d.path}/$stamp').create());
    final files = <File>[];
    try {
      for (var part = 0; part < groups.length; part++) {
        final name = groups.length == 1
            ? 'jarvis-conversations-$stamp.json'
            : 'jarvis-conversations-$stamp-${part + 1}of${groups.length}.json';
        final file = File('${folder.path}/$name');
        try {
          await _writePart(
            file,
            [for (final i in groups[part]) encoded[i]],
            {for (final i in groups[part]) ...perConversation[i]}.toList(),
            mimes,
            part: part + 1,
            parts: groups.length,
          );
        } on _BackupTooLarge {
          // A part is whole conversations: one that alone is over the limit cannot be split, so say which it is.
          if (groups[part].length != 1) rethrow;
          final title = snapshot[groups[part].single]['title'] ?? '未命名';
          throw JarvisException(
            '会话「$title」的附件太大，无法放进一个备份文件；请先删除其中一部分图片或文件，或删除这个会话后再导出',
          );
        }
        files.add(file);
      }
    } catch (_) {
      await BackupExport(folder, files).dispose();
      rethrow;
    }
    return BackupExport(folder, files);
  }

  Future<void> _writePart(
    File file,
    List<String> conversationsJson,
    List<String> ids,
    Map<String, String> mimes, {
    required int part,
    required int parts,
  }) async {
    final sink = file.openWrite();
    final out = _PartWriter(sink, BackupLimits.importBytes);
    final skipped = <String>[];
    try {
      // Deliberately exclude account cookies, API keys and other authentication material.
      await out.add(
        '{"version":3,"app":${jsonEncode(backupAppName())},'
        '"exported_at":${jsonEncode(DateTime.now().toUtc().toIso8601String())},'
        '"part":$part,"parts":$parts,'
        '"conversations":[${conversationsJson.join(',')}],"files":[',
      );
      var first = true;
      for (final id in ids) {
        final Uint8List bytes;
        try {
          bytes = await blobs.get(id);
        } catch (_) {
          // One lost file must not make the whole backup impossible; the caller can tell the user.
          skipped.add(id);
          continue;
        }
        await out.add(
          '${first ? '' : ','}{"id":${jsonEncode(id)},"data":"data:${mimes[id]};base64,',
        );
        first = false;
        // Multiples of 3 bytes encode to base64 without padding, so the chunks join into one valid string.
        const chunk = 48 * 1024;
        for (var i = 0; i < bytes.length; i += chunk) {
          final end = i + chunk < bytes.length ? i + chunk : bytes.length;
          await out.add(base64Encode(Uint8List.sublistView(bytes, i, end)));
        }
        await out.add('"}');
      }
      await out.add(
        ']${skipped.isEmpty ? '' : ',"missing_files":${jsonEncode(skipped)}'}}',
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
    backupSkipped.addAll(skipped);
  }

  /// Exports and hands the file(s) to the system's save dialog; temp files are removed either way. Returns how many
  /// files were offered, 0 when the user cancelled.
  Future<int> exportAndSaveBackup() async {
    final export = await exportBackupFiles();
    try {
      final saved = await NativeFiles.saveFiles([
        for (final f in export.files)
          (path: f.path, name: f.uri.pathSegments.last),
      ], 'application/json');
      return saved ? export.files.length : 0;
    } finally {
      await export.dispose();
    }
  }

  /// The whole backup as one block of bytes, for callers that cannot take several files. Throws when it would not fit
  /// in one file.
  Future<Uint8List> exportBackup() async {
    final export = await exportBackupFiles();
    try {
      if (export.files.length > 1) {
        throw const JarvisException('备份内容较多，需要分成多个文件导出');
      }
      return await export.files.single.readAsBytes();
    } finally {
      await export.dispose();
    }
  }

  /// Sessions imported, or null when the person closed the picker without choosing.
  Future<int?> chooseImport() async {
    final picked = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '贾维斯会话备份',
          extensions: ['json'],
          mimeTypes: ['application/json'],
        ),
      ],
    );
    if (picked.isEmpty) return null;
    var total = 0;
    for (final file in picked) {
      try {
        if (await file.length() > BackupLimits.importBytes) {
          throw JarvisException(
            '备份文件超过${BackupLimits.importBytes ~/ (1024 * 1024)}MB，无法导入',
          );
        }
        total += await importBackup(await file.readAsBytes());
      } catch (e) {
        if (total == 0) rethrow;
        // Earlier parts are already in; say so instead of pretending nothing happened.
        throw JarvisException(
          '已导入 $total 个会话，但“${file.name}”未能导入：${e is JarvisException ? e.message : '文件无效'}',
        );
      }
    }
    return total;
  }

  Future<int> importBackup(Uint8List input) async {
    if (input.length > BackupLimits.importBytes) {
      throw const JarvisException('备份过大');
    }
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
      if (bytes.length > BackupLimits.attachmentBytes) {
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

    // Files the exporting device could not read were left out on purpose; their messages keep a placeholder.
    final missing = {
      ...(root['missing_files'] as List? ?? []).whereType<String>(),
    };
    final imported = <Conversation>[];
    for (final value in raw) {
      final j = Map<String, dynamic>.from(value as Map);
      final native = j.containsKey('messages');
      if (native) {
        // Rewrite only owned blob/conversation identities, preserving message references and task records.
        final copy = jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
        copy['id'] = id('conversation_${j['id']}');
        for (final a in copy['attachments'] as List? ?? []) {
          final old = a['id'] as String;
          a['id'] = id(old);
          if (!data.containsKey(a['id']) && !missing.contains(old)) {
            throw const JarvisException('备份缺少附件');
          }
        }
        for (final m in copy['messages'] as List) {
          for (final a in m['attachments'] as List? ?? []) {
            final old = a['id'] as String;
            a['id'] = id(old);
            if (!data.containsKey(a['id']) && !missing.contains(old)) {
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
              urls: media
                  .map((x) => x is Map ? x['url'] : null)
                  .whereType<String>()
                  .where((url) {
                    try {
                      api.mediaUri(url);
                      return true;
                    } catch (_) {
                      return false;
                    }
                  })
                  .toList(),
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
    holdBlobs(data.keys);
    try {
      for (final entry in data.entries) {
        await blobs.put(entry.key, entry.value);
      }
      installImported(imported);
    } finally {
      releaseBlobs(data.keys);
    }
    await save();
    if (persistFailed) {
      throw const JarvisException('会话已导入，但未能保存到本机；退出应用前请先导出备份');
    }
    return imported.length;
  }

  String diagnostics() => const JsonEncoder.withIndent('  ').convert({
    'app': 'Jarvis ${backupPlatformName()}',
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

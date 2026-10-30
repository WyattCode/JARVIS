import 'dart:async';
import 'dart:convert';

import '../model/media.dart';
import '../model/settings.dart';
import '../model/starters.dart';
import '../model/text_clip.dart';
import '../net/tool_schema.dart';
import '../net/model_tools.dart';
import 'blobs.dart';
import '../voice/voice_session.dart';
import '../voice/audio_device.dart';

import 'package:flutter/foundation.dart';

import '../model/conversation.dart';
import '../net/jarvis_api.dart';
import 'local_data.dart';
import 'vault.dart';

class JarvisController extends ChangeNotifier {
  JarvisController(this.api, this.vault, {BlobStore? blobs, this.audioDevice})
    : blobs = blobs ?? MemoryBlobs();
  final AudioDevice? audioDevice;
  VoiceSession? _voice;
  Timer? _voiceSettingsTimer;
  VoiceSession get voice => _voice ??= VoiceSession(
    api: api,
    audio: audioDevice ?? NativeAudioDevice(),
    settings: () => settings,
    catalog: () => models,
    effort: () => effort,
    model: () => model,
    changed: () {
      scheduleSave();
      _changed();
    },
    onTask: voiceTask,
    onUnauthorized: expireSession,
  );
  final BlobStore blobs;
  final settings = ChatSettings();
  final _starters = SessionStarters();
  List<Starter> get starters => _starters.available(
    (kind) => settings.tools && models.any((m) => m.kind == kind),
  );
  final _mediaActive = <String, String>{};
  final _attachmentLoads = <String, int>{};
  bool attachmentsLoading(String id) => (_attachmentLoads[id] ?? 0) > 0;
  void beginAttachment(Conversation c) {
    _attachmentLoads.update(c.id, (n) => n + 1, ifAbsent: () => 1);
    _changed();
  }

  void endAttachment(Conversation c) {
    _attachmentLoads.update(
      c.id,
      (n) => (n - 1).clamp(0, 100),
      ifAbsent: () => 0,
    );
    _changed();
  }

  final JarvisTransport api;
  final Vault vault;
  final conversations = <Conversation>[];
  final _active = <String, ({String requestId, ChatMessage message})>{};
  List<ModelInfo> models = [];
  Map<String, dynamic> modelSkill = {'enabled': false, 'text': ''};
  String? selectedId;
  String model = '';
  String effort = 'high';
  String theme = 'dark';
  bool initialized = false, authenticated = false, connecting = false;
  String? error;
  String? connectionError;
  int _catalogEpoch = 0, _authEpoch = 0;

  /// A saved session exists but the service could not be reached (network or server trouble, not a rejected login):
  /// the UI keeps the local history reachable, with sending off, instead of sending the user to the login page.
  bool get offlineSession => _offlineSession;
  bool _offlineSession = false;
  Timer? _retryTimer;
  int _retryAttempts = 0;
  DateTime? _lastConnectAt;

  /// Wait before the n-th automatic reconnect while offline (5 s, 10 s ... 60 s).
  @visibleForTesting
  Duration Function(int attempt) offlineRetryDelay = (n) =>
      Duration(seconds: (5 << n.clamp(0, 4)).clamp(5, 60));

  /// Coming back to the foreground retries at most this often.
  @visibleForTesting
  Duration resumeThrottle = const Duration(seconds: 3);

  /// Asked before the model unloads or loads a model on its own (model management); the UI shows the question.
  /// Without it these tools are refused: an instruction hidden in an attachment must not be able to run them.
  Future<bool> Function(String action)? confirmToolCall;
  bool get modelReady {
    final m = models.where((m) => m.id == model).firstOrNull;
    return connectionError == null &&
        m != null &&
        m.metadata['running'] != false &&
        !['loading', 'failed', 'unloaded'].contains(m.metadata['state']);
  }

  String? storageError;

  /// Attachments the last [exportBackup] could not read and left out.
  List<String> backupSkipped = [];
  // The saved file could not be read: saving would overwrite it, so persistence stays off until [startFresh].
  bool _storageBlocked = false, _saveFailed = false;
  bool get storageReadOnly => _storageBlocked;
  bool get persistFailed => _storageBlocked || _saveFailed;
  bool _blobsDirty = false;
  // After "start fresh" the preserved unreadable file still refers to attachments: nothing is collected from then on.
  bool _gcHold = false;
  final _heldBlobs = <String, int>{};
  final _trash = <({Conversation conversation, DateTime until})>[];

  /// How long a deleted conversation's attachment files are kept for the undo.
  @visibleForTesting
  Duration undoWindow = const Duration(seconds: 10);
  bool _disposed = false;
  int _serial = 0;
  Timer? _saveTimer;
  Timer? _streamRefresh;
  Future<void> _saveTail = Future.value();
  Conversation get current =>
      conversations.firstWhere((c) => c.id == selectedId);
  bool isGenerating(String id) =>
      _active.containsKey(id) ||
      (_voice?.active == true &&
          _voice?.conversationId == id &&
          _voice?.thinking == true);
  void _changed() {
    _dirty = true;
    _streamRefresh?.cancel();
    _streamRefresh = null;
    if (!_disposed) notifyListeners();
  }

  void _streamChanged() {
    if (_disposed || _streamRefresh != null) return;
    // Keep every delta immediately; batch expensive Markdown/layout updates.
    _streamRefresh = Timer(const Duration(milliseconds: 32), () {
      _streamRefresh = null;
      if (!_disposed) notifyListeners();
    });
  }

  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${_serial++}';

  Future<void> initialize() async {
    // Exports, backups and downloads staged before a kill sit in the temp folders as plain text; nothing of this launch
    // can be using them yet. Best-effort: it never fails the start.
    clearStaleCachedMedia();
    var loaded = false;
    try {
      final raw = await vault.read();
      if (raw != null) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        if (saved['version'] != 1) {
          throw const FormatException('Unknown saved version');
        }
        // Parse everything before touching live state: a half-applied file must never be saved back over the original.
        final sameServer =
            saved['server'] == api.endpoint.origin ||
            (saved['server'] == null &&
                api.endpoint.origin == 'https://jarvis.example.com');
        final restored = (saved['conversations'] as List)
            .map(
              (c) => Conversation.fromJson(Map<String, dynamic>.from(c as Map)),
            )
            .toList();
        final restoredSettings = Map<String, dynamic>.from(
          saved['settings'] as Map? ?? {},
        );
        api.cookie = sameServer ? saved['cookie'] as String? : null;
        settings.restore(restoredSettings);
        if (!sameServer) settings.apiKey = '';
        api.apiKey = settings.apiKey;
        model = saved['model'] as String? ?? '';
        _gcHold = saved['gcHold'] == true;
        conversations.addAll(restored);
        selectedId = saved['selectedId'] as String?;
        effort = ['none', 'low', 'medium', 'high'].contains(saved['effort'])
            ? saved['effort'] as String
            : 'high';
        theme = ['system', 'light', 'dark'].contains(saved['theme'])
            ? saved['theme'] as String
            : 'dark';
        // Migrate the old implicit system default once; future system choices
        // remain persistent through the versioned preference below.
        if (theme == 'system' && saved['themePreferenceVersion'] == null) {
          theme = 'dark';
        }
        loaded = true;
      }
    } catch (_) {
      // Read-only until the user explicitly starts fresh: the first save would overwrite the only copy.
      _storageBlocked = true;
      conversations.clear();
      storageError = '未能读取本机保存的资料，原文件未删除；本次修改不会保存，可重启应用重试，或选择从空白开始';
    }
    if (conversations.isEmpty) newConversation(save: false);
    if (!conversations.any((c) => c.id == selectedId)) {
      selectedId = conversations.first.id;
    }
    initialized = true;
    _changed();
    // Orphans left by a crash or an earlier version; never while the saved state could not be read.
    if (loaded) {
      _blobsDirty = true;
      unawaited(_collectBlobs());
    }
    if (api.cookie != null) await connect();
    for (final owner in conversations) {
      for (final task in owner.tasks.where((t) => t.pending)) {
        if (authenticated && task.source == 'voice' && task.jobId != null) {
          unawaited(_pollVoiceTask(owner, task));
        } else if (authenticated &&
            task.kind == 'video' &&
            task.jobId != null) {
          unawaited(_runMedia(owner, task, resume: true));
        } else {
          task.status = 'interrupted';
          task.error = '应用上次退出时任务未完成，请检查或重试原任务';
        }
      }
    }
    _changed();
  }

  Future<void> connect() async {
    final run = ++_catalogEpoch;
    _lastConnectAt = DateTime.now();
    connecting = true;
    error = null;
    _changed();
    try {
      final found = await api.models();
      if (run != _catalogEpoch || _disposed) return;
      models = found;
      connectionError = null;
      final chats = models.where((m) => m.kind == 'chat').toList();
      if (chats.isEmpty) throw const JarvisException('服务未提供可用的聊天模型');
      if (!chats.any((m) => m.id == model)) model = chats.first.id;
      if (settings.speechModel.isEmpty) {
        final speech = models.where((m) => m.kind == 'speech').firstOrNull;
        if (speech != null) {
          settings.speechModel = speech.id;
          settings.voices.putIfAbsent(speech.id, () => speech.defaultVoice);
        }
      }
      try {
        final skill = await api.modelSkill();
        if (run != _catalogEpoch || _disposed) return;
        modelSkill = skill;
      } catch (_) {
        if (run != _catalogEpoch || _disposed) return;
        modelSkill = {'enabled': false, 'text': ''};
      }
      authenticated = true;
      _offlineSession = false;
      _retryAttempts = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    } on JarvisException catch (e) {
      if (run != _catalogEpoch || _disposed) return;
      connectionError = e.message;
      error = e.message;
      if (e.unauthorized) {
        expireSession();
      } else {
        _wentOffline();
      }
    } catch (_) {
      if (run != _catalogEpoch || _disposed) return;
      connectionError = '暂时无法连接服务，请检查网络后重试';
      error = connectionError;
      _wentOffline();
    } finally {
      if (run == _catalogEpoch) {
        connecting = false;
        _changed();
      }
    }
  }

  void _wentOffline() {
    // Only a session that was already saved counts; a failed login has no cookie and stays on the login page.
    _offlineSession = !authenticated && api.cookie != null;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_offlineSession || _disposed) return;
    _retryTimer = Timer(offlineRetryDelay(_retryAttempts++), () {
      _retryTimer = null;
      unawaited(retryConnect());
    });
  }

  /// Tries the saved session again (the banner's button, the backoff timer, coming back to the foreground).
  Future<void> retryConnect() async {
    if (_disposed || authenticated || connecting || api.cookie == null) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    await connect();
    // A session first reached after a login that could not connect yet was never written down.
    if (authenticated) await save();
  }

  /// The app came back to the foreground: a dropped connection is worth another try right away.
  void appResumed() {
    if (!_offlineSession || connecting) return;
    final last = _lastConnectAt;
    if (last != null && DateTime.now().difference(last) < resumeThrottle) {
      return;
    }
    unawaited(retryConnect());
  }

  Future<bool> login(String username, String password) async {
    if (connecting) return false;
    final authRun = ++_authEpoch;
    connecting = true;
    error = null;
    _changed();
    try {
      await api.login(username.trim(), password);
      if (authRun != _authEpoch || _disposed) return false;
      await connect();
      if (authenticated) await save();
      return authenticated;
    } on JarvisException catch (e) {
      error = e.message;
      return false;
    } catch (_) {
      error = '登录连接失败，请检查网络后重试';
      return false;
    } finally {
      if (authRun == _authEpoch) {
        connecting = false;
        _changed();
      }
    }
  }

  void expireSession() {
    _catalogEpoch++;
    _authEpoch++;
    authenticated = false;
    connecting = false;
    _offlineSession = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    api.cookie = null;
    connectionError = '登录已过期，请重新登录';
    error = connectionError;
    if (_voice?.active == true) unawaited(_voice!.stop());
    for (final id in _active.keys.toList()) {
      cancel(id);
    }
    for (final request in _mediaActive.values.toList()) {
      api.cancel(request);
    }
    _mediaActive.clear();
    for (final owner in conversations) {
      for (final task in owner.tasks.where((t) => t.pending)) {
        task.status = 'interrupted';
        task.error = '已退出登录；任务可能仍在服务器运行，请重新登录后检查原任务';
      }
    }
    scheduleSave();
    _changed();
  }

  /// Signs out of the service. Conversations, settings (including the API key, which stays in the encrypted vault) and
  /// attachments stay on the device so signing in again picks up where the user left off; only cached media in the
  /// temp folders goes. [clearLocalData] is the "sign out and erase this device" variant.
  Future<void> logout() async {
    _catalogEpoch++;
    _authEpoch++;
    authenticated = false;
    connecting = false;
    _offlineSession = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _changed();
    await _voice?.stop();
    for (final id in _active.keys.toList()) {
      cancel(id);
    }
    try {
      await api.logout();
    } catch (_) {
      api.cookie = null;
    }
    for (final request in _mediaActive.values.toList()) {
      api.cancel(request);
    }
    _mediaActive.clear();
    for (final owner in conversations) {
      for (final task in owner.tasks.where((t) => t.pending)) {
        task.status = 'interrupted';
        task.error = '已退出登录；任务可能仍在服务器运行，请重新登录后检查原任务';
      }
    }
    authenticated = false;
    error = null;
    await save();
    await clearCachedMedia();
    _changed();
  }

  /// Signs out and erases everything this app keeps on the device: conversations, attachments, settings (API key
  /// included), the saved session and cached media. Returns false when the saved file could not be read: that copy is
  /// evidence the user has not decided about yet (see [startFresh]).
  Future<bool> clearLocalData() async {
    if (_storageBlocked) return false;
    await logout();
    conversations.clear();
    _trash.clear();
    _heldBlobs.clear();
    selectedId = null;
    theme = 'dark';
    models = [];
    modelSkill = {'enabled': false, 'text': ''};
    model = '';
    effort = 'high';
    settings.restore({});
    api.apiKey = '';
    api.cookie = null;
    connectionError = null;
    storageError = null;
    _gcHold = false;
    newConversation(save: false);
    // Blobs first: the state file must never be the only thing left saying what existed.
    try {
      for (final id in await blobs.list()) {
        await blobs.delete(id);
      }
    } catch (_) {
      _blobsDirty = true;
    }
    // The preserved copies of earlier unreadable files hold the old data too.
    if (vault case final EvidenceWiper wiper) {
      try {
        await wiper.wipeEvidence();
      } catch (_) {
        _blobsDirty = true;
      }
    }
    await save();
    if (_saveFailed) {
      // The old file (history and session cookie) would sign the next launch straight back in: remove it outright.
      if (vault case final StateEraser eraser) {
        try {
          await eraser.eraseState();
          _saveFailed = false;
          storageError = null;
        } catch (_) {}
      }
      // Said on the login page: signing out has already taken the settings page (and its notice) away.
      if (_saveFailed) error = '未能清除本机数据，请稍后重试';
    }
    _changed();
    return !persistFailed;
  }

  /// Returns the empty conversation that is already selected instead of stacking another one.
  Conversation newConversation({bool save = true}) {
    final selected = conversations.where((c) => c.id == selectedId).firstOrNull;
    if (selected != null &&
        selected.messages.isEmpty &&
        selected.tasks.isEmpty &&
        selected.draft.trim().isEmpty &&
        selected.pendingAttachments.isEmpty &&
        !attachmentsLoading(selected.id) &&
        !(_voice?.active == true && _voice?.conversationId == selected.id)) {
      return selected;
    }
    final c = Conversation(_id());
    conversations.insert(0, c);
    selectedId = c.id;
    if (save) scheduleSave();
    _changed();
    return c;
  }

  void select(String id) {
    if (conversations.any((c) => c.id == id)) {
      selectedId = id;
      scheduleSave();
      _changed();
    }
  }

  void notifyDraftSuggestion() {
    scheduleSave();
    _changed();
  }

  void setDraft(String value) {
    final c = current;
    c.draft = value;
    _draftDirty.add(c.id);
    // Typing must not re-encode the whole history; see [save].
    scheduleSave(draftOnly: true);
  }

  void setEffort(String value) {
    if (!['none', 'low', 'medium', 'high'].contains(value) || value == effort) {
      return;
    }
    effort = value;
    _voice?.cancelHold();
    _voice?.updateSettings();
    scheduleSave();
    _changed();
  }

  void setTheme(String value) {
    if (!['system', 'light', 'dark'].contains(value)) return;
    theme = value;
    scheduleSave();
    _changed();
  }

  void cancel(String id) {
    final m = _active.remove(id);
    if (m == null && _voice?.conversationId == id) {
      unawaited(_voice!.interrupt());
      return;
    }
    if (m != null) {
      m.message.status = 'interrupted';
      api.cancel(m.requestId);
      scheduleSave();
      _changed();
    }
  }

  Future<void> send() async {
    final c = current, text = current.draft.trim();
    if (attachmentsLoading(c.id)) {
      error = '附件仍在处理，草稿已保留';
      _changed();
      return;
    }
    if (!authenticated ||
        (text.isEmpty && c.pendingAttachments.isEmpty) ||
        model.isEmpty ||
        _active.containsKey(c.id)) {
      return;
    }
    if (_voice?.active == true &&
        _voice?.conversationId == c.id &&
        c.pendingAttachments.isEmpty) {
      if (_voice!.typed(text)) {
        c.draft = '';
        scheduleSave();
      } else {
        error = '语音尚未就绪或上一条回复仍在输出，草稿已保留';
      }
      _changed();
      return;
    }
    final attachments = List<Attachment>.of(c.pendingAttachments);
    c.pendingAttachments.clear();
    c.draft = '';
    if (c.messages.isEmpty && !c.named) {
      final title = tidyTitle(text.isEmpty ? attachments.first.name : text);
      if (title.isNotEmpty) c.title = title;
    }
    c.messages.add(ChatMessage('user', text, attachments: attachments));
    var reply = ChatMessage('assistant', '', status: 'generating');
    c.messages.add(reply);
    _active[c.id] = (requestId: _id(), message: reply);
    final requestId = _active[c.id]!.requestId;
    error = null;
    scheduleSave();
    _changed();
    final management = settings.tools && modelSkill['enabled'] == true;
    final option = ChatOptions(
      tools: settings.tools
          ? [...mediaToolSchema(models), if (management) ...modelToolSchema()]
          : [],
      maxTokens: settings.maxTokens,
    );
    final requestModel = model, requestEffort = effort;
    final instruction =
        settings.instructions + (management ? '\n\n${modelSkill['text']}' : '');
    try {
      for (var round = 0; round < (management ? 8 : 4); round++) {
        if (round > 0) {
          if (!_active.containsKey(c.id) || _disposed) return;
          reply = ChatMessage('assistant', '', status: 'generating');
          c.messages.add(reply);
          _active[c.id] = (requestId: requestId, message: reply);
        }
        final calls = <int, ToolCall>{};
        var done = false;
        final messages = await messagePayload(c, instruction: instruction);
        if (_active[c.id]?.message != reply) return;
        await for (final delta in api.chat(
          requestId,
          requestModel,
          requestEffort,
          messages,
          options: option,
        )) {
          if (_disposed || _active[c.id]?.message != reply) break;
          for (final d in delta.toolDeltas) {
            final call = calls.putIfAbsent(d.index, () => ToolCall());
            if (d.id.isNotEmpty) call.id = d.id;
            call.name += d.name;
            call.arguments += d.arguments;
          }
          done = done || delta.done;
          reply.text += delta.text;
          reply.reasoning += delta.reasoning;
          if (delta.finishReason == 'length') reply.status = 'length';
          if (delta.done && reply.status == 'generating') {
            reply.status = 'complete';
          }
          _streamChanged();
          scheduleSave();
        }
        if (reply.status == 'generating') reply.status = 'interrupted';
        if (!done ||
            reply.status != 'complete' ||
            _active[c.id]?.message != reply) {
          return;
        }
        if (calls.isEmpty) break;
        var background = false, continued = false;
        for (final call in calls.values) {
          if (_active[c.id]?.message != reply) return;
          if (call.id.isEmpty) call.id = 'call_${_id()}';
          final isMedia = [
                'generate_image',
                'generate_video',
              ].contains(call.name),
              isManagement = management && modelToolNames.contains(call.name);
          if (!isMedia && !isManagement) {
            reply.error = '模型请求了未开放的工具，未执行';
            reply.status = 'interrupted';
            continue;
          }
          reply.calls.add(call);
          Map<String, dynamic> args;
          try {
            args = Map<String, dynamic>.from(jsonDecode(call.arguments) as Map);
          } catch (_) {
            args = {};
          }
          if (isManagement) {
            final action = _changesModels(call.name, args);
            if (action != null && !await _confirmed(action)) {
              reply.toolResults[call.id] = jsonEncode({
                'error': '用户没有同意此操作（$action），未执行',
              });
              _changed();
            } else {
              reply.toolResults[call.id] = await api.modelTool(
                requestId,
                call.name,
                args,
              );
            }
            continued = true;
          } else {
            final kind = call.name == 'generate_video' ? 'video' : 'image',
                task = MediaTask(
                  id: _id(),
                  kind: kind,
                  prompt: args['prompt'] as String? ?? '',
                  args: args,
                  callId: call.id,
                );
            c.tasks.add(task);
            c.messages.add(ChatMessage('tool', task.prompt, taskId: task.id));
            unawaited(_runMedia(c, task));
            background = true;
          }
        }
        scheduleSave();
        _changed();
        if (background || !continued) break;
        if (round == (management ? 7 : 3)) {
          reply.error = '已达到本轮工具调用上限，请明确下一步操作';
          reply.status = 'interrupted';
        }
      }
    } on JarvisException catch (e) {
      if (_active[c.id]?.message == reply) {
        reply.status = 'interrupted';
        reply.error = e.message;
        if (e.unauthorized) {
          expireSession();
        }
      }
    } catch (_) {
      if (_active[c.id]?.message == reply) {
        reply.status = 'interrupted';
        reply.error = '连接中断，已保留收到的内容；未自动重试';
      }
    } finally {
      if (_active[c.id]?.message == reply) _active.remove(c.id);
      if (!_disposed) {
        _changed();
        await save();
      }
    }
  }

  /// What a model-management call would change, in words for the question; null for the read-only ones.
  String? _changesModels(String tool, Map<String, dynamic> args) {
    final name = '${args['model'] ?? ''}'.trim();
    final label = name.isEmpty ? '指定的模型' : '模型 $name';
    return switch (tool) {
      'unload_model' => '卸载$label',
      'load_model' => '加载$label',
      'reserve_for' when args['dry_run'] != true => '为$label预留空间',
      _ => null,
    };
  }

  Future<bool> _confirmed(String action) async {
    final ask = confirmToolCall;
    if (ask == null) return false;
    try {
      return await ask(action);
    } catch (_) {
      return false;
    }
  }

  String _voiceSettingsSignature() {
    final config = settings.toJson()
      ..remove('messageFontSize')
      ..remove('atlasVoiceDefaultRevision');
    return jsonEncode(config);
  }

  void changeSettings(void Function(ChatSettings) edit) {
    final previousSpeech = settings.speechModel,
        previousVoice = settings.voices[settings.speechModel],
        previousConfig = _voiceSettingsSignature();
    edit(settings);
    api.apiKey = settings.apiKey;
    // Presentation-only/no-op edits must not discard a microphone buffer or
    // pause an already confirmed voice session.
    if (_voiceSettingsSignature() != previousConfig) {
      final voiceChanged =
          previousSpeech != settings.speechModel ||
          previousVoice != settings.voices[settings.speechModel];
      if (_voice?.active == true && voiceChanged) {
        unawaited(_voice!.interrupt());
      }
      // The error was about the old engine/voice (unavailable voice, failed preview); a live call keeps its own.
      if (voiceChanged) _voice?.clearIdleError();
      _voice?.cancelHold();
      if (_voice?.previewing == true) unawaited(_voice!.stopPreview());
      _voiceSettingsTimer?.cancel();
      _voiceSettingsTimer = Timer(const Duration(milliseconds: 200), () {
        _voice?.updateSettings();
      });
    }
    scheduleSave();
    _changed();
  }

  void rename(String id, String title) {
    final c = conversations.where((c) => c.id == id).firstOrNull;
    if (c == null || title.trim().isEmpty) return;
    c.title = title.trim();
    c.named = true;
    scheduleSave();
    _changed();
  }

  /// A conversation can't be deleted while it generates, is in a call, or has pending work.
  bool canDeleteConversation(String id) {
    final c = conversations.where((c) => c.id == id).firstOrNull;
    return c != null &&
        !isGenerating(id) &&
        !(_voice?.active == true && _voice?.conversationId == id) &&
        !c.tasks.any((t) => t.pending);
  }

  Conversation? deleteConversation(String id) {
    if (!canDeleteConversation(id)) return null;
    final c = conversations.firstWhere((c) => c.id == id);
    conversations.remove(c);
    if (conversations.isEmpty) newConversation(save: false);
    if (selectedId == id) selectedId = conversations.first.id;
    // Its attachments stay on disk while the undo is still offered.
    _trash.add((conversation: c, until: DateTime.now().add(undoWindow)));
    _blobsDirty = true;
    scheduleSave();
    _changed();
    return c;
  }

  void restoreConversation(Conversation c) {
    if (conversations.any((v) => v.id == c.id)) return;
    _trash.removeWhere((t) => t.conversation == c);
    conversations.insert(0, c);
    select(c.id);
  }

  Future<void> addAttachment(
    Conversation owner,
    Attachment attachment,
    Uint8List? bytes,
  ) async {
    if (!conversations.contains(owner)) return;
    if (owner.pendingAttachments.length >= 4) {
      throw const JarvisException('每条消息最多4个附件');
    }
    if (bytes != null) {
      // Held from before the write so a collection in between cannot take a blob nothing references yet.
      holdBlobs([attachment.id]);
      try {
        await blobs.put(attachment.id, bytes);
        if (!conversations.contains(owner) ||
            owner.pendingAttachments.length >= 4) {
          await _discardBlob(attachment.id);
          if (!conversations.contains(owner)) return;
          throw const JarvisException('每条消息最多4个附件');
        }
        owner.pendingAttachments.add(attachment);
      } finally {
        releaseBlobs([attachment.id]);
      }
    } else {
      owner.pendingAttachments.add(attachment);
    }
    await save();
    _changed();
  }

  Future<void> _discardBlob(String id) async {
    try {
      await blobs.delete(id);
    } catch (_) {
      _blobsDirty = true;
    }
  }

  void removeAttachment(String id) {
    current.pendingAttachments.removeWhere((a) => a.id == id);
    _blobsDirty = true;
    scheduleSave();
    _changed();
  }

  /// Keeps blobs that are written but not yet referenced by a conversation (an import in progress) out of the collection.
  void holdBlobs(Iterable<String> ids) {
    for (final id in ids) {
      _heldBlobs.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  void releaseBlobs(Iterable<String> ids) {
    for (final id in ids) {
      final n = (_heldBlobs[id] ?? 1) - 1;
      if (n <= 0) {
        _heldBlobs.remove(id);
      } else {
        _heldBlobs[id] = n;
      }
    }
  }

  /// Deletes attachment files that no conversation, undo window or write in flight refers to.
  Future<void> _collectBlobs() async {
    if (!_blobsDirty || _storageBlocked || _gcHold || _disposed) return;
    final now = DateTime.now();
    _trash.removeWhere((t) => t.until.isBefore(now));
    // Something may still be undone; look again after the next save.
    if (_trash.isNotEmpty) return;
    _blobsDirty = false;
    try {
      final stored = await blobs.list();
      final keep = <String>{..._heldBlobs.keys};
      for (final c in conversations) {
        for (final a in [
          ...c.pendingAttachments,
          ...c.messages.expand((m) => m.attachments),
        ]) {
          keep.add(a.id);
        }
      }
      for (final id in stored.where((id) => !keep.contains(id))) {
        if (_heldBlobs.containsKey(id)) continue;
        // A conversation deleted while this runs may still be undone.
        if (_trash.isNotEmpty) {
          _blobsDirty = true;
          return;
        }
        await blobs.delete(id);
      }
    } catch (_) {
      _blobsDirty = true;
    }
  }

  Future<List<Map<String, dynamic>>> messagePayload(
    Conversation c, {
    String? instruction,
  }) async {
    final out = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            '你是贾维斯。用户用什么语言交流，就使用同一种语言回答。工具任务回执不是新用户输入，不要因此插话或切换语言。${(instruction ?? settings.instructions).isEmpty ? '' : '\n${instruction ?? settings.instructions}'}',
      },
    ];
    var imageBytes = 0, textChars = 0;
    for (final m in c.messages.where((m) => !m.hidden)) {
      if (m.role == 'user') {
        final parts = <Map<String, dynamic>>[
          if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
        ];
        for (final a in m.attachments) {
          if (a.kind == 'image') {
            Uint8List bytes;
            try {
              bytes = await blobs.get(a.id);
            } catch (_) {
              // A lost file must not make the whole conversation unsendable.
              parts.add({'type': 'text', 'text': '[附件「${a.name}」不可用]'});
              continue;
            }
            imageBytes += bytes.length;
            if (imageBytes > 18 * 1024 * 1024) {
              throw const JarvisException('会话图片超过18MB，请新建话题');
            }
            parts.add({
              'type': 'image_url',
              'image_url': {
                'url': 'data:${a.mime};base64,${base64Encode(bytes)}',
              },
            });
          } else {
            final text = a.text ?? '';
            textChars += text.length;
            if (textChars > 200000) {
              throw const JarvisException('会话附件文字过多，请拆分或新建话题');
            }
            parts.add({'type': 'text', 'text': '附件「${a.name}」的内容：\n$text'});
          }
        }
        out.add({
          'role': 'user',
          'content': m.attachments.isEmpty ? m.text : parts,
        });
      } else if (m.role == 'assistant' &&
          (m.text.isNotEmpty || m.calls.isNotEmpty)) {
        out.add({
          'role': 'assistant',
          'content': m.text.isEmpty ? null : m.text,
          if (m.calls.isNotEmpty)
            'tool_calls': m.calls.map((c) => c.toJson()).toList(),
        });
        for (final call in m.calls) {
          final task = c.tasks.where((t) => t.callId == call.id).firstOrNull;
          out.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content':
                m.toolResults[call.id] ??
                jsonEncode(task?.receipt ?? {'status': 'cancelled'}),
          });
        }
      }
    }
    return out;
  }

  Future<void> retryMedia(MediaTask task) async {
    final owner = conversations
        .where((c) => c.tasks.contains(task))
        .firstOrNull;
    if (owner == null || _mediaActive.containsKey(task.id)) return;
    if (task.source == 'voice' &&
        task.jobId != null &&
        task.status != 'failed') {
      task.status = 'in_progress';
      await _pollVoiceTask(owner, task);
      return;
    }
    task.source = 'http';
    task.error = null;
    task.status = 'queued';
    await _runMedia(
      owner,
      task,
      resume: task.kind == 'video' && task.jobId != null,
    );
  }

  /// Stops a running image or video task: the service call is cancelled and the card says so (and can be retried), which
  /// also lets the conversation be deleted again.
  Future<void> cancelMediaTask(MediaTask task) async {
    final request = _mediaActive.remove(task.id);
    if (request != null) api.cancel(request);
    if (task.pending) {
      task.status = 'interrupted';
      task.error = '已取消';
    }
    scheduleSave();
    _changed();
  }

  Future<void> startMedia(
    String kind,
    String prompt, {
    Map<String, dynamic> args = const {},
  }) async {
    if (!authenticated || !settings.tools) return;
    final owner = current,
        task = MediaTask(
          id: _id(),
          kind: kind,
          prompt: prompt,
          args: {...args, 'prompt': prompt},
        );
    owner.tasks.add(task);
    owner.messages.add(ChatMessage('tool', prompt, taskId: task.id));
    unawaited(_runMedia(owner, task));
    _changed();
  }

  Future<void> _runMedia(
    Conversation owner,
    MediaTask task, {
    bool resume = false,
  }) async {
    if (_mediaActive.containsKey(task.id)) return;
    final request = 'media_${_id()}';
    _mediaActive[task.id] = request;
    task.status = 'in_progress';
    scheduleSave();
    _changed();
    try {
      final model = models.where((m) => m.kind == task.kind).firstOrNull;
      if (model == null || task.prompt.trim().isEmpty) {
        throw const JarvisException('当前模型不支持此任务，或提示词为空');
      }
      final maxSeconds =
          (model.metadata['limits']?['max_seconds'] as num?)?.toInt() ?? 5;
      final seconds = task.args['seconds'];
      if (seconds != null &&
          (seconds is! num || seconds < 1 || seconds > maxSeconds)) {
        throw JarvisException('当前视频支持1至$maxSeconds秒');
      }
      final urls = await api.generate(
        request,
        task.kind,
        {...task.args, 'model': model.id},
        resumeJobId: resume ? task.jobId : null,
        onJob: (id) {
          task.jobId = id;
          scheduleSave();
        },
        onProgress: (p) {
          task.progress = p;
          _changed();
        },
      );
      if (_mediaActive[task.id] != request) return;
      if (urls.isEmpty) throw const JarvisException('任务没有返回作品地址');
      task.urls = urls;
      task.status = 'completed';
      task.error = null;
      task.progress = 100;
    } catch (e) {
      if (_mediaActive[task.id] == request) {
        task.status = 'failed';
        task.error = e is JarvisException ? e.message : '生成失败，请稍后重试原任务';
      }
    } finally {
      if (_mediaActive[task.id] == request) _mediaActive.remove(task.id);
      if (!_disposed) {
        await save();
        _changed();
      }
    }
  }

  /// How often a voice job is asked about, and how long it is followed before it is marked interrupted (a stuck server
  /// task would otherwise be polled forever and keep its conversation from being deleted).
  @visibleForTesting
  Duration voicePollInterval = const Duration(seconds: 3);
  @visibleForTesting
  Duration voicePollDeadline = const Duration(minutes: 30);

  Future<void> _pollVoiceTask(Conversation owner, MediaTask task) async {
    if (_mediaActive.containsKey(task.id) || task.jobId == null) return;
    final request = 'poll_${_id()}';
    _mediaActive[task.id] = request;
    var failures = 0;
    final started = DateTime.now();
    // Checked after asking, never before: the first poll after iOS kept the app suspended past the deadline must not
    // write off a job the server has finished in the meantime.
    bool overdue() => DateTime.now().difference(started) > voicePollDeadline;
    try {
      while (!_disposed &&
          authenticated &&
          task.pending &&
          _mediaActive[task.id] == request) {
        await Future<void>.delayed(voicePollInterval);
        if (_disposed ||
            !authenticated ||
            !task.pending ||
            _mediaActive[task.id] != request) {
          break;
        }
        Map<String, dynamic> state;
        try {
          state = await api.jobStatus(task.jobId!);
          failures = 0;
        } catch (e) {
          if (e is JarvisException && e.unauthorized) {
            expireSession();
            break;
          }
          if (++failures >= 20) {
            task.status = 'interrupted';
            task.error = '暂时无法检查任务，服务器可能仍在运行；请检查原任务';
            break;
          }
          if (overdue()) {
            task.status = 'interrupted';
            task.error = '任务等待时间过长，服务器可能仍在运行；请检查原任务';
            break;
          }
          continue;
        }
        if (_mediaActive[task.id] != request || !task.pending) break;
        final status = state['status'];
        task.progress =
            (state['progress'] as num?)?.toDouble() ?? task.progress;
        if (['completed', 'succeeded'].contains(status)) {
          task.urls = stringList(
            state['urls'] ??
                (state['data'] as List? ?? [])
                    .map((x) => x is Map ? x['url'] : null)
                    .toList(),
          );
          task.settleKind(
            state['kind'] ?? state['job_type'] ?? state['object'],
          );
          if (task.urls.isEmpty && task.kind == 'video') {
            task.urls = [
              '/v1/videos/${Uri.encodeComponent(task.jobId!)}/content',
            ];
          }
          task.status = task.urls.isEmpty ? 'failed' : 'completed';
          task.error = task.urls.isEmpty ? '任务未返回作品地址' : null;
          task.progress = 100;
        } else if (['failed', 'cancelled'].contains(status)) {
          task.status = 'failed';
          task.error = '生成失败，请重试原任务';
        }
        if (task.pending && overdue()) {
          task.status = 'interrupted';
          task.error = '任务等待时间过长，服务器可能仍在运行；请检查原任务';
        }
        scheduleSave();
        _changed();
      }
    } finally {
      if (_mediaActive[task.id] == request) _mediaActive.remove(task.id);
      if (!_disposed) {
        await save();
        _changed();
      }
    }
  }

  /// Asks the model to carry on after a reply that stopped at the length limit.
  Future<void> continueReply() async {
    final c = current;
    if (c.draft.trim().isNotEmpty ||
        c.pendingAttachments.isNotEmpty ||
        isGenerating(c.id)) {
      return;
    }
    // Sending is refused (and the draft would linger in the composer) while signed out, without a model or loading.
    if (!authenticated || model.isEmpty || attachmentsLoading(c.id)) return;
    c.draft = '请继续';
    await send();
    // A send that did not start (voice not ready, say) must not leave the prompt behind for the person to find.
    if (c.draft == '请继续') {
      c.draft = '';
      scheduleSave(draftOnly: true);
      _changed();
    }
  }

  Future<void> regenerate() async {
    final c = current;
    if (isGenerating(c.id) ||
        (_voice?.active == true && _voice?.conversationId == c.id)) {
      return;
    }
    final index = c.messages.lastIndexWhere(
      (m) => m.role == 'user' && !m.hidden,
    );
    if (index < 0) return;
    final following = c.messages.skip(index + 1);
    if (following.any(
      (m) =>
          m.taskId != null && c.tasks.any((t) => t.id == m.taskId && t.pending),
    )) {
      error = '原媒体任务仍在运行，可以直接发送新的请求';
      _changed();
      return;
    }
    // The composer is not ours to overwrite, and nothing may be hidden unless the resend is going to start.
    if (c.draft.trim().isNotEmpty || c.pendingAttachments.isNotEmpty) {
      error = '输入框里还有未发送的内容，请先发送或清空后再重新生成';
      _changed();
      return;
    }
    if (attachmentsLoading(c.id) || !authenticated || model.isEmpty) {
      error = attachmentsLoading(c.id)
          ? '附件仍在处理，请稍后再重新生成'
          : '当前无法发送，请检查连接后再重新生成';
      _changed();
      return;
    }
    final user = c.messages[index];
    for (final m in c.messages.skip(index)) {
      m.hidden = true;
    }
    c.draft = user.text;
    c.pendingAttachments.clear();
    c.pendingAttachments.addAll(user.attachments);
    await send();
  }

  bool wipeConversations() {
    if (conversations.any(
          (c) => isGenerating(c.id) || c.tasks.any((t) => t.pending),
        ) ||
        _voice?.active == true) {
      return false;
    }
    conversations.clear();
    // Nothing is left to undo, so the attachment files can go at the next save.
    _trash.clear();
    _blobsDirty = true;
    newConversation();
    return true;
  }

  void installImported(List<Conversation> imported) {
    conversations.insertAll(0, imported);
    if (imported.isNotEmpty) selectedId = imported.first.id;
    scheduleSave();
    _changed();
  }

  void setModel(String id) {
    if (!models.any((m) => m.id == id && m.kind == 'chat')) return;
    model = id;
    _voice?.cancelHold();
    _voice?.updateSettings();
    scheduleSave();
    _changed();
  }

  void voiceTask(Conversation owner, Map<String, dynamic> event) {
    if (!conversations.contains(owner)) return;
    final call = (event['call_id'] ?? event['id']) as String?;
    var task = owner.tasks
        .where(
          (t) =>
              (call != null && t.callId == call) ||
              (event['job_id'] != null && t.jobId == event['job_id']),
        )
        .firstOrNull;
    // A job event that names neither the call nor a known job belongs to the newest voice task still waiting for one.
    if (task == null && event['type'] != 'call') {
      task = owner.tasks
          .where((t) => t.source == 'voice' && t.pending && t.jobId == null)
          .lastOrNull;
    }
    if (event['type'] == 'call') {
      if (!['generate_image', 'generate_video'].contains(event['name'])) return;
      Map<String, dynamic> args = {};
      try {
        args = Map<String, dynamic>.from(
          jsonDecode(event['arguments'] as String? ?? '{}') as Map,
        );
      } catch (_) {}
      task ??= MediaTask(
        id: _id(),
        kind: event['name'] == 'generate_video' ? 'video' : 'image',
        prompt: args['prompt'] as String? ?? '',
        args: args,
        callId: call,
        status: 'in_progress',
        source: 'voice',
      );
    } else {
      task ??= MediaTask(
        id: _id(),
        kind:
            '${event['kind'] ?? event['job_type'] ?? event['object']}'.contains(
              'video',
            )
            ? 'video'
            : 'image',
        prompt: '',
        args: {},
        callId: call,
        status: 'in_progress',
        source: 'voice',
      );
    }
    if (!owner.tasks.contains(task)) {
      owner.tasks.add(task);
      owner.messages.add(ChatMessage('tool', task.prompt, taskId: task.id));
    }
    if (event['job_id'] != null) task.jobId = event['job_id'] as String;
    if (event['type'] == 'localrouter.job.created' && task.jobId != null) {
      unawaited(_pollVoiceTask(owner, task));
    }
    if (event['type'] == 'localrouter.job.done') {
      task.status = event['status'] == 'completed' ? 'completed' : 'failed';
      task.urls = stringList(event['urls']);
      task.settleKind(event['kind'] ?? event['job_type'] ?? event['object']);
      if (task.status == 'completed' &&
          task.urls.isEmpty &&
          task.kind == 'video' &&
          task.jobId != null) {
        task.urls = ['/v1/videos/${Uri.encodeComponent(task.jobId!)}/content'];
      }
      task.error = task.status == 'failed' ? '生成失败，请重试原任务' : null;
    }
    scheduleSave();
    _changed();
  }

  // Per-conversation JSON from the last full save, and the conversations whose draft changed since. While only drafts
  // changed, the next save re-encodes just those instead of the whole history.
  final _encoded = <String, String>{};
  final _draftDirty = <String>{};
  bool _fullSaveDue = true;

  /// [draftOnly]: nothing but a draft changed (the timer may then take the cheap path in [save]).
  void scheduleSave({bool draftOnly = false}) {
    if (_disposed) return;
    _dirty = true;
    if (!draftOnly) _fullSaveDue = true;
    // Every streamed delta restarts the debounce: a long reply would otherwise not be written until it ends.
    final due =
        initialized &&
        !_storageBlocked &&
        DateTime.now().difference(_lastSaveAt) > maxSaveWait;
    _saveTimer?.cancel();
    if (due) {
      unawaited(_save(cheap: !_fullSaveDue));
      return;
    }
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save(cheap: !_fullSaveDue));
    });
  }

  /// The longest a pending change waits for the debounce while saves keep being rescheduled.
  @visibleForTesting
  Duration maxSaveWait = const Duration(seconds: 5);
  DateTime _lastSaveAt = DateTime.now();

  Future<void> save() => _save(cheap: false);

  // Anything that may differ from the last write: set at every change notification and save request (a redundant save
  // costs little, a lost one costs history), cleared when a full save starts and set again if its write fails.
  bool _dirty = true;
  String? _savedHead;

  /// [save] unless nothing changed since the last write: the app going inactive and then paused would otherwise
  /// re-encode and re-encrypt the whole history twice for nothing.
  Future<void> saveIfDirty() {
    if (!initialized || _storageBlocked) return _saveTail;
    if (_dirty ||
        _saveFailed ||
        _saveTimer?.isActive == true ||
        _head() != _savedHead) {
      return save();
    }
    // The write still running (the one going inactive started) can yet fail, and nothing else would try it again.
    return _saveTail.then((_) async {
      if (_saveFailed && !_disposed) await save();
    });
  }

  // Everything but the conversations; small, and it also catches changes made behind the controller's back (the cookie).
  String _head() => jsonEncode({
    'version': 1,
    'server': api.endpoint.origin,
    'model': model,
    'settings': settings.toJson(),
    'cookie': api.cookie,
    'selectedId': selectedId,
    'effort': effort,
    'theme': theme,
    'themePreferenceVersion': 1,
    if (_gcHold) 'gcHold': true,
  });

  Future<void> _save({required bool cheap}) {
    _saveTimer?.cancel();
    // Before the saved file is read the lists are empty and the cookie is null: writing now would erase it.
    if (!initialized || _storageBlocked) return _saveTail;
    _lastSaveAt = DateTime.now();
    final fresh = <String, String>{};
    for (final c in conversations) {
      final reuse = cheap && !_draftDirty.contains(c.id)
          ? _encoded[c.id]
          : null;
      fresh[c.id] = reuse ?? jsonEncode(c.toJson());
    }
    _encoded
      ..clear()
      ..addAll(fresh);
    _draftDirty.clear();
    _fullSaveDue = false;
    // A draft-only save reuses the other conversations' last encodings: a change made since without asking for a save
    // (only noted by [_changed]) is not in it, so only a full save counts as having written everything.
    if (!cheap) _dirty = false;
    final head = _head();
    _savedHead = head;
    final value =
        '${head.substring(0, head.length - 1)},"conversations":[${fresh.values.join(',')}]}';
    _saveTail = _saveTail
        .then((_) => vault.write(value))
        .then((_) async {
          if (_saveFailed) {
            _saveFailed = false;
            storageError = null;
            _changed();
          }
          await _collectBlobs();
        })
        .catchError((Object _) {
          _dirty = true;
          _saveFailed = true;
          storageError = '本机保存失败，请勿清除应用资料';
          _changed();
        });
    return _saveTail;
  }

  /// Leaves the unreadable saved file aside and lets saving replace it. The user has to ask for this.
  Future<void> startFresh() async {
    if (!_storageBlocked) return;
    try {
      if (vault case final UnreadableKeeper keeper) {
        await keeper.keepUnreadable();
      }
    } catch (_) {
      storageError = '无法备份原文件，未清空；请重启应用重试';
      _changed();
      return;
    }
    _storageBlocked = false;
    storageError = null;
    _blobsDirty = false;
    // The preserved file still names attachments; collecting now (or after the next launch) would delete them.
    if (vault is UnreadableKeeper) _gcHold = true;
    _changed();
    await save();
  }

  @override
  void dispose() {
    _disposed = true;
    _catalogEpoch++;
    _voiceSettingsTimer?.cancel();
    _retryTimer?.cancel();
    _voice?.dispose();
    _saveTimer?.cancel();
    api.close();
    _streamRefresh?.cancel();
    super.dispose();
  }
}

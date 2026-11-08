import 'dart:async';
import 'dart:convert';

import '../model/media.dart';
import '../model/settings.dart';
import '../model/starters.dart';
import '../net/tool_schema.dart';
import '../net/model_tools.dart';
import 'blobs.dart';
import '../voice/voice_session.dart';
import '../voice/audio_device.dart';

import 'package:flutter/foundation.dart';

import '../model/conversation.dart';
import '../net/jarvis_api.dart';
import 'vault.dart';

typedef PendingWorkNotice = ({
  Object source,
  String ownerId,
  String title,
  VoidCallback open,
});

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
    refreshCatalog: refreshVoiceCatalog,
    isConversationAvailable: (c) => authenticated && conversations.contains(c),
    effort: () => voiceEffort,
    model: () => model,
    changed: () {
      scheduleSave();
      _changed();
    },
    onTask: voiceTask,
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
  String get voiceEffort {
    if (settings.voiceEffort.isNotEmpty) return settings.voiceEffort;
    final chat = models.where((m) => m.id == model).firstOrNull;
    final policy = chat?.metadata['jarvis'];
    final defaults = policy is Map ? policy['voice_defaults'] : null;
    final value = defaults is Map ? defaults['reasoning_effort'] : null;
    return ['none', 'low', 'medium', 'high'].contains(value)
        ? value as String
        : 'low';
  }

  void setVoiceEffort(String value) {
    if (!['', 'none', 'low', 'medium', 'high'].contains(value)) return;
    changeSettings((s) => s.voiceEffort = value);
  }

  String theme = 'dark';
  bool initialized = false, authenticated = false, connecting = false;
  String? error;
  String? connectionError;
  int _catalogEpoch = 0, _authEpoch = 0;
  bool get modelReady {
    final m = models.where((m) => m.id == model).firstOrNull;
    return connectionError == null &&
        m != null &&
        m.metadata['running'] != false &&
        !['loading', 'failed', 'unloaded'].contains(m.metadata['state']);
  }

  String? storageError;

  /// Ephemeral UI state; never persisted or sent to the model.
  String? readingHistoryId;
  final pendingWorkNotice = ValueNotifier<PendingWorkNotice?>(null);
  void updatePendingWorkNotice(
    PendingWorkNotice? value, {
    Object? clearSource,
  }) {
    if (_disposed) return;
    final old = pendingWorkNotice.value;
    if (clearSource != null && old?.source != clearSource) return;
    if (old?.source == value?.source &&
        old?.ownerId == value?.ownerId &&
        old?.title == value?.title) {
      return;
    }
    pendingWorkNotice.value = value;
  }

  bool _disposed = false;
  int _serial = 0;
  Timer? _saveTimer;
  Timer? _streamRefresh;
  int _streamIntervalMs = 32;

  /// Slow frames reduce layout pressure; deltas themselves are never delayed.
  /// Only measure during generation, so unrelated animations cannot slow chat.
  void reportStreamBuild(Duration build) {
    if (_active.isEmpty || _disposed) return;
    final target = (build.inMicroseconds * 3 / 1000).ceil().clamp(32, 96);
    _streamIntervalMs = target > _streamIntervalMs
        ? target
        : ((_streamIntervalMs * 3 + target) / 4).round();
  }

  Future<void> _saveTail = Future.value();
  Conversation get current =>
      conversations.firstWhere((c) => c.id == selectedId);
  bool isGenerating(String id) =>
      _active.containsKey(id) ||
      (_voice?.active == true &&
          _voice?.conversationId == id &&
          _voice?.thinking == true);
  void _changed() {
    _streamRefresh?.cancel();
    _streamRefresh = null;
    if (!_disposed) notifyListeners();
  }

  void _streamChanged() {
    if (_disposed || _streamRefresh != null) return;
    // Keep every delta immediately; batch expensive Markdown/layout updates.
    _streamRefresh = Timer(Duration(milliseconds: _streamIntervalMs), () {
      _streamRefresh = null;
      if (!_disposed) notifyListeners();
    });
  }

  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${_serial++}';

  Future<void> initialize() async {
    try {
      final raw = await vault.read();
      if (raw != null) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        if (saved['version'] != 1) {
          throw const FormatException('Unknown saved version');
        }
        final sameServer =
            saved['server'] == api.endpoint.origin ||
            (saved['server'] == null &&
                api.endpoint.origin == 'https://jarvis.odn.cc');
        api.cookie = sameServer ? saved['cookie'] as String? : null;
        settings.restore(
          Map<String, dynamic>.from(saved['settings'] as Map? ?? {}),
        );
        if (!sameServer) settings.apiKey = '';
        api.apiKey = settings.apiKey;
        model = saved['model'] as String? ?? '';
        conversations.addAll(
          (saved['conversations'] as List).map(
            (c) => Conversation.fromJson(Map<String, dynamic>.from(c as Map)),
          ),
        );
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
      }
    } catch (_) {
      storageError = '未能读取本机保存的资料，原文件未删除';
    }
    if (conversations.isEmpty) newConversation(save: false);
    if (!conversations.any((c) => c.id == selectedId)) {
      selectedId = conversations.first.id;
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
    initialized = true;
    _changed();
  }

  Future<void> connect() async {
    final run = ++_catalogEpoch;
    connecting = true;
    error = null;
    _changed();
    try {
      final found = await api.models();
      if (run != _catalogEpoch || _disposed) return;
      models = found;
      if (_voice?.active != true &&
          settings.applyVoiceDefaults(models, scope: api.endpoint.origin)) {
        scheduleSave();
      }
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
    } on JarvisException catch (e) {
      if (run != _catalogEpoch || _disposed) return;
      connectionError = e.message;
      error = e.message;
      if (e.unauthorized) {
        expireSession();
      }
    } catch (_) {
      if (run != _catalogEpoch || _disposed) return;
      connectionError = '暂时无法连接服务，请检查网络后重试';
      error = connectionError;
    } finally {
      if (run == _catalogEpoch) {
        connecting = false;
        _changed();
      }
    }
  }

  Future<bool>? _voiceCatalogRefresh;
  Future<bool> refreshVoiceCatalog() {
    if (!authenticated ||
        _disposed ||
        (_voice?.active == true && _voice?.reconnecting != true)) {
      return Future.value(false);
    }
    return _voiceCatalogRefresh ??= _loadVoiceCatalog().whenComplete(() {
      _voiceCatalogRefresh = null;
    });
  }

  Future<bool> _loadVoiceCatalog() async {
    final epoch = _catalogEpoch;
    try {
      final found = await api.models().timeout(const Duration(seconds: 10));
      if (_disposed ||
          !authenticated ||
          epoch != _catalogEpoch ||
          (_voice?.active == true && _voice?.reconnecting != true)) {
        return false;
      }
      models = found;
      if (settings.speechModel.isEmpty) {
        settings.speechModel =
            models.where((m) => m.kind == 'speech').firstOrNull?.id ?? '';
      }
      if (settings.applyVoiceDefaults(models, scope: api.endpoint.origin)) {
        scheduleSave();
      }
      _changed();
      return true;
    } catch (_) {
      return false;
    }
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
    api.cookie = null;
    connectionError = '登录已过期，请重新登录';
    error = connectionError;
    if (_voice != null) unawaited(_voice!.stop());
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

  Future<void> logout() async {
    _catalogEpoch++;
    _authEpoch++;
    authenticated = false;
    connecting = false;
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
    _changed();
  }

  void newConversation({bool save = true}) {
    final c = Conversation(_id());
    conversations.insert(0, c);
    selectedId = c.id;
    if (save) scheduleSave();
    _changed();
  }

  void select(String id) {
    if (conversations.any((c) => c.id == id)) {
      selectedId = id;
      scheduleSave();
      _changed();
    }
  }

  /// A starter card was picked: its prompt goes after what is already written
  /// (on its own line), not over it.
  void addStarterPrompt(String prompt) {
    final draft = current.draft;
    current.draft = draft.trim().isEmpty ? prompt : '$draft\n$prompt';
    notifyDraftSuggestion();
  }

  void notifyDraftSuggestion() {
    scheduleSave();
    _changed();
  }

  void setDraft(String value) {
    current.draft = value;
    scheduleSave();
  }

  void setEffort(String value) {
    if (!['none', 'low', 'medium', 'high'].contains(value) || value == effort) {
      return;
    }
    effort = value;
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
      unawaited(_voice!.interrupt(source: 'conversation_cancel'));
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
      final title = text.isEmpty ? attachments.first.name : text;
      c.title = title.length > 24 ? '${title.substring(0, 24)}…' : title;
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
            reply.toolResults[call.id] = await api.modelTool(
              requestId,
              call.name,
              args,
            );
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

  String _voiceSettingsSignature() {
    final config = settings.toJson()
      ..remove('messageFontSize')
      ..remove('atlasVoiceDefaultRevision')
      ..remove('voiceDefaultRevisions');
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
      if (_voice?.active == true &&
          (previousSpeech != settings.speechModel ||
              previousVoice != settings.voices[settings.speechModel])) {
        unawaited(_voice!.interrupt(source: 'voice_setting_changed'));
      }
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
        _voice?.ownsConversation(id) != true &&
        !c.tasks.any((t) => t.pending);
  }

  Conversation? deleteConversation(String id) {
    if (!canDeleteConversation(id)) return null;
    final c = conversations.firstWhere((c) => c.id == id);
    conversations.remove(c);
    if (conversations.isEmpty) newConversation(save: false);
    if (selectedId == id) selectedId = conversations.first.id;
    scheduleSave();
    _changed();
    return c;
  }

  void restoreConversation(Conversation c) {
    if (conversations.any((v) => v.id == c.id)) return;
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
    if (bytes != null) await blobs.put(attachment.id, bytes);
    if (!conversations.contains(owner)) return;
    if (owner.pendingAttachments.length >= 4) {
      throw const JarvisException('每条消息最多4个附件');
    }
    owner.pendingAttachments.add(attachment);
    await save();
    _changed();
  }

  void removeAttachment(String id) {
    current.pendingAttachments.removeWhere((a) => a.id == id);
    scheduleSave();
    _changed();
  }

  Future<List<Map<String, dynamic>>> messagePayload(
    Conversation c, {
    String? instruction,
  }) async {
    final out = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            '你是贾维斯。标为【未完成回复】的历史只是中断片段，不要模仿半句结束；当前回复应完整表达，历史状态标记无需朗读。用户用什么语言交流，就使用同一种语言回答。工具任务回执不是新用户输入，不要因此插话或切换语言。${(instruction ?? settings.instructions).isEmpty ? '' : '\n${instruction ?? settings.instructions}'}',
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
            final bytes = await blobs.get(a.id);
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
          'content': m.text.isEmpty
              ? null
              : m.status == 'complete'
              ? m.text
              : '【未完成回复】\n${m.text}',
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
      task.settleKind();
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

  Future<void> _pollVoiceTask(Conversation owner, MediaTask task) async {
    if (_mediaActive.containsKey(task.id) || task.jobId == null) return;
    final request = 'poll_${_id()}';
    _mediaActive[task.id] = request;
    var failures = 0;
    try {
      while (!_disposed &&
          authenticated &&
          task.pending &&
          _mediaActive[task.id] == request) {
        await Future<void>.delayed(const Duration(seconds: 3));
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
        } catch (_) {
          if (++failures >= 20) {
            task.status = 'interrupted';
            task.error = '暂时无法检查任务，服务器可能仍在运行；请检查原任务';
            break;
          }
          continue;
        }
        if (_mediaActive[task.id] != request || !task.pending) break;
        final status = state['status'];
        task.progress =
            (state['progress'] as num?)?.toDouble() ?? task.progress;
        if (['completed', 'succeeded'].contains(status)) {
          task.urls =
              (state['urls'] as List? ??
                      (state['data'] as List? ?? [])
                          .map((x) => x['url'])
                          .toList())
                  .cast<String>();
          task.settleKind(
            state['kind'] ?? state['job_type'] ?? state['object'],
          );
          task.status = task.urls.isEmpty ? 'failed' : 'completed';
          task.error = task.urls.isEmpty ? '任务未返回作品地址' : null;
          task.progress = 100;
        } else if (['failed', 'cancelled'].contains(status)) {
          task.status = 'failed';
          task.error = '生成失败，请重试原任务';
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
        _voice?.active == true ||
        _voice?.starting == true) {
      return false;
    }
    conversations.clear();
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
        kind: event['kind'] == 'video' ? 'video' : 'image',
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
      task.urls = (event['urls'] as List? ?? []).cast<String>();
      task.settleKind(event['kind'] ?? event['job_type'] ?? event['object']);
      task.error = task.status == 'failed' ? '生成失败，请重试原任务' : null;
    }
    scheduleSave();
    _changed();
  }

  void scheduleSave() {
    if (_disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(save());
    });
  }

  Future<void> save() {
    _saveTimer?.cancel();
    final value = jsonEncode({
      'version': 1,
      'server': api.endpoint.origin,
      'model': model,
      'settings': settings.toJson(),
      'cookie': api.cookie,
      'selectedId': selectedId,
      'effort': effort,
      'theme': theme,
      'themePreferenceVersion': 1,
      'conversations': conversations.map((c) => c.toJson()).toList(),
    });
    _saveTail = _saveTail.then((_) => vault.write(value)).catchError((
      Object _,
    ) {
      storageError = '本机保存失败，请勿清除应用资料';
      _changed();
    });
    return _saveTail;
  }

  @override
  void dispose() {
    _disposed = true;
    pendingWorkNotice.dispose();
    _catalogEpoch++;
    _voiceSettingsTimer?.cancel();
    _voice?.dispose();
    _saveTimer?.cancel();
    api.close();
    _streamRefresh?.cancel();
    super.dispose();
  }
}

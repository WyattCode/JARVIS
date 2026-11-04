import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../model/conversation.dart';
import '../model/media.dart';
import '../model/settings.dart';
import '../net/jarvis_api.dart';
import '../net/realtime_wire.dart';
import 'audio_device.dart';
import 'pcm.dart';
import 'audio_levels.dart';

class _SessionUpdate {
  _SessionUpdate(this.id, this.reasoning, this.speech, this.voice, this.model);
  final String id, voice;
  final String? speech, model;
  final bool reasoning;
  bool matches(Map session) =>
      session['reasoning'] == reasoning &&
      (speech == null || session['speech_model'] == speech) &&
      session['voice'] == voice &&
      (model == null || session['model'] == model);
}

class VoiceSession extends ChangeNotifier {
  VoiceSession({
    required this.api,
    required this.audio,
    required this.settings,
    required this.catalog,
    required this.effort,
    required this.model,
    required this.changed,
    required this.onTask,
    this.refreshCatalog,
    this.isConversationAvailable,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Future<bool> Function()? refreshCatalog;
  final bool Function(Conversation)? isConversationAvailable;
  Conversation? _startingOwner;
  final List<_SessionUpdate> _sessionUpdates = [];
  _SessionUpdate? _latestSessionUpdate, _confirmedSessionUpdate;
  int _updateSerial = 0;
  final DateTime Function() now;
  final JarvisTransport api;
  final AudioDevice audio;
  final ChatSettings Function() settings;
  final List<ModelInfo> Function() catalog;
  final String Function() effort, model;
  final void Function() changed;
  final void Function(Conversation, Map<String, dynamic>) onTask;
  Conversation? owner;
  RealtimeWire? _wire;
  StreamSubscription<String>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _audioEvents;
  Timer? _tail, _reconnect, _handshake;
  int _run = 0, _turn = 0, _retries = 0, _pendingClears = 0, _previewRun = 0;
  bool open = false,
      ready = false,
      held = false,
      muted = false,
      thinking = false,
      speaking = false,
      previewing = false;
  bool _audioBlocked = false;
  bool? _captureEcho;
  bool _captureBusy = false;
  int _audioEpoch = 0, _queuedBytes = 0;
  Future<void> _captureTail = Future.value();
  String? previewVoice;
  bool _wanted = false, _disposed = false, _tailOpen = false;
  String status = '已结束', hint = '', lastYou = '', lastBot = '';
  String? error, _response, _awaitingItem;
  final _items = <String, ChatMessage>{},
      _cancelled = <String>{},
      _cut = <String>{};
  DateTime? _heldAt;
  Future<void> _audioTail = Future.value();
  Future<void> _closing = Future.value(), _previewClosing = Future.value();
  Future<void> _deviceClosing = Future.value();
  bool _starting = false, _stopping = false;
  int capturedPcmBytes = 0, sentPcmBytes = 0, receivedPcmBytes = 0;
  int bufferedFrames = 0, playbackRate = 24000;
  final levels = ValueNotifier(const AudioLevels());
  void _levels({double? input, double? output, bool? playing}) {
    if (_disposed) return;
    final old = levels.value;
    levels.value = AudioLevels(
      input: input ?? old.input,
      output: output ?? old.output,
      playing: playing ?? old.playing,
    );
  }

  void _resetLevels() => _levels(input: 0, output: 0, playing: false);
  String get _readyHint =>
      settings().voiceMode == 'ptt' ? '按住按钮开始说话' : '直接说话即可，停顿后我会回答';
  String get _replyHint =>
      settings().voiceMode == 'ptt' ? '按住按钮可打断回复' : '直接说话即可打断回复';
  void _presentReadyState() {
    if (held) {
      status = '正在聆听';
      hint = '松开发送';
    } else if (_awaitingItem != null) {
      status = '正在识别';
      hint = '正在处理这段语音';
    } else if (speaking) {
      status = '正在说话';
      hint = _replyHint;
    } else if (thinking) {
      status = '正在思考';
      hint = '正在整理回复';
    } else if (replying) {
      status = '正在回复';
      hint = _replyHint;
    } else {
      status = muted ? '已静音' : '已就绪';
      hint = muted ? '点击麦克风恢复聆听' : _readyHint;
    }
  }

  bool get needsRecovery => error != null && !ready;
  void _clearTurnError() {
    // A valid new turn clears retryable errors, never a blocked device/config.
    if (ready && !_audioBlocked) error = null;
  }

  bool get active => _wanted;
  bool get starting => _starting;
  bool ownsConversation(String id) =>
      (_wanted && owner?.id == id) || (_starting && _startingOwner?.id == id);
  bool get reconnecting => _wanted && _retries > 0 && _wire == null && !ready;
  bool get replying => _response != null && !thinking && lastBot.isNotEmpty;
  bool get expressing => !previewing && (speaking || replying);
  bool typed(String text) {
    if (!ready || thinking || _response != null || owner == null) return false;
    _clearTurnError();
    owner!.messages.add(ChatMessage('user', text));
    lastYou = text;
    thinking = true;
    status = '正在思考';
    hint = '正在整理回复';
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
    _send({'type': 'response.create'});
    _changed();
    return true;
  }

  String? get conversationId => owner?.id;
  void _changed() {
    if (!_disposed) {
      notifyListeners();
      changed();
    }
  }

  bool _send(Map<String, dynamic> value) {
    final wire = _wire;
    if (wire == null) return false;
    if (value['type'] == 'input_audio_buffer.clear') _pendingClears++;
    wire.send(jsonEncode(value));
    return true;
  }

  ModelInfo? get speech => catalog()
      .where((m) => m.id == settings().speechModel && m.kind == 'speech')
      .firstOrNull;
  String get voice => settings().voices[settings().speechModel] ?? '';
  Future<void> start(Conversation c) async {
    if (_wanted) {
      open = true;
      _changed();
      return;
    }
    if (_starting || _disposed || isConversationAvailable?.call(c) == false) {
      return;
    }
    _starting = true;
    _startingOwner = c;
    _retries = 0; // A user starts a new call with its own retry budget.
    _changed();
    final before = _run;
    try {
      await _closing;
      await _previewClosing;
      await _deviceClosing;
      if (_disposed || before != _run) return;
      if (previewing || _audioEvents != null) await stopPreview();
      if (_disposed || before != _run) return;
      if (refreshCatalog != null && !await refreshCatalog!()) {
        if (_disposed || before != _run) return;
        error = '无法更新音色配置，请检查网络后重试';
        status = '语音未开启';
        _changed();
        return;
      }
      if (_disposed || before != _run) return;
      if (isConversationAvailable?.call(c) == false) return;
      final speaker = speech;
      if (speaker == null ||
          speaker.voices.isNotEmpty &&
              !speaker.voices.any((v) => v.id == voice)) {
        error = '所选音色不可用，请在设置中重新选择';
        status = '音色未确认';
        _changed();
        return;
      }
      _wanted = true;
      _audioBlocked = false;
      owner = c;
      open = true;
      status = '连接中';
      capturedPcmBytes = 0;
      sentPcmBytes = 0;
      receivedPcmBytes = 0;
      bufferedFrames = 0;
      playbackRate = 24000;
      error = null;
      lastYou = '';
      lastBot = '';
      final run = ++_run;
      _changed();
      try {
        _audioEvents = audio.events.listen(
          _onAudio,
          onError: (Object _) {
            _fail('音频设备连接失败');
          },
        );
        await audio.start(_input, echoCancel: settings().echoCancel);
        _captureEcho = settings().echoCancel;
        if (!_wanted || run != _run) {
          await audio.stop();
          return;
        }
        await _connect(run);
      } catch (e) {
        if (run == _run) {
          await stop();
          error = e is JarvisException ? e.message : '无法开启语音，请检查麦克风权限与网络';
          status = '语音未开启';
          _changed();
        }
      }
    } finally {
      _starting = false;
      _startingOwner = null;
      _changed();
    }
  }

  Future<void> _connect(int run) async {
    ready = false;
    status = _retries > 0 ? '正在重连' : '连接中';
    _changed();
    if (_retries > 0 && refreshCatalog != null && !await refreshCatalog!()) {
      throw StateError('无法更新音色配置');
    }
    if (run != _run || !_wanted || _disposed) return;
    final speaker = speech;
    if (speaker == null ||
        speaker.voices.isNotEmpty &&
            !speaker.voices.any((v) => v.id == voice)) {
      throw StateError('所选音色不可用');
    }
    final wire = await api.openRealtime();
    if (run != _run || !_wanted) {
      await wire.close();
      return;
    }
    _wire = wire;
    _items.clear();
    _cancelled.clear();
    _cut.clear();
    _sessionUpdates.clear();
    _latestSessionUpdate = _confirmedSessionUpdate = null;
    _pendingClears = 0;
    _awaitingItem = null;
    _response = null;
    _subscription = wire.events.listen(
      (raw) {
        if (_wire != wire) return;
        try {
          handle(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        } catch (_) {
          _fail('收到无效的语音事件，文字内容已保留');
        }
      },
      onDone: () => _lost(run, wire),
      onError: (Object _) => _lost(run, wire),
    );
    updateSettings();
    // Seed complete turns only; a tool receipt is a sourced system note, never new user input.
    for (final m
        in owner!.messages
            .where(
              (m) =>
                  ['user', 'assistant'].contains(m.role) &&
                  m.text.isNotEmpty &&
                  m.status != 'generating',
            )
            .toList()
            .reversed
            .take(40)
            .toList()
            .reversed) {
      _send({
        'type': 'conversation.item.create',
        'item': {
          'type': 'message',
          'role': m.role,
          'content': [
            {'type': m.role == 'user' ? 'input_text' : 'text', 'text': m.text},
          ],
        },
      });
    }
  }

  void updateSettings() {
    if (_wanted && (_captureBusy || _captureEcho != settings().echoCancel)) {
      ready = false;
      if (_captureBusy) return;
      _captureBusy = true;
      final run = _run;
      _captureTail = _captureTail
          .then((_) async {
            try {
              while (run == _run &&
                  _wanted &&
                  _captureEcho != settings().echoCancel) {
                final echo = settings().echoCancel;
                await audio.reconfigureInput(_input, echoCancel: echo);
                _captureEcho = echo;
              }
            } finally {
              _captureBusy = false;
            }
            if (run == _run && _wanted) updateSettings();
          })
          .catchError((Object _) {
            if (run == _run && _wanted) {
              _audioBlocked = true;
              ready = false;
              _fail('麦克风配置未能更新，请恢复语音');
            }
          });
      return;
    }
    if (_wire == null) return;
    final s = settings(),
        speaker = speech,
        chat = catalog().where((m) => m.id == model()).firstOrNull;
    final expected = _SessionUpdate(
      'session_${_run}_${++_updateSerial}',
      effort() != 'none',
      speaker?.id,
      voice,
      chat?.metadata['jarvis']?['voice_effort_models']?[effort()] as String? ??
          model(),
    );
    _sessionUpdates.add(expected);
    _latestSessionUpdate = expected;
    _confirmedSessionUpdate = null;
    ready = false;
    error = null;
    status = '正在确认语音配置';
    _send({
      'type': 'session.update',
      'event_id': expected.id,
      'session': {
        'modalities': ['audio', 'text'],
        'input_audio_format': 'pcm16',
        'output_audio_format': 'pcm16',
        'model': expected.model,
        'reasoning': expected.reasoning,
        'voice': voice,
        if (speaker != null) 'speech_model': speaker.id,
        'tool_choice': s.tools ? 'auto' : 'none',
        'max_response_output_tokens': s.maxTokens > 0 ? s.maxTokens : 'inf',
        'instructions':
            '你是贾维斯。用户使用什么语言，就使用同一种语言回答。任务回执不是用户输入，不要主动插话。${s.instructions.isEmpty ? '' : '\n${s.instructions}'}',
        'input_audio_transcription': {
          'language': s.language,
          'prompt': s.transcriptionPrompt,
        },
        'turn_detection': s.voiceMode == 'ptt'
            ? null
            : {
                'type': 'server_vad',
                'threshold': s.threshold,
                'silence_duration_ms': s.waitMs,
                'prefix_padding_ms': 300,
                'create_response': false,
                'interrupt_response': true,
              },
      },
    });
    _handshake?.cancel();
    final run = _run;
    _handshake = Timer(const Duration(seconds: 20), () {
      if (run == _run && !ready) _fail('服务器尚未确认语音配置，请重试连接');
    });
    _changed();
  }

  void _input(Uint8List bytes) {
    if (!_wanted) return;
    capturedPcmBytes += bytes.length;
    if (!ready ||
        muted ||
        previewing ||
        _wire == null ||
        (settings().voiceMode == 'ptt' && !held && !_tailOpen)) {
      if (levels.value.input != 0) _levels(input: 0);
      return;
    }
    _levels(input: pcmRms(bytes));
    sentPcmBytes += bytes.length;
    _send({'type': 'input_audio_buffer.append', 'audio': base64Encode(bytes)});
  }

  void _onAudio(Map<String, dynamic> e) {
    if (e['type'] == 'playback') {
      bufferedFrames = (e['buffered_frames'] as num?)?.toInt() ?? 0;
      playbackRate = (e['sample_rate'] as num?)?.toInt() ?? 24000;
      final active = e['active'] == true;
      final rms = (e['rms'] as num?)?.toDouble() ?? 0;
      _levels(
        output: active && !previewing && rms.isFinite ? rms.clamp(0.0, 1.0) : 0,
        playing: active && !previewing,
      );
      if (active != speaking) {
        speaking = active;
        if (!active && previewing) {
          previewing = false;
          if (_wanted) {
            unawaited(_resetRate());
          } else {
            unawaited(stopPreview());
          }
        }
        if (!held && ready && error == null) _presentReadyState();
        _changed();
      }
    }
    if (e['type'] == 'focus_lost' ||
        e['type'] == 'input_error' ||
        e['type'] == 'output_error') {
      cancelHold();
      muted = true;
      _audioBlocked = true;
      ready = false;
      _handshake?.cancel();
      _previewRun++;
      previewing = false;
      previewVoice = null;
      final interrupted = interrupt();
      _deviceClosing = _deviceClosing
          .catchError((Object _) {})
          .then((_) async {
            await interrupted;
            await audio.stop();
          })
          .catchError((Object _) {
            _fail('音频设备暂停失败，请结束并重新开启通话');
          });
      _fail(
        e['type'] == 'output_error'
            ? '音频播放失败，请恢复语音；文字回复已保留'
            : '语音已暂停，麦克风或音频设备不可用',
      );
    }
    if (e['type'] == 'open_requested') {
      open = true;
      _changed();
    }
    if (e['type'] == 'stop_requested') unawaited(stop());
  }

  Future<void> _resetRate() async {
    if (audio is NativeAudioDevice) {
      await (audio as NativeAudioDevice).voiceRate();
    }
  }

  Future<void> interrupt() async {
    _audioEpoch++;
    if (_response != null) {
      _cancelled.add(_response!);
      _send({'type': 'response.cancel'});
    }
    for (final id in _items.keys) {
      if (_items[id]!.role == 'assistant') {
        _cut.add(id);
        if (_items[id]!.status == 'generating') {
          _items[id]!.status = 'interrupted';
        }
      }
    }
    _response = null;
    thinking = false;
    speaking = false;
    _levels(output: 0, playing: false);
    await audio.flush();
    _changed();
  }

  Future<void> hold() async {
    if (!ready || held || settings().voiceMode != 'ptt' || previewing) return;
    _clearTurnError();
    _tail?.cancel();
    _tailOpen = false;
    _turn++;
    held = true;
    muted = false;
    _heldAt = now();
    _awaitingItem = null;
    status = '正在聆听';
    hint = '松开发送';
    _send({'type': 'input_audio_buffer.clear'});
    unawaited(interrupt());
    _changed();
  }

  void release() {
    if (!held) return;
    held = false;
    hint = '正在处理这段语音';
    _tailOpen = true;
    final turn = _turn, run = _run;
    final length = now().difference(_heldAt ?? now()).inMilliseconds;
    _tail?.cancel();
    _tail = Timer(const Duration(milliseconds: 220), () {
      _tailOpen = false;
      _levels(input: 0);
      if (run != _run || turn != _turn || held || !ready) return;
      if (length < 250) {
        _send({'type': 'input_audio_buffer.clear'});
        status = '已就绪';
        hint = '请按住按钮后说话';
        _changed();
        return;
      }
      _awaitingItem = 'pending';
      _send({
        'type': 'input_audio_buffer.commit',
        'event_id': 'ptt_${run}_$turn',
      });
      thinking = true;
      status = '正在识别';
      _changed();
    });
    _changed();
  }

  void cancelHold() {
    _levels(input: 0);
    _turn++;
    _tail?.cancel();
    _tailOpen = false;
    held = false;
    _awaitingItem = null;
    _send({'type': 'input_audio_buffer.clear'});
    if (ready && !thinking && !speaking) {
      status = muted ? '已静音' : '已就绪';
      hint = muted ? '点击麦克风恢复聆听' : _readyHint;
    }
    _changed();
  }

  void toggleMute() {
    muted = !muted;
    if (muted) cancelHold();
    status = muted ? '已静音' : '已就绪';
    hint = muted ? '点击麦克风恢复聆听' : _readyHint;
    _changed();
  }

  void minimize() {
    if (held) cancelHold();
    open = false;
    _changed();
  }

  void expand() {
    open = true;
    _changed();
  }

  void _fail(String text) {
    error = text;
    hint = text;
    _changed();
  }

  void _settleSessionUpdate(Map? session, {Map? refusal}) {
    final eventId = refusal?['event_id'];
    final index = eventId is String
        ? _sessionUpdates.indexWhere((pending) => pending.id == eventId)
        : 0; // Legacy servers without correlation IDs reply in request order.
    if (index < 0 || index >= _sessionUpdates.length) return;
    final expected = _sessionUpdates.removeAt(index);
    if (identical(expected, _latestSessionUpdate)) {
      ready = false;
      _confirmedSessionUpdate =
          refusal == null && session != null && expected.matches(session)
          ? expected
          : null;
      if (refusal != null) {
        _handshake?.cancel();
        status = '语音配置未确认';
        _fail('所选语音配置未被接受，请重新选择后重试');
        return;
      }
      if (_confirmedSessionUpdate == null && !_audioBlocked && !_captureBusy) {
        _handshake?.cancel();
        _fail('服务器确认的音色或思考配置不一致，请重新选择');
        return;
      }
    }
    if (_sessionUpdates.isNotEmpty ||
        _confirmedSessionUpdate == null ||
        !identical(_confirmedSessionUpdate, _latestSessionUpdate)) {
      return;
    }
    ready = !_audioBlocked && !_captureBusy;
    if (ready) {
      _handshake?.cancel();
      _retries = 0;
      _presentReadyState();
      error = null;
    }
  }

  void handle(Map<String, dynamic> e) {
    final type = e['type'],
        id = e['item_id'] as String?,
        response =
            e['response_id'] as String? ??
            (e['response'] is Map ? e['response']['id'] as String? : null);
    if (response != null && _cancelled.contains(response) ||
        id != null && _cut.contains(id)) {
      return;
    }
    if (_pendingClears > 0 &&
        [
          'input_audio_buffer.speech_started',
          'input_audio_buffer.speech_stopped',
          'input_audio_buffer.committed',
        ].contains(type)) {
      return;
    }
    switch (type) {
      case 'input_audio_buffer.cleared':
        _pendingClears = (_pendingClears - 1).clamp(0, 100);
      case 'session.updated':
        _settleSessionUpdate(e['session'] as Map?);
      case 'input_audio_buffer.speech_started':
        if (settings().voiceMode != 'vad' || muted) break;
        _clearTurnError();
        unawaited(interrupt());
        _awaitingItem = null;
        lastYou = '';
        status = '正在聆听';
        hint = '正在听你说话';
      case 'input_audio_buffer.committed':
        if (settings().voiceMode == 'vad' || _awaitingItem == 'pending') {
          _awaitingItem = id;
        }
      case 'localrouter.transcription.partial':
        if (id == null) break;
        final m = _user(id);
        m.text = e['transcript'] as String? ?? '';
        lastYou = m.text;
      case 'conversation.item.input_audio_transcription.completed':
        if (id == null) break;
        final m = _user(id);
        m.text = (e['transcript'] as String? ?? '').trim();
        m.status = 'complete';
        lastYou = m.text;
        if (_awaitingItem == id &&
            !held &&
            !muted &&
            !previewing &&
            ready &&
            m.text.isNotEmpty) {
          _clearTurnError();
          _awaitingItem = null;
          thinking = true;
          status = '正在思考';
          hint = '正在整理回复';
          _send({'type': 'response.create'});
        } else if (_awaitingItem == id) {
          _awaitingItem = null;
          thinking = false;
          status = '没有听清';
          _fail('没有识别到有效语音，请再说一次');
        }
      case 'conversation.item.input_audio_transcription.failed':
        if (_awaitingItem == id) {
          _awaitingItem = null;
          thinking = false;
          status = '没有听清';
          _fail('这次语音识别失败，请重新说一次');
        }
      case 'response.created':
        _clearTurnError();
        _response = e['response']?['id'] as String?;
        lastBot = '';
        thinking = true;
        status = '正在思考';
        hint = '正在整理回复';
      case 'response.text.delta':
      case 'response.audio_transcript.delta':
        if (id == null) break;
        final m = _bot(id);
        m.text += e['delta'] as String? ?? '';
        lastBot = m.text;
        thinking = false;
        status = speaking ? '正在说话' : '正在回复';
        hint = _replyHint;
      case 'response.audio.delta':
        if (id == null) break;
        _bot(id);
        final data = base64Decode(e['delta'] as String? ?? '');
        receivedPcmBytes += data.length;
        final run = _run, epoch = _audioEpoch;
        if (_queuedBytes + data.length > 1440000) {
          unawaited(interrupt());
          _fail('语音播放积压，已停止当前语音；文字回复已保留');
          break;
        }
        _queuedBytes += data.length;
        _audioTail = _audioTail
            .then((_) async {
              try {
                if (run == _run &&
                    epoch == _audioEpoch &&
                    _wire != null &&
                    !_cut.contains(id) &&
                    !(response != null && _cancelled.contains(response))) {
                  await audio.feed(data);
                }
              } finally {
                _queuedBytes -= data.length;
              }
            })
            .catchError((Object _) {
              _fail('语音播放失败，文字回复已保留');
            });
      case 'localrouter.response.speech_done':
      case 'response.audio.done':
        final run = _run, epoch = _audioEpoch;
        _audioTail = _audioTail
            .then((_) async {
              if (run == _run &&
                  epoch == _audioEpoch &&
                  _wanted &&
                  !(response != null && _cancelled.contains(response))) {
                await audio.finish();
              }
            })
            .catchError((Object _) {
              _fail('语音播放失败，文字回复已保留');
            });
      case 'response.output_item.done':
        final item = e['item'] as Map?;
        if (item?['type'] == 'function_call') {
          onTask(owner!, {'type': 'call', ...Map<String, dynamic>.from(item!)});
        }
      case 'localrouter.job.created':
      case 'localrouter.job.done':
        onTask(owner!, e);
      case 'response.done':
        thinking = false;
        _response = null;
        final result = e['response'] as Map? ?? {};
        for (final item in result['output'] as List? ?? []) {
          final m = _items[item['id']];
          if (m == null) continue;
          m.status = result['status'] == 'completed'
              ? 'complete'
              : result['status'] == 'incomplete'
              ? 'length'
              : 'interrupted';
        }
        status = speaking
            ? '正在说话'
            : muted
            ? '已静音'
            : '已就绪';
        hint = speaking
            ? _replyHint
            : muted
            ? '点击麦克风恢复聆听'
            : _readyHint;
      case 'error':
        final error = e['error'] as Map? ?? {};
        if (error['code'] == 'invalid_session') {
          _settleSessionUpdate(null, refusal: error);
          break;
        }
        thinking = false;
        _fail(
          error['code'] == 'speech_failed'
              ? '语音生成失败，文字回复仍可查看'
              : '语音服务返回错误，请重试当前操作',
        );
      case 'localrouter.voice.paused':
        ready = false;
        status = '语音暂时暂停';
        hint = '模型任务结束后恢复';
      case 'localrouter.voice.resumed':
        updateSettings();
    }
    _changed();
  }

  ChatMessage _user(String id) => _items.putIfAbsent(id, () {
    final m = ChatMessage('user', '', status: 'generating');
    owner!.messages.add(m);
    return m;
  });
  ChatMessage _bot(String id) => _items.putIfAbsent(id, () {
    final m = ChatMessage('assistant', '', status: 'generating');
    owner!.messages.add(m);
    return m;
  });
  Future<void> _lost(int run, RealtimeWire wire) async {
    if (_wire != wire || run != _run || !_wanted) return;
    _wire = null;
    _resetLevels();
    _audioEpoch++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(wire.close());
    ready = false;
    held = false;
    thinking = false;
    speaking = false;
    _response = null;
    _tail?.cancel();
    _tailOpen = false;
    _awaitingItem = null;
    _handshake?.cancel();
    // Mark only the lost connection's items before awaiting device I/O.
    for (final m in _items.values) {
      if (m.status == 'generating') m.status = 'interrupted';
    }
    status = '正在重连';
    hint = '连接中断，正在自动重连';
    _changed();
    try {
      await audio.flush();
    } catch (_) {
      if (run == _run && _wanted && !_disposed) {
        _audioBlocked = true;
        _fail('音频设备暂时无法重置，请恢复语音后继续');
      }
      return;
    }
    // stop()/a new call can finish while the old device flush is pending.
    if (run != _run || !_wanted || _disposed) return;
    if (++_retries > 8) {
      await stop();
      _fail('语音连接未能恢复，已保留对话');
      return;
    }
    status = '正在重连';
    _changed();
    _reconnect?.cancel();
    _reconnect = Timer(
      Duration(seconds: (1 << (_retries - 1)).clamp(1, 15)),
      () async {
        if (run != _run || !_wanted) return;
        try {
          await _connect(run);
        } catch (_) {
          if (run == _run && _wanted) {
            _wire = wire;
            unawaited(_lost(run, wire));
          }
        }
      },
    );
  }

  Future<void> playPreview(VoiceInfo voice, String engine) async {
    final preview = ++_previewRun;
    await _closing;
    await _previewClosing;
    if (preview != _previewRun || _disposed || _starting) return;
    cancelHold();
    previewing = true;
    previewVoice = voice.id;
    await interrupt();
    if (preview != _previewRun) return;
    _audioEvents ??= audio.events.listen(
      _onAudio,
      onError: (Object _) {
        _fail('试听音频设备不可用');
      },
    );
    previewing = true;
    previewVoice = voice.id;
    _changed();
    try {
      final clip = PcmClip.wav(await api.preview(voice, engine));
      if (preview != _previewRun || !previewing) return;
      await audio.preview(clip);
      if (preview != _previewRun) return;
      speaking = true;
      _changed();
    } catch (_) {
      if (preview == _previewRun) {
        previewing = false;
        _fail('试听暂时不可用，请重试；已选音色保持不变');
      }
    }
  }

  Future<void> stopPreview() {
    _previewRun++;
    previewing = false;
    previewVoice = null;
    _previewClosing = _previewClosing.catchError((Object _) {}).then((_) async {
      await audio.flush();
      if (_wanted) {
        await _resetRate();
      } else {
        await audio.stop();
        await _audioEvents?.cancel();
        _audioEvents = null;
      }
      _changed();
    });
    return _previewClosing;
  }

  Future<void> stop() {
    _resetLevels();
    if (_stopping) return _closing;
    _stopping = true;
    _closing = _stop().whenComplete(() {
      _stopping = false;
    });
    return _closing;
  }

  Future<void> _stop() async {
    _wanted = false;
    _sessionUpdates.clear();
    _latestSessionUpdate = _confirmedSessionUpdate = null;
    _audioEpoch++;
    _previewRun++;
    _run++;
    _turn++;
    _tail?.cancel();
    _handshake?.cancel();
    _reconnect?.cancel();
    ready = false;
    held = false;
    open = false;
    _tailOpen = false;
    final wire = _wire;
    _wire = null;
    await _subscription?.cancel();
    _subscription = null;
    await wire?.close();
    await _audioEvents?.cancel();
    _audioEvents = null;
    try {
      await _previewClosing;
      await _deviceClosing;
      await _captureTail;
      await audio.stop();
    } catch (_) {}
    for (final m in _items.values) {
      if (m.status == 'generating') m.status = 'interrupted';
    }
    thinking = false;
    speaking = false;
    previewing = false;
    status = '已结束';
    hint = '';
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    levels.dispose();
    unawaited(stop().then((_) => audio.dispose()));
    super.dispose();
  }
}

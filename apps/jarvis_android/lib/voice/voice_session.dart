import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/conversation.dart';
import '../model/media.dart';
import '../model/settings.dart';
import '../net/jarvis_api.dart';
import '../net/realtime_wire.dart';
import 'audio_device.dart';
import 'pcm.dart';
import 'audio_levels.dart';

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
    this.onUnauthorized,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final JarvisTransport api;
  final AudioDevice audio;
  final ChatSettings Function() settings;
  final List<ModelInfo> Function() catalog;
  final String Function() effort, model;
  final void Function() changed;
  final void Function(Conversation, Map<String, dynamic>) onTask;

  /// The service refused the realtime handshake as unauthorized: the owner expires the session.
  final void Function()? onUnauthorized;
  Conversation? owner;
  RealtimeWire? _wire;
  StreamSubscription<String>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _audioEvents;
  Timer? _tail, _reconnect, _handshake, _turnTimer;

  /// How long a committed recording or a sent message may wait for the server to react at all, and how long a started
  /// reply may stay silent (reasoning models think for a while before the first word).
  @visibleForTesting
  Duration turnTimeout = const Duration(seconds: 30),
      replyTimeout = const Duration(seconds: 120);
  int _run = 0,
      _turn = 0,
      _pendingUpdates = 0,
      _retries = 0,
      _pendingClears = 0,
      _previewRun = 0;
  bool open = false,
      ready = false,
      held = false,
      muted = false,
      thinking = false,
      speaking = false,
      previewing = false;

  /// A preview was asked for but its first audio is not queued yet (the clip is still downloading).
  bool previewLoading = false;

  /// Why the last voice preview failed. Kept apart from [error], which belongs to the call; cleared by the next preview,
  /// by stopping it, and when the voice or engine changes.
  String? previewError;
  bool _audioBlocked = false;

  /// The microphone permission was refused (or restricted); the call page stays closed so the UI can offer the settings.
  bool permissionDenied = false;
  bool? _captureEcho;
  bool _captureBusy = false;
  int _audioEpoch = 0, _queuedBytes = 0;
  Future<void> _captureTail = Future.value();
  String? previewVoice;
  bool _wanted = false, _disposed = false, _tailOpen = false;
  int _hangups = 0;
  String status = '已结束', hint = '', lastYou = '', lastBot = '';
  String? error,
      _response,
      _awaitingItem,
      _expectedVoice,
      _expectedSpeech,
      _expectedModel;
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

  /// Mute only exists in hands-free mode; in push-to-talk the button is the switch and there is nothing to unmute.
  bool get mutedInVad => muted && settings().voiceMode == 'vad';
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
      status = mutedInVad ? '已静音' : '已就绪';
      hint = mutedInVad ? '点击麦克风恢复聆听' : _readyHint;
    }
  }

  bool get needsRecovery => error != null && !ready;
  void _clearTurnError() {
    // A valid new turn clears retryable errors, never a blocked device/config.
    if (ready && !_audioBlocked) error = null;
  }

  bool get active => _wanted;

  /// A call is being set up (the microphone permission may still be asked): not [active] yet, but its voice is final.
  bool get starting => _starting;
  bool get replying => _response != null && !thinking && lastBot.isNotEmpty;
  bool get expressing => !previewing && (speaking || replying);
  bool typed(String text) {
    if (!ready || thinking || _response != null || owner == null) return false;
    // Send first: if the connection is gone the draft stays in the composer and nothing is shown as sent.
    final sent =
        _send({
          'type': 'conversation.item.create',
          'item': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': text},
            ],
          },
        }) &&
        _send({'type': 'response.create'});
    if (!sent) return false;
    _clearTurnError();
    owner!.messages.add(ChatMessage('user', text));
    lastYou = text;
    thinking = true;
    status = '正在思考';
    hint = '正在整理回复';
    _syncTurnTimer();
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
    try {
      wire.send(jsonEncode(value));
    } catch (_) {
      // A socket that closed under us throws instead of reporting through the stream.
      unawaited(_lost(_run, wire));
      return false;
    }
    if (value['type'] == 'input_audio_buffer.clear') _pendingClears++;
    return true;
  }

  ModelInfo? get speech => catalog()
      .where((m) => m.id == settings().speechModel && m.kind == 'speech')
      .firstOrNull;
  String get voice => settings().voices[settings().speechModel] ?? '';
  Future<void> start(Conversation c) => _begin(c, recovering: false);

  /// Restarts the call after an error. The call page stays open throughout (unlike [stop] followed by [start], which
  /// closes it and leaves it closed when the restart fails), so a refused permission or an unavailable voice shows up
  /// on the page as [error] / [permissionDenied] instead of the page silently disappearing. True when the call is up.
  Future<bool> recover() async {
    final c = owner;
    if (c == null || _disposed) return false;
    final hangups = _hangups;
    open = true;
    await _stopCall(keepOpen: true);
    // Hanging up while this was restarting wins.
    if (_hangups != hangups || _disposed) return false;
    await _begin(c, recovering: true);
    return _wanted;
  }

  Future<void> _begin(Conversation c, {required bool recovering}) async {
    if (_wanted) {
      open = true;
      _changed();
      return;
    }
    if (_starting || _disposed) return;
    _starting = true;
    final before = _run;
    try {
      await _closing;
      await _previewClosing;
      await _deviceClosing;
      if (_disposed || before != _run) return;
      if (previewing || _audioEvents != null) await stopPreview();
      if (_disposed || before != _run) return;
      final speaker = speech;
      if (speaker == null ||
          speaker.voices.isNotEmpty &&
              !speaker.voices.any((v) => v.id == voice)) {
        error = '所选音色不可用，请在设置中重新选择';
        status = '音色未确认';
        if (recovering) open = true;
        _changed();
        return;
      }
      // Ask before the call page opens, so a refusal does not make it slide in and straight back out.
      permissionDenied = false;
      final granted = await audio.microphonePermission();
      if (_disposed || before != _run) return;
      if (!granted) {
        permissionDenied = true;
        error = '需要麦克风权限才能语音通话，请在系统设置中允许';
        status = '语音未开启';
        if (recovering) open = true;
        _changed();
        return;
      }
      _wanted = true;
      muted = false;
      _audioBlocked = false;
      _retries = 0;
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
          await _stopCall(keepOpen: recovering);
          permissionDenied = e is PlatformException && e.code == 'mic_denied';
          error = e is JarvisException
              ? e.message
              : e is PlatformException && e.code == 'no_input'
              ? e.message ?? '未检测到可用的麦克风'
              : '无法开启语音，请检查麦克风权限与网络';
          status = '语音未开启';
          _changed();
          if (e is JarvisException && e.unauthorized) onUnauthorized?.call();
        }
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _connect(int run) async {
    ready = false;
    status = _retries > 0 ? '正在重连' : '连接中';
    _changed();
    final wire = await api.openRealtime();
    if (run != _run || !_wanted) {
      await wire.close();
      return;
    }
    try {
      _attach(run, wire);
    } catch (_) {
      // Nobody owns this socket yet if setup failed: close it instead of leaking it.
      if (_wire == wire) _wire = null;
      await _subscription?.cancel();
      _subscription = null;
      await wire.close();
      rethrow;
    }
  }

  void _attach(int run, RealtimeWire wire) {
    _wire = wire;
    _items.clear();
    _cancelled.clear();
    _cut.clear();
    _pendingUpdates = 0;
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
    // Mute belongs to hands-free mode; switching to push-to-talk must not carry it over.
    if (muted && settings().voiceMode != 'vad') muted = false;
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
    _expectedSpeech = speaker?.id;
    _expectedVoice = voice;
    _expectedModel =
        chat?.metadata['jarvis']?['voice_effort_models']?[effort()] as String?;
    _pendingUpdates++;
    ready = false;
    error = null;
    status = '正在确认语音配置';
    _send({
      'type': 'session.update',
      'session': {
        'modalities': ['audio', 'text'],
        'input_audio_format': 'pcm16',
        'output_audio_format': 'pcm16',
        'model': _expectedModel ?? model(),
        'reasoning': effort() != 'none',
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
          previewLoading = false;
          if (_wanted) {
            _resetRate().ignore();
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
      // The input is blocked until the call is recovered; only hands-free mode shows that as "muted".
      muted = settings().voiceMode == 'vad';
      _audioBlocked = true;
      ready = false;
      _handshake?.cancel();
      _previewRun++;
      previewing = false;
      previewLoading = false;
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
    _syncTurnTimer();
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
      _syncTurnTimer();
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
      status = mutedInVad ? '已静音' : '已就绪';
      hint = mutedInVad ? '点击麦克风恢复聆听' : _readyHint;
    }
    _syncTurnTimer();
    _changed();
  }

  void toggleMute() {
    muted = !muted;
    if (muted) cancelHold();
    // Through the same path as everything else, so a reply in progress keeps its own status.
    _presentReadyState();
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
        _pendingUpdates = (_pendingUpdates - 1).clamp(0, 100);
        final s = e['session'] as Map? ?? {};
        ready =
            !_audioBlocked &&
            !_captureBusy &&
            _pendingUpdates == 0 &&
            s['reasoning'] == (effort() != 'none') &&
            (_expectedSpeech == null ||
                s['speech_model'] == _expectedSpeech &&
                    s['voice'] == _expectedVoice) &&
            (_expectedModel == null || s['model'] == _expectedModel);
        if (ready) {
          _handshake?.cancel();
          _retries = 0;
          _presentReadyState();
          error = null;
        } else if (_pendingUpdates == 0 && !_audioBlocked && !_captureBusy) {
          _fail('服务器确认的音色或思考配置不一致，请重新选择');
        }
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
            : mutedInVad
            ? '已静音'
            : '已就绪';
        hint = speaking
            ? _replyHint
            : mutedInVad
            ? '点击麦克风恢复聆听'
            : _readyHint;
      case 'error':
        thinking = false;
        final error = e['error'] as Map? ?? {};
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
    // Any word from the server proves it is alive; the wait for the next one starts over.
    _syncTurnTimer(restart: _turnTimer != null);
    _changed();
  }

  /// A recording or message has gone out and nothing came back: don't leave "recognising / thinking" up forever.
  void _syncTurnTimer({bool restart = false}) {
    final waiting = _wanted && ready && (_awaitingItem != null || thinking);
    if (!waiting) {
      _turnTimer?.cancel();
      _turnTimer = null;
      return;
    }
    if (_turnTimer != null && !restart) return;
    _turnTimer?.cancel();
    final run = _run;
    _turnTimer = Timer(_response != null ? replyTimeout : turnTimeout, () {
      _turnTimer = null;
      if (run != _run || !_wanted) return;
      _awaitingItem = null;
      thinking = false;
      unawaited(interrupt());
      status = '没有收到回复';
      _fail('服务器长时间没有回应，请再说一次或重试');
    });
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
    _syncTurnTimer();
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
      await _stopCall();
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
        } catch (e) {
          if (run != _run || !_wanted) return;
          if (e is JarvisException && e.unauthorized) {
            // Retrying with a session the service rejected only repeats the refusal.
            await _stopCall();
            _fail('登录已过期，请重新登录');
            onUnauthorized?.call();
            return;
          }
          _wire = wire;
          unawaited(_lost(run, wire));
        }
      },
    );
  }

  Future<void> playPreview(VoiceInfo voice, String engine) async {
    final preview = ++_previewRun;
    previewLoading = true;
    _changed();
    try {
      await _closing;
      await _previewClosing;
      if (preview != _previewRun || _disposed || _starting) return;
      cancelHold();
      previewError = null;
      // An earlier failure belongs to the earlier attempt; a live call keeps its own error.
      if (!_wanted) error = null;
      previewing = true;
      previewVoice = voice.id;
      await interrupt();
      if (preview != _previewRun) return;
      _audioEvents ??= audio.events.listen(
        _onAudio,
        onError: (Object _) {
          if (_wanted) {
            _fail('试听音频设备不可用');
          } else {
            previewError = '试听音频设备不可用';
            _changed();
          }
        },
      );
      previewing = true;
      previewVoice = voice.id;
      _changed();
      try {
        // The server's clip is played as it is, but one this app cannot decode (not 16-bit mono WAV) is replaced by the
        // voice speaking the same sentence, rather than failing the try-out.
        final bytes = await api.preview(voice, engine);
        PcmClip clip;
        try {
          clip = PcmClip.wav(bytes);
        } on FormatException {
          if (voice.preview == null) rethrow;
          clip = PcmClip.wav(await api.synthesize(voice, engine));
        }
        if (preview != _previewRun || !previewing) return;
        await audio.preview(clip);
        if (preview != _previewRun) return;
        previewLoading = false;
        speaking = true;
        _changed();
      } catch (_) {
        if (preview == _previewRun) {
          previewing = false;
          previewLoading = false;
          // Not [error]: that one belongs to the call and would show up on the call page.
          previewError = '试听暂时不可用，请重试；已选音色保持不变';
          _changed();
        }
      }
    } finally {
      // Whatever ended this attempt (a guard, a stop, a failure) the spinner must not outlive it; a newer attempt owns
      // the flag once it has bumped [_previewRun].
      if (preview == _previewRun && previewLoading) {
        previewLoading = false;
        _changed();
      }
    }
  }

  /// Drops an error that no longer applies, e.g. after the speech engine or voice changed. A live call keeps its own.
  void clearIdleError() {
    if (previewError != null) {
      previewError = null;
      _changed();
    }
    if (_wanted || error == null) return;
    error = null;
    hint = '';
    status = '已结束';
    _changed();
  }

  Future<void> stopPreview() {
    _previewRun++;
    previewError = null;
    previewing = false;
    previewLoading = false;
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
    // Most callers do not wait for it: a failing flush or stop must not surface as an unhandled error (callers that do
    // wait still see it).
    _previewClosing.ignore();
    return _previewClosing;
  }

  Future<void> stop() {
    _hangups++;
    // A hang-up that joins a restart already in progress turns it into a plain stop.
    _keepOpen = false;
    open = false;
    return _stopCall();
  }

  bool _keepOpen = false;
  Future<void> _stopCall({bool keepOpen = false}) {
    _resetLevels();
    if (_stopping) return _closing;
    _stopping = true;
    _keepOpen = keepOpen;
    _closing = _stop().whenComplete(() {
      _stopping = false;
    });
    return _closing;
  }

  Future<void> _stop() async {
    _wanted = false;
    _retries = 0;
    _audioEpoch++;
    _previewRun++;
    _run++;
    _turn++;
    _tail?.cancel();
    _handshake?.cancel();
    _reconnect?.cancel();
    ready = false;
    held = false;
    if (!_keepOpen) open = false;
    _tailOpen = false;
    _syncTurnTimer();
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
    previewLoading = false;
    status = _keepOpen ? '连接中' : '已结束';
    hint = '';
    _changed();
  }

  @override
  void dispose() {
    _turnTimer?.cancel();
    _disposed = true;
    levels.dispose();
    unawaited(stop().then((_) => audio.dispose()));
    super.dispose();
  }
}

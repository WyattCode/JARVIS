import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'pcm.dart';

abstract class AudioDevice {
  Stream<Map<String, dynamic>> get events;
  Future<void> start(
    void Function(Uint8List) input, {
    required bool echoCancel,
  });
  Future<void> feed(Uint8List pcm);
  Future<void> flush();
  Future<void> finish();
  Future<void> preview(PcmClip clip);
  Future<void> stop();
  Future<void> reconfigureInput(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async {}
  Future<void> dispose() => stop();
}

class NativeAudioDevice extends AudioDevice {
  static const _method = MethodChannel('cc.odn.jarvis/audio');
  static const _events = EventChannel('cc.odn.jarvis/audio-events');
  AudioRecorder? _recorder;
  AudioRecorder get recorder => _recorder ??= AudioRecorder();
  bool _configured = false;
  StreamSubscription<Uint8List>? _capture;
  Future<void> _output = Future.value();
  final _warm = BytesBuilder();
  int _epoch = 0;
  bool _warming = true;
  @override
  Stream<Map<String, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map))
      .where((e) => e['epoch'] == null || e['epoch'] == _epoch);
  @override
  Future<void> start(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async {
    if (!await recorder.hasPermission()) {
      throw PlatformException(code: 'mic_denied', message: '请允许麦克风权限后再开启语音');
    }
    _configured = true;
    await _method.invokeMethod('start', {'rate': 24000, 'epoch': ++_epoch});
    try {
      await reconfigureInput(input, echoCancel: echoCancel);
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> reconfigureInput(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async {
    await _capture?.cancel();
    _capture = null;
    if (await recorder.isRecording()) await recorder.stop();
    // iOS: the native bridge owns the shared AVAudioSession (playAndRecord + voiceChat).
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await recorder.ios?.manageAudioSession(false);
    }
    final stream = await recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 24000,
        numChannels: 1,
        echoCancel: echoCancel,
        noiseSuppress: true,
        autoGain: false,
        // The native duplex session owns audio focus for BOTH recording and playback.
        audioInterruption: AudioInterruptionMode.none,
        streamBufferSize: 1920,
        androidConfig: const AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
          audioManagerMode: AudioManagerMode.modeInCommunication,
          speakerphone: true,
        ),
      ),
    );
    _capture = stream.listen(
      input,
      onError: (Object e) {
        _method.invokeMethod('inputError');
      },
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _recorder?.dispose();
    _recorder = null;
  }

  @override
  Future<void> feed(Uint8List pcm) async {
    if (pcm.length.isOdd) throw const FormatException('PCM数据不完整');
    _warm.add(pcm);
    if (_warming && _warm.length < 8640) return;
    _warming = false;
    final bytes = _warm.takeBytes(), epoch = _epoch;
    final pending = _output.then((_) async {
      if (epoch == _epoch) {
        await _method.invokeMethod('feed', {'epoch': epoch, 'bytes': bytes});
      }
    });
    // Report this write's failure to its caller, while leaving the serialization
    // tail usable. Otherwise one platform error prevents every subsequent feed
    // from even reaching the native player, including audio in a later call.
    _output = pending.catchError((Object _) {});
    await pending;
  }

  @override
  Future<void> finish() async {
    if (_warm.isNotEmpty) {
      _warming = false;
      await feed(Uint8List(0));
    }
    await _output;
  }

  @override
  Future<void> flush() async {
    _epoch++;
    _warm.clear();
    _warming = true;
    _output = Future.value();
    await _method.invokeMethod('clear', {'epoch': _epoch});
  }

  @override
  Future<void> preview(PcmClip clip) async {
    await flush();
    _configured = true;
    await _method.invokeMethod('configureOutput', {
      'rate': clip.rate,
      'epoch': _epoch,
    });
    await _method.invokeMethod('feed', {'epoch': _epoch, 'bytes': clip.bytes});
  }

  Future<void> voiceRate() async {
    await flush();
    _configured = true;
    await _method.invokeMethod('configureOutput', {
      'rate': 24000,
      'epoch': _epoch,
    });
  }

  @override
  Future<void> stop() async {
    _epoch++;
    _warm.clear();
    _warming = true;
    _output = Future.value();
    await _capture?.cancel();
    _capture = null;
    try {
      if (_recorder != null) await recorder.stop();
    } finally {
      if (_configured) await _method.invokeMethod('stop');
      _configured = false;
    }
  }
}

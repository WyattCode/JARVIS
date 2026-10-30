import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';
import 'voice_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Starting voice with no usable microphone', () {
    Future<String?> startError(Object failure) async {
      final c = JarvisController(
        FakeApi(),
        MemoryVault(),
        audioDevice: FailingStartAudio(failure),
      );
      await c.initialize();
      addTearDown(c.dispose);
      c.models.add(
        ModelInfo(
          'speech',
          'Speech',
          kind: 'speech',
          voices: const [VoiceInfo('Mae', 'Mae', '')],
        ),
      );
      c.settings.speechModel = 'speech';
      c.settings.voices['speech'] = 'Mae';
      await c.voice.start(c.current);
      expect(c.voice.active, isFalse);
      return c.voice.error;
    }

    test('shows the real reason', () async {
      final error = await startError(
        PlatformException(
          code: 'no_input',
          message: '未检测到可用的麦克风，请检查音频输入后再开启语音',
        ),
      );
      expect(error, contains('未检测到可用的麦克风'));
    });

    test('other failures keep the existing generic message', () async {
      expect(
        await startError(PlatformException(code: 'mic_denied', message: 'x')),
        '无法开启语音，请检查麦克风权限与网络',
      );
    });
  });
}

class FailingStartAudio extends FakeAudio {
  FailingStartAudio(this.failure);
  final Object failure;
  @override
  Future<void> start(
    void Function(Uint8List) input, {
    required bool echoCancel,
  }) async => throw failure;
}

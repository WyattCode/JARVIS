import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/voice/pcm.dart';

import 'voice_support.dart';

void main() {
  test(
    'Preview cancels a pending utterance and cannot trigger a new response',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.settings.voiceMode = 'vad';
      h.event({'type': 'input_audio_buffer.committed', 'item_id': 'old-input'});
      final preview = h.session.playPreview(
        const VoiceInfo('Mae', 'Mae', ''),
        'speech',
      );
      await Future<void>.delayed(Duration.zero);
      h.event({'type': 'input_audio_buffer.cleared'});
      h.event({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'old-input',
        'transcript': '旧录音',
      });
      expect(h.wire.sent.where((e) => e['type'] == 'response.create'), isEmpty);
      h.api.previews['Mae']!.complete(wavBytes());
      await preview;
      await h.close();
    },
  );
  test('Starting a call waits for the prior preview device to close', () async {
    final h = VoiceHarness();
    final preview = h.session.playPreview(
      const VoiceInfo('Mae', 'Mae', ''),
      'speech',
    );
    await Future<void>.delayed(Duration.zero);
    h.api.previews['Mae']!.complete(wavBytes());
    await preview;
    h.audio.stopBarrier = Completer<void>();
    final stopping = h.session.stopPreview();
    final starting = h.session.start(h.owner);
    await Future<void>.delayed(Duration.zero);
    expect(h.audio.starts, 0);
    h.audio.stopBarrier!.complete();
    await stopping;
    await starting;
    expect(h.audio.starts, 1);
    expect(h.session.previewing, false);
    h.audio.stopBarrier = null;
    await h.close();
  });

  test(
    'Stopping an interrupted response cannot flush old audio into a new turn',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r1'},
      });
      h.event({
        'type': 'response.audio.delta',
        'item_id': 'i1',
        'response_id': 'r1',
        'delta': base64Encode(Uint8List(480)),
      });
      h.event({
        'type': 'localrouter.response.speech_done',
        'response_id': 'r1',
      });
      await h.session.interrupt();
      await Future<void>.delayed(Duration.zero);
      expect(h.audio.fed, isEmpty);
      expect(h.audio.finishes, 0);
      await h.close();
    },
  );
  test('Changing echo cancellation reconfigures capture before the next server acknowledgement', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.settings.echoCancel = false;
    h.session.updateSettings();
    expect(h.session.ready, false);
    await Future<void>.delayed(Duration.zero);
    expect(h.audio.reconfigures, 1);
    expect(h.audio.echo, false);
    h.ack();
    expect(h.session.ready, true);
    await h.close();
  });

  test(
    'No microphone packet can leave before exact voice/model acknowledgement',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.audio.input!(Uint8List(1920));
      expect(h.session.capturedPcmBytes, 1920);
      expect(h.session.sentPcmBytes, 0);
      expect(
        h.wire.sent.where((e) => e['type'] == 'input_audio_buffer.append'),
        isEmpty,
      );
      h.ack(voice: 'Mae');
      expect(h.session.ready, false);
      expect(h.session.error, contains('不一致'));
      expect(h.settings.voices['speech'], 'Atlas');
      h.session.updateSettings();
      h.ack();
      expect(h.session.ready, true);
      expect(h.settings.voices['speech'], 'Atlas');
      await h.close();
    },
  );
  test(
    'PTT commit waits for the matching nonempty transcript and responds once',
    () {
      fakeAsync((clock) {
        final h = VoiceHarness();
        h.session.start(h.owner);
        clock.flushMicrotasks();
        h.ack();
        h.session.hold();
        clock.flushMicrotasks();
        h.event({'type': 'input_audio_buffer.cleared'});
        h.audio.input!(Uint8List(1920));
        expect(
          h.wire.sent.any((e) => e['type'] == 'input_audio_buffer.append'),
          true,
        );
        h.time = h.time.add(const Duration(milliseconds: 400));
        h.session.release();
        clock.elapse(const Duration(milliseconds: 230));
        clock.flushMicrotasks();
        expect(
          h.wire.sent
              .where((e) => e['type'] == 'input_audio_buffer.commit')
              .length,
          1,
        );
        h.event({'type': 'input_audio_buffer.committed', 'item_id': 'u1'});
        h.event({
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': 'u1',
          'transcript': '你好',
        });
        h.event({
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': 'u1',
          'transcript': '你好',
        });
        expect(
          h.wire.sent.where((e) => e['type'] == 'response.create').length,
          1,
        );
        expect(h.owner.messages.single.text, '你好');
        h.close();
        clock.flushMicrotasks();
      });
    },
  );
  test(
    'Cancelled or short holds never commit or trigger an old transcript',
    () {
      fakeAsync((clock) {
        final h = VoiceHarness();
        h.session.start(h.owner);
        clock.flushMicrotasks();
        h.ack();
        h.session.hold();
        clock.flushMicrotasks();
        h.session.cancelHold();
        clock.elapse(const Duration(seconds: 1));
        h.event({'type': 'input_audio_buffer.cleared'});
        h.event({'type': 'input_audio_buffer.cleared'});
        h.event({
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': 'old',
          'transcript': '旧语音',
        });
        expect(
          h.wire.sent.where(
            (e) =>
                e['type'] == 'input_audio_buffer.commit' ||
                e['type'] == 'response.create',
          ),
          isEmpty,
        );
        h.session.hold();
        clock.flushMicrotasks();
        h.session.release();
        clock.elapse(const Duration(milliseconds: 230));
        expect(
          h.wire.sent.where((e) => e['type'] == 'input_audio_buffer.commit'),
          isEmpty,
        );
        h.close();
        clock.flushMicrotasks();
      });
    },
  );
  test('Late cancelled PCM cannot play and a short response forces final buffer flush', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.event({
      'type': 'response.created',
      'response': {'id': 'r1'},
    });
    h.event({
      'type': 'response.text.delta',
      'item_id': 'a1',
      'response_id': 'r1',
      'delta': '已保留文字',
    });
    await h.session.interrupt();
    h.event({
      'type': 'response.audio.delta',
      'item_id': 'a1',
      'response_id': 'r1',
      'delta': base64Encode(Uint8List(100)),
    });
    await Future<void>.delayed(Duration.zero);
    expect(h.audio.fed, isEmpty);
    h.event({
      'type': 'response.created',
      'response': {'id': 'r2'},
    });
    h.event({
      'type': 'response.audio.delta',
      'item_id': 'a2',
      'response_id': 'r2',
      'delta': base64Encode(Uint8List(100)),
    });
    h.event({'type': 'localrouter.response.speech_done', 'item_id': 'a2'});
    await Future<void>.delayed(Duration.zero);
    expect(h.audio.fed.single.length, 100);
    expect(h.audio.finishes, 1);
    await h.close();
  });
  test(
    'Latest preview wins, stopping cannot start a pending preview',
    () async {
      final h = VoiceHarness();
      final a = h.session.playPreview(
        const VoiceInfo('Atlas', 'Atlas', ''),
        'speech',
      );
      await Future<void>.delayed(Duration.zero);
      final b = h.session.playPreview(
        const VoiceInfo('Mae', 'Mae', ''),
        'speech',
      );
      await Future<void>.delayed(Duration.zero);
      h.api.previews['Mae']!.complete(wavBytes(rate: 16000));
      await b;
      h.api.previews['Atlas']!.complete(wavBytes());
      await a;
      expect(h.audio.clips.length, 1);
      expect(h.audio.clips.single.rate, 16000);
      await h.session.stopPreview();
      expect(h.settings.voices['speech'], 'Atlas');
      await h.close();
    },
  );
  test('Focus loss disables capture, even if an old configuration acknowledgement arrives', () async {
    final h = VoiceHarness();
    h.settings.voiceMode = 'vad';
    await h.session.start(h.owner);
    h.ack();
    h.audio.output.add({'type': 'focus_lost'});
    await Future<void>.delayed(Duration.zero);
    final deviceError = h.session.error;
    expect(deviceError, contains('音频设备'));
    h.ack();
    expect(h.session.ready, false);
    expect(h.session.muted, true);
    expect(h.session.error, deviceError);
    expect(h.audio.stops, greaterThanOrEqualTo(1));
    await h.close();
  });
  test(
    'Minimizing the call preserves its connection and own conversation',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.session.minimize();
      expect(h.session.active, true);
      expect(h.session.open, false);
      expect(h.api.wires.length, 1);
      h.session.expand();
      expect(h.session.owner, h.owner);
      expect(h.audio.starts, 1);
      await h.close();
    },
  );
  test(
    'WAV parsing rejects stereo, unsupported formats and truncated data',
    () {
      expect(PcmClip.wav(wavBytes()).rate, 24000);
      expect(() => PcmClip.wav(wavBytes(channels: 2)), throwsFormatException);
      expect(() => PcmClip.wav(wavBytes(bits: 32)), throwsFormatException);
      expect(() => PcmClip.wav(Uint8List(44)), throwsFormatException);
    },
  );
}

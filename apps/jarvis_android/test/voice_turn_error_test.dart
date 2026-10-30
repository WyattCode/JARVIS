import 'package:flutter_test/flutter_test.dart';

import 'voice_support.dart';

void main() {
  test('A retry clears a previous empty-transcript error before listening and replying', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.settings.voiceMode = 'vad';
    h.event({'type': 'input_audio_buffer.committed', 'item_id': 'bad'});
    h.event({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'bad',
      'transcript': '',
    });
    expect(h.session.error, contains('没有识别到有效语音'));
    h.settings.voiceMode = 'ptt';
    await h.session.hold();
    expect(
      h.session.error,
      isNull,
      reason: 'A fresh accepted recording must replace the prior retry hint',
    );
    h.session.cancelHold();
    h.event({
      'type': 'response.created',
      'response': {'id': 'good'},
    });
    h.event({
      'type': 'response.text.delta',
      'response_id': 'good',
      'item_id': 'bot',
      'delta': '你好，我听清楚了。',
    });
    expect(h.session.error, isNull);
    expect(h.session.expressing, true);
    expect(h.session.hint, isNot(contains('松开发送')));
    await h.close();
  });
  test('Hands-free and typed retries clear transient errors; blocked input retains device errors', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.settings.voiceMode = 'vad';
    h.event({'type': 'input_audio_buffer.committed', 'item_id': 'bad'});
    h.event({
      'type': 'conversation.item.input_audio_transcription.failed',
      'item_id': 'bad',
    });
    expect(h.session.error, isNotNull);
    h.event({'type': 'input_audio_buffer.speech_started'});
    expect(h.session.error, isNull);
    h.event({'type': 'input_audio_buffer.committed', 'item_id': 'bad2'});
    h.event({
      'type': 'conversation.item.input_audio_transcription.failed',
      'item_id': 'bad2',
    });
    expect(h.session.typed('改用文字继续'), true);
    expect(h.session.error, isNull);
    await h.session.interrupt();
    h.audio.output.add({'type': 'input_error'});
    await Future<void>.delayed(Duration.zero);
    final deviceError = h.session.error;
    expect(deviceError, isNotNull);
    h.settings.voiceMode = 'ptt';
    await h.session.hold();
    expect(h.session.held, false);
    expect(h.session.error, deviceError);
    await h.close();
  });
}

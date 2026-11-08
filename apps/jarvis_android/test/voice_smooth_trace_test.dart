import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'voice_support.dart';

void main() {
  test(
    'Text waiting for audio is not presented as further model thinking',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r1'},
      });
      h.event({
        'type': 'response.audio_transcript.delta',
        'response_id': 'r1',
        'item_id': 'i1',
        'delta': '知道，接下来是完整内容。',
      });
      expect(h.session.status, '正在回复');
      expect(h.session.thinking, false);
      h.audio.output.add({
        'type': 'playback',
        'active': true,
        'buffered_frames': 4800,
        'sample_rate': 24000,
        'played_frames': 2400,
        'written_frames': 7200,
        'epoch': 1,
      });
      expect(h.session.status, '正在说话');
      h.audio.output.add({
        'type': 'playback',
        'active': false,
        'buffered_frames': 0,
        'sample_rate': 24000,
        'played_frames': 7200,
        'written_frames': 7200,
        'epoch': 1,
      });
      expect(h.session.status, '正在回复');
      await h.close();
    },
  );
  test(
    'Cancellation identifies the trigger and still rejects late old-turn audio',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r1'},
      });
      await h.session.interrupt(source: 'orb_tap');
      expect(
        h.wire.sent.lastWhere((x) => x['type'] == 'response.cancel')['source'],
        'orb_tap',
      );
      h.event({
        'type': 'response.audio.delta',
        'response_id': 'r1',
        'item_id': 'i1',
        'delta': base64Encode(Uint8List(4800)),
      });
      await Future<void>.delayed(Duration.zero);
      expect(h.audio.fed, isEmpty);
      h.event({
        'type': 'response.created',
        'response': {'id': 'r2'},
      });
      await h.session.hold();
      expect(
        h.wire.sent.lastWhere((x) => x['type'] == 'response.cancel')['source'],
        'ptt_press',
      );
      await h.close();
    },
  );
  test('Input and playback traces preserve counters without recording private text', () async {
    final records = <Map<String, dynamic>>[];
    final h = VoiceHarness(traceEvent: records.add);
    await h.session.start(h.owner);
    h.ack();
    h.event({'type': 'input_audio_buffer.speech_stopped', 'item_id': 'input1'});
    h.event({'type': 'input_audio_buffer.committed', 'item_id': 'input1'});
    h.event({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'input1',
      'transcript': '私密原文123',
    });
    h.event({
      'type': 'response.created',
      'response': {'id': 'r1'},
    });
    h.event({
      'type': 'response.audio_transcript.delta',
      'response_id': 'r1',
      'item_id': 'i1',
      'delta': '私密回复456',
    });
    h.audio.output.add({
      'type': 'playback',
      'active': true,
      'buffered_frames': 4800,
      'sample_rate': 24000,
      'played_frames': 2400,
      'written_frames': 7200,
      'epoch': 1,
      'underruns': 0,
    });
    final playback = records.lastWhere((r) => r['phase'] == 'playback');
    expect(playback['played_frames'], 2400);
    expect(playback['written_frames'], 7200);
    expect(playback['response_id'], 'r1');
    expect(
      records.firstWhere((r) => r['phase'] == 'input_committed')['response_id'],
      isNull,
    );
    expect(records.any((r) => r['phase'] == 'transcription_completed'), true);
    expect(jsonEncode(records).contains('私密'), false);
    await h.close();
  });
}

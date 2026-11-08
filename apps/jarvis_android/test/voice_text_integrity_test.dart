import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'voice_support.dart';

void main() {
  test('final transcript restores text missing from streamed deltas', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.event({'type': 'response.created', 'response': {'id': 'r'}});
    h.event({'type': 'response.audio_transcript.delta', 'response_id': 'r', 'item_id': 'i', 'delta': '知道。'});
    h.event({'type': 'response.audio_transcript.done', 'response_id': 'r', 'item_id': 'i', 'transcript': '知道。后面的完整内容。'});
    expect(h.owner.messages.single.text, '知道。后面的完整内容。');
    expect(h.session.lastBot, '知道。后面的完整内容。');
    await h.close();
  });
  test('a cancelled response ignores late final transcript', () async {
    final h = VoiceHarness();
    await h.session.start(h.owner);
    h.ack();
    h.event({'type': 'response.created', 'response': {'id': 'r'}});
    h.event({'type': 'response.audio_transcript.delta', 'response_id': 'r', 'item_id': 'i', 'delta': '已经显示。'});
    await h.session.interrupt();
    h.event({'type': 'response.audio_transcript.done', 'response_id': 'r', 'item_id': 'i', 'transcript': '过期的内容。'});
    expect(h.owner.messages.single.text, '已经显示。');
    await h.close();
  });
  test('completed response snapshot restores a missing final transcript event', () async {
    final h = VoiceHarness(); await h.session.start(h.owner); h.ack();
    h.event({'type':'response.created','response':{'id':'r'}});
    h.event({'type':'response.audio_transcript.delta','response_id':'r','item_id':'i','delta':'知道。'});
    h.event({'type':'response.done','response':{'id':'r','status':'completed','output':[{'type':'message','role':'assistant','id':'i','content':[{'type':'audio','transcript':'知道。完整的后文。'}]}]}});
    expect(h.owner.messages.single.text, '知道。完整的后文。');
    expect(h.owner.messages.single.status, 'complete'); await h.close();
  });
  test('late final text from previous turn cannot replace current transcript', () async {
    final h = VoiceHarness(); await h.session.start(h.owner); h.ack();
    h.event({'type':'response.created','response':{'id':'new'}});
    h.event({'type':'response.audio_transcript.delta','response_id':'new','item_id':'new-item','delta':'新回答'});
    h.event({'type':'response.audio_transcript.done','response_id':'old','item_id':'old-item','transcript':'旧回答'});
    expect(h.session.lastBot,'新回答'); expect(h.owner.messages.length,1); await h.close();
  });
  for (final name in ['browser-public', 'browser-public-vad']) {
    test('sanitized $name replay transcript survives Android event processing', () async {
      final data = jsonDecode(File('test/fixtures/voice_replay/$name.json').readAsStringSync()) as Map;
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      for (final e in data['events'] as List) {
        h.event(Map<String, dynamic>.from(e as Map));
      }
      final messages = h.owner.messages.where((m) => m.role == 'assistant').toList();
      expect(messages.length, 1);
      expect(messages.single.text, data['text']);
      expect(messages.single.status, 'complete');
      expect(h.session.lastBot, data['text']);
      await h.close();
    });
  }
}

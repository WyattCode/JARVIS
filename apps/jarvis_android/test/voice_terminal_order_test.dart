import 'package:flutter_test/flutter_test.dart';

import 'voice_support.dart';

void main() {
  test(
    'a server-cancelled final transcript cannot shorten already visible text',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r'},
      });
      h.event({
        'type': 'response.audio_transcript.delta',
        'response_id': 'r',
        'item_id': 'i',
        'delta': '第一句。已经显示的第二句和第三句。',
      });
      h.event({
        'type': 'response.audio_transcript.done',
        'response_id': 'r',
        'item_id': 'i',
        'transcript': '第一句。',
      });
      h.event({
        'type': 'response.done',
        'response': {
          'id': 'r',
          'status': 'cancelled',
          'output': [
            {
              'type': 'message',
              'role': 'assistant',
              'id': 'i',
              'status': 'incomplete',
              'content': [
                {'type': 'audio', 'transcript': '第一句。'},
              ],
            },
          ],
        },
      });
      final text = h.owner.messages.single.text;
      await h.close();
      expect(text, '第一句。已经显示的第二句和第三句。');
    },
  );
  test(
    'only completed response snapshot can make a shorter canonical correction',
    () async {
      final h = VoiceHarness();
      await h.session.start(h.owner);
      h.ack();
      h.event({
        'type': 'response.created',
        'response': {'id': 'r'},
      });
      h.event({
        'type': 'response.audio_transcript.delta',
        'response_id': 'r',
        'item_id': 'i',
        'delta': '最终回复。临时多出的文字。',
      });
      h.event({
        'type': 'response.audio_transcript.done',
        'response_id': 'r',
        'item_id': 'i',
        'transcript': '最终回复。',
      });
      expect(h.owner.messages.single.text, '最终回复。临时多出的文字。');
      h.event({
        'type': 'response.done',
        'response': {
          'id': 'r',
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'role': 'assistant',
              'id': 'i',
              'status': 'completed',
              'content': [
                {'type': 'audio', 'transcript': '最终回复。'},
              ],
            },
          ],
        },
      });
      expect(h.owner.messages.single.text, '最终回复。');
      await h.close();
    },
  );
}

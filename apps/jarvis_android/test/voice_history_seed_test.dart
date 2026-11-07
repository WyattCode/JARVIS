import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'voice_support.dart';

void main() {
 test('interrupted persisted message must retain incomplete status when seeded',() async {
  final h=VoiceHarness();
  h.owner.messages.add(ChatMessage.fromJson({'id':'stored','role':'assistant','text':'这句尚未说完，后面','status':'generating'}));
  expect(h.owner.messages.single.status,'interrupted');
  await h.session.start(h.owner);
  final events=h.wire.sent.where((e)=>e['type']=='conversation.item.create').toList();

  await h.close();
  expect(events.single['item']['status'],'incomplete');
 });
 test('reconnect reseeds the interrupted live turn as incomplete',() async {
  final h=VoiceHarness();
  await h.session.start(h.owner);h.ack();
  h.event({'type':'response.created','response':{'id':'r'}});
  h.event({'type':'response.audio_transcript.delta','response_id':'r','item_id':'i','delta':'这轮还没有说完，'});
  await h.wire.server.close();
  await Future<void>.delayed(const Duration(milliseconds:1300));
  expect(h.api.wires.length,2);
  final seeded=h.wire.sent.firstWhere((e)=>e['type']=='conversation.item.create');
  expect(seeded['item']['status'],'incomplete');
  expect(seeded['item']['content'][0]['text'],'这轮还没有说完，');
  await h.close();
 });
 test('explicit none still produces a no-thinking session despite low server default',() async {
  final h=VoiceHarness();h.effort='none';
  await h.session.start(h.owner);
  final event=h.wire.sent.firstWhere((e)=>e['type']=='session.update');

  expect(event['session']['reasoning'],false);
  await h.close();
 });
}

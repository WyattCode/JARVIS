import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'support.dart';
import 'voice_support.dart';
class ChangingApi extends VoiceApi {
 int revision=1, modelQueries=0; bool fail = false;
 @override Future<List<ModelInfo>> models() async {
  modelQueries++;
  if (fail) throw StateError('offline');
  return [ModelInfo('chat','Chat'),ModelInfo.fromJson({'id':'speech','kind':'speech','default_voice':revision==1?'retired':'kept','voice_default_revision':revision,'voices':revision==1?[{'id':'retired','name':'Old'},{'id':'kept','name':'Kept'}]:[{'id':'kept','name':'Kept'}]})];
 }
}
void main(){
 test('configuration update during call is applied before next call',()async{
  final api=ChangingApi(),audio=FakeAudio();final c=JarvisController(api,MemoryVault(),audioDevice:audio);
  await c.initialize();await c.login('test','test');expect(c.settings.voices['speech'],'retired');
  await c.voice.start(c.current);expect(api.wires.last.sent.firstWhere((e)=>e['type']=='session.update')['session']['voice'],'retired');
  api.revision=2;await c.refreshVoiceCatalog();expect(api.modelQueries,2);
  await c.voice.stop();await c.voice.start(c.current);
  expect(api.modelQueries,3);expect(api.wires.last.sent.firstWhere((e)=>e['type']=='session.update')['session']['voice'],'kept');
  await c.voice.stop();c.dispose();await audio.output.close();
 });
 test('failed refresh does not start a call with stale configuration', () async {
  final api=ChangingApi(), audio=FakeAudio();
  final c=JarvisController(api,MemoryVault(),audioDevice:audio);
  await c.initialize(); await c.login('test','test');
  api.fail=true;
  await c.voice.start(c.current);
  expect(c.voice.active, isFalse);
  expect(c.voice.error, contains('音色配置'));
  expect(api.wires, isEmpty);
  c.dispose(); await audio.output.close();
 });

 test('lost connection refreshes removed voice before opening a new socket', () async {
  final api=ChangingApi(),audio=FakeAudio();final c=JarvisController(api,MemoryVault(),audioDevice:audio);
  await c.initialize();await c.login('test','test');await c.voice.start(c.current);
  api.revision=2;await api.wires.first.close();
  await Future<void>.delayed(const Duration(milliseconds:1300));
  expect(api.wires.length,2);
  expect(api.wires.last.sent.firstWhere((e)=>e['type']=='session.update')['session']['voice'],'kept');
  await c.voice.stop();c.dispose();await audio.output.close();
 });
 test('failed reconnect refresh never opens a stale socket and hangup cancels retry', () async {
  final api=ChangingApi(),audio=FakeAudio();final c=JarvisController(api,MemoryVault(),audioDevice:audio);
  await c.initialize();await c.login('test','test');await c.voice.start(c.current);
  api.fail=true;await api.wires.first.close();
  await Future<void>.delayed(const Duration(milliseconds:1300));
  expect(api.wires.length,1);
  await c.voice.stop();api.fail=false;
  await Future<void>.delayed(const Duration(milliseconds:2200));
  expect(api.wires.length,1);c.dispose();await audio.output.close();
 });

}

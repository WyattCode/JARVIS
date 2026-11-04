import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/model/conversation.dart';

ModelInfo server({
  int? revision = 7,
  String selected = 'a',
  List<String> order = const ['a', 'b'],
}) => ModelInfo.fromJson({
  'id': 'tts-from-server',
  'kind': 'speech',
  'default_voice': selected,
  'voice_default_revision': ?revision,
  'voices': [
    for (final id in order) {'id': id, 'name': 'Server $id'},
  ],
});
void main() {
  test('Server defaults migrate once, persist manual choice and follow later revisions', () {
    final settings = ChatSettings()
      ..restore({
        'voices': {'tts-from-server': 'old', 'other': 'custom'},
        'atlasVoiceDefaultRevision': 1,
      });
    expect(ChatSettings().voices, isEmpty);
    expect(
      settings.applyVoiceDefaults([server()], scope: 'https://one.test'),
      isTrue,
    );
    expect(settings.voices['tts-from-server'], 'a');
    expect(settings.voices['other'], 'custom');
    settings.voices['tts-from-server'] = 'b';
    final restored = ChatSettings()..restore(settings.toJson());
    expect(
      restored.applyVoiceDefaults([server()], scope: 'https://one.test'),
      isFalse,
    );
    expect(restored.voices['tts-from-server'], 'b');
    expect(
      restored.applyVoiceDefaults([
        server(revision: 8),
      ], scope: 'https://one.test'),
      isTrue,
    );
    expect(restored.voices['tts-from-server'], 'a');
    restored.voices['tts-from-server'] = 'b';
    expect(
      restored.applyVoiceDefaults([server()], scope: 'https://one.test'),
      isFalse,
    );
    expect(restored.voices['tts-from-server'], 'b');
  });
  test('Server order and names are preserved without pinning any voice', () {
    final first = server();
    expect(first.defaultVoice, 'a');
    expect(first.voices.map((v) => v.name), ['Server a', 'Server b']);
    final changed = server(selected: 'b', order: ['b', 'a']);
    expect(changed.defaultVoice, 'b');
    expect(changed.voices.map((v) => v.id), ['b', 'a']);
  });
  test('Revisions are scoped by endpoint and unavailable defaults never erase a choice', () {
    final settings = ChatSettings();
    settings.applyVoiceDefaults([server()], scope: 'https://one.test');
    settings.voices['tts-from-server'] = 'b';
    expect(
      settings.applyVoiceDefaults([server()], scope: 'https://two.test'),
      isTrue,
    );
    settings.voices['tts-from-server'] = 'b';
    expect(
      settings.applyVoiceDefaults([
        server(revision: 9, selected: 'missing'),
      ], scope: 'https://two.test'),
      isFalse,
    );
    expect(settings.voices['tts-from-server'], 'b');
  });
  test('Legacy servers without revisions fill empty defaults but retain explicit choices', () {
    final settings = ChatSettings();
    settings.applyVoiceDefaults([
      server(revision: null),
    ], scope: 'https://one.test');
    expect(settings.voices['tts-from-server'], 'a');
    settings.voices['tts-from-server'] = 'b';
    expect(
      settings.applyVoiceDefaults([
        server(revision: null),
      ], scope: 'https://one.test'),
      isFalse,
    );
    expect(settings.voices['tts-from-server'], 'b');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/settings.dart';

void main() {
  final models = [
    ModelInfo.fromJson({
      'id': 'new',
      'kind': 'speech',
      'aliases': ['old'],
      'voices': ['a', 'b'],
      'default_voice': 'a',
      'voice_default_revision': 3,
    }),
  ];
  test('server alias moves a saved selection without resetting the voice', () {
    final s = ChatSettings()..speechModel = 'old';
    s.voices['old'] = 'b';
    expect(s.applyVoiceDefaults(models, scope: 'server'), isTrue);
    expect(s.speechModel, 'new');
    expect(s.voices['new'], 'b');
    expect(s.applyVoiceDefaults(models, scope: 'server'), isFalse);
    final restored = ChatSettings()..restore(s.toJson());
    expect(restored.speechModel, 'new');
    expect(restored.voices['new'], 'b');
  });
  test('missing models do not migrate without an explicit alias', () {
    final s = ChatSettings()..speechModel = 'unavailable';
    s.applyVoiceDefaults(models, scope: 'server');
    expect(s.speechModel, 'unavailable');
    s.speechModel = 'old';
    s.voices['old'] = 'removed';
    s.applyVoiceDefaults(models, scope: 'server');
    expect(s.speechModel, 'new');
    expect(s.voices['new'], 'a');
  });
}

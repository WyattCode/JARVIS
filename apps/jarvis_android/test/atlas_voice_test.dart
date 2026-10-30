import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/model/conversation.dart';

void main() {
  test(
    'Atlas defaults migrate once and preserve subsequent manual choices',
    () {
      final fresh = ChatSettings();
      expect(fresh.voices['fishaudio/drama-3'], 'zh-xingheng');
      final old = ChatSettings()
        ..restore({
          'voices': {'fishaudio/drama-3': 'Mae', 'other': 'custom'},
        });
      expect(old.voices['fishaudio/drama-3'], 'zh-xingheng');
      expect(old.voices['other'], 'custom');
      old.voices['fishaudio/drama-3'] = 'Arlo';
      final restored = ChatSettings()..restore(old.toJson());
      expect(restored.voices['fishaudio/drama-3'], 'Arlo');
    },
  );
  test('Atlas is first and default while retaining every supported voice', () {
    final model = ModelInfo.fromJson({
      'id': 'fishaudio/drama-3',
      'kind': 'speech',
      'default_voice': 'Mae',
      'voices': [
        'Mae',
        {'id': 'zh-xingheng', 'name': 'Atlas'},
        'Arlo',
      ],
    });
    expect(model.defaultVoice, 'zh-xingheng');
    expect(model.voices.map((v) => v.id).toList(), [
      'zh-xingheng',
      'Mae',
      'Arlo',
    ]);
    final other = ModelInfo.fromJson({
      'id': 'other',
      'kind': 'speech',
      'default_voice': 'a',
      'voices': ['b', 'a'],
    });
    expect(other.defaultVoice, 'a');
    expect(other.voices.first.id, 'b');
  });
}

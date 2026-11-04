import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/settings.dart';

void main() {
  test('Message font starts two points larger and persists user choices', () {
    final settings = ChatSettings();
    expect(settings.messageFontSize, 16);
    settings.restore({});
    expect(settings.messageFontSize, 16);
    settings.messageFontSize = 20;
    final restored = ChatSettings()..restore(settings.toJson());
    expect(restored.messageFontSize, 20);
    restored.restore({'messageFontSize': 999});
    expect(restored.messageFontSize, 16);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/voice_picker.dart';

import 'support.dart';

class SpeechApi extends FakeApi {
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('test-model', 'Test'),
    ModelInfo(
      's1',
      'engine-one',
      kind: 'speech',
      defaultVoice: 'a',
      voices: const [VoiceInfo('a', '星衡', '沉稳'), VoiceInfo('b', '晨曦', '明亮')],
    ),
    ModelInfo('s2', 'engine-two', kind: 'speech', defaultVoice: 'a'),
  ];
}

void main() {
  testWidgets('the call page picker uses the settings page rows', (t) async {
    final c = JarvisController(SpeechApi(), MemoryVault());
    await c.initialize();
    await c.connect();
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showVoicePicker(context, c),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(SettingsGroup), findsOneWidget);
    expect(find.byType(PickerRow<String>), findsOneWidget);
    expect(find.byType(VoiceChoiceRow), findsNWidgets(2));
    // Choosing a voice works through the shared row.
    await t.tap(find.text('晨曦'));
    await t.pump();
    expect(c.settings.voices['s1'], 'b');
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

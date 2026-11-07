import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/model/settings.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';
import 'voice_support.dart';

class PolicyApi extends VoiceApi {
  dynamic policy = {
    'voice_defaults': {'reasoning_effort': 'low'},
    'voice_effort_models': {
      'none': 'chat-none',
      'low': 'chat-low',
      'medium': 'chat-medium',
      'high': 'chat-high',
    },
  };
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo.fromJson({'id': 'chat', 'kind': 'chat', 'jarvis': policy}),
    ModelInfo(
      'speech',
      'Speech',
      kind: 'speech',
      defaultVoice: 'Atlas',
      voices: const [VoiceInfo('Atlas', 'Atlas', '')],
    ),
  ];
}

void main() {
  test(
    'voice follows server while text remains high; manual choice persists',
    () async {
      final api = PolicyApi(), audio = FakeAudio(), vault = MemoryVault();
      final c = JarvisController(api, vault, audioDevice: audio);
      await c.initialize();
      await c.login('test', 'test');
      expect(c.effort, 'high');
      expect(c.voiceEffort, 'low');
      await c.voice.start(c.current);
      expect(
        api.wires.last.sent.firstWhere(
          (e) => e['type'] == 'session.update',
        )['session']['model'],
        'chat-low',
      );
      final count = api.wires.last.sent.length;
      c.setEffort('medium');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(api.wires.last.sent.length, count);
      c.setVoiceEffort('high');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        api.wires.last.sent.lastWhere(
          (e) => e['type'] == 'session.update',
        )['session']['model'],
        'chat-high',
      );
      await c.voice.stop();
      await c.save();
      expect(vault.value, contains('"voiceEffort":"high"'));
      api.policy['voice_defaults']['reasoning_effort'] = 'none';
      await c.refreshVoiceCatalog();
      expect(c.voiceEffort, 'high');
      c.setVoiceEffort('');
      expect(c.voiceEffort, 'none');
      c.dispose();
      await audio.output.close();
    },
  );
  test(
    'old settings follow server; malformed defaults fall back safely',
    () async {
      final api = PolicyApi(), c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('test', 'test');
      for (final bad in [
        'bad',
        {'voice_defaults': 'bad'},
        {
          'voice_defaults': {'reasoning_effort': false},
        },
      ]) {
        api.policy = bad;
        await c.refreshVoiceCatalog();
        expect(c.voiceEffort, 'low');
      }
      for (final value in [null, 'bad', false]) {
        final s = ChatSettings();
        s.restore({'voiceEffort': value});
        expect(s.voiceEffort, '');
      }
      final s = ChatSettings();
      s.restore({'voiceEffort': 'medium'});
      expect(s.toJson()['voiceEffort'], 'medium');
      c.dispose();
    },
  );
}

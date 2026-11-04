import 'conversation.dart';

class ChatSettings {
  bool tools = true;
  int maxTokens = 0;
  double messageFontSize = 16;
  String instructions = '';
  String apiKey = '';
  String speechModel = '';
  final Map<String, String> voices = {};
  final Map<String, int> voiceDefaultRevisions = {};
  int atlasVoiceDefaultRevision = 1;
  String voiceMode = 'ptt';
  String language = '';
  String transcriptionPrompt = '';
  int waitMs = 800;
  double threshold = .5;
  bool echoCancel = true;
  Map<String, dynamic> toJson() => {
    'tools': tools,
    'maxTokens': maxTokens,
    'messageFontSize': messageFontSize,
    'instructions': instructions,
    'apiKey': apiKey,
    'speechModel': speechModel,
    'voices': voices,
    'atlasVoiceDefaultRevision': atlasVoiceDefaultRevision,
    'voiceDefaultRevisions': voiceDefaultRevisions,
    'voiceMode': voiceMode,
    'language': language,
    'transcriptionPrompt': transcriptionPrompt,
    'waitMs': waitMs,
    'threshold': threshold,
    'echoCancel': echoCancel,
  };

  /// Server catalog/defaults are authoritative. A revision applies only once;
  /// later manual choices survive refreshes, and rollback cannot replay an old revision.
  bool applyVoiceDefaults(List<ModelInfo> models, {required String scope}) {
    var changed = false;
    for (final m in models.where((m) => m.kind == 'speech')) {
      if (m.defaultVoice.isEmpty ||
          !m.voices.any((v) => v.id == m.defaultVoice)) {
        continue;
      }
      final key = '$scope|${m.id}';
      final revision = m.metadata['voice_default_revision'];
      final validRevision =
          revision is int && revision > 0 && revision <= 9007199254740991;
      if (validRevision && revision > (voiceDefaultRevisions[key] ?? 0)) {
        voices[m.id] = m.defaultVoice;
        voiceDefaultRevisions[key] = revision;
        changed = true;
      } else if ((voices[m.id] ?? '').isEmpty ||
          !m.voices.any((v) => v.id == voices[m.id])) {
        voices[m.id] = m.defaultVoice;
        changed = true;
      }
    }
    return changed;
  }

  void restore(Map<String, dynamic> j) {
    tools = j['tools'] as bool? ?? true;
    maxTokens = ((j['maxTokens'] as num?)?.toInt() ?? 0).clamp(0, 32768);
    final font = (j['messageFontSize'] as num?)?.toDouble();
    messageFontSize =
        const [12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0].contains(font)
        ? font!
        : 16;
    instructions = j['instructions'] as String? ?? '';
    apiKey = j['apiKey'] as String? ?? '';
    speechModel = j['speechModel'] as String? ?? '';
    voices.clear();
    voices.addAll((j['voices'] as Map? ?? {}).cast<String, String>());
    atlasVoiceDefaultRevision = 1;
    voiceDefaultRevisions.clear();
    for (final entry in (j['voiceDefaultRevisions'] as Map? ?? {}).entries) {
      if (entry.key is String && entry.value is int && entry.value >= 0) {
        voiceDefaultRevisions[entry.key as String] = entry.value as int;
      }
    }
    voiceMode = j['voiceMode'] == 'vad' ? 'vad' : 'ptt';
    final savedLanguage = j['language'] as String? ?? '';
    language =
        ['', 'zh', 'en', 'ja', 'ko', 'fr', 'de', 'es'].contains(savedLanguage)
        ? savedLanguage
        : '';
    transcriptionPrompt = (j['transcriptionPrompt'] as String? ?? '');
    if (transcriptionPrompt.length > 500) {
      transcriptionPrompt = transcriptionPrompt.substring(0, 500);
    }
    final wait = ((j['waitMs'] as num?)?.toInt() ?? 800).clamp(300, 5000);
    waitMs = [
      300,
      500,
      800,
      1000,
      1500,
      2000,
      3000,
      4000,
      5000,
    ].reduce((a, b) => (a - wait).abs() <= (b - wait).abs() ? a : b);
    threshold = ((j['threshold'] as num?)?.toDouble() ?? .5).clamp(.2, .8);
    echoCancel = j['echoCancel'] as bool? ?? true;
  }
}

class ChatOptions {
  const ChatOptions({this.tools = const [], this.maxTokens = 0});
  final List<Map<String, dynamic>> tools;
  final int maxTokens;
}

import 'text_clip.dart';

class ChatSettings {
  bool tools = true;
  int maxTokens = 0;
  double messageFontSize = 16;
  String instructions = '';
  String apiKey = '';
  String speechModel = '';
  final Map<String, String> voices = {};

  /// The server's voice-default revision already applied here, by `<server>|<speech model>`: a default the server
  /// changes is taken once, and the voice the user picks afterwards is kept.
  final Map<String, int> voiceDefaultRevisions = {};
  String voiceMode = 'ptt';
  String language = '';
  String transcriptionPrompt = '';
  int waitMs = 800;
  double threshold = .5;
  bool echoCancel = true;

  /// The one-time notice about what is sent to the AI service was accepted on this device.
  bool aiNoticeAccepted = false;
  Map<String, dynamic> toJson() => {
    'tools': tools,
    'maxTokens': maxTokens,
    'messageFontSize': messageFontSize,
    'instructions': instructions,
    'apiKey': apiKey,
    'speechModel': speechModel,
    'voices': voices,
    'voiceDefaultRevisions': voiceDefaultRevisions,
    'voiceMode': voiceMode,
    'language': language,
    'transcriptionPrompt': transcriptionPrompt,
    'waitMs': waitMs,
    'threshold': threshold,
    'echoCancel': echoCancel,
    'aiNoticeAccepted': aiNoticeAccepted,
  };
  void restore(Map<String, dynamic> j) {
    aiNoticeAccepted = j['aiNoticeAccepted'] as bool? ?? false;
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
    voiceDefaultRevisions.clear();
    for (final e in (j['voiceDefaultRevisions'] as Map? ?? {}).entries) {
      final value = e.value;
      if (e.key is String && value is num && value > 0) {
        voiceDefaultRevisions[e.key as String] = value.toInt();
      }
    }
    voiceMode = j['voiceMode'] == 'vad' ? 'vad' : 'ptt';
    final savedLanguage = j['language'] as String? ?? '';
    language =
        ['', 'zh', 'en', 'ja', 'ko', 'fr', 'de', 'es'].contains(savedLanguage)
        ? savedLanguage
        : '';
    // Cut between characters, never inside a surrogate pair.
    transcriptionPrompt = clipCharacters(
      j['transcriptionPrompt'] as String? ?? '',
      500,
    );
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

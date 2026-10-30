import 'media.dart';
import 'text_clip.dart';

class ChatMessage {
  ChatMessage(
    this.role,
    this.text, {
    this.reasoning = '',
    this.status = 'complete',
    this.error,
    this.hidden = false,
    this.taskId,
    String? id,
    List<Attachment>? attachments,
    List<ToolCall>? calls,
    Map<String, String>? toolResults,
  }) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
       attachments = attachments ?? [],
       calls = calls ?? [],
       toolResults = toolResults ?? {};
  static int _serial = 0;
  final String id;
  final List<Attachment> attachments;
  final List<ToolCall> calls;
  final Map<String, String> toolResults;
  final String? taskId;
  final String role;
  String text;
  String reasoning;
  String status;
  String? error;
  bool hidden;
  Map<String, Object?> toJson() => {
    'id': id,
    'taskId': taskId,
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'calls': calls.map((c) => c.toJson()).toList(),
    'toolResults': toolResults,
    'role': role,
    'text': text,
    'reasoning': reasoning,
    'status': status,
    'error': error,
    'hidden': hidden,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    j['role'] as String,
    j['text'] as String,
    id: j['id'] as String?,
    toolResults: (j['toolResults'] as Map? ?? {}).cast<String, String>(),
    hidden: j['hidden'] as bool? ?? false,
    taskId: j['taskId'] as String?,
    attachments: (j['attachments'] as List? ?? [])
        .map((a) => Attachment.fromJson(Map<String, dynamic>.from(a as Map)))
        .toList(),
    calls: (j['calls'] as List? ?? [])
        .map((a) => ToolCall.fromJson(Map<String, dynamic>.from(a as Map)))
        .toList(),
    reasoning: j['reasoning'] as String? ?? '',
    error: j['error'] as String?,
    status: j['status'] == 'generating'
        ? 'interrupted'
        : j['status'] as String? ?? 'complete',
  );
}

class Conversation {
  Conversation(
    this.id, {
    this.title = '新建会话',
    List<ChatMessage>? messages,
    this.draft = '',
    this.named = false,
    List<Attachment>? attachments,
    List<MediaTask>? tasks,
  }) : messages = messages ?? [],
       pendingAttachments = attachments ?? [],
       tasks = tasks ?? [];
  final String id;
  bool named;
  final List<Attachment> pendingAttachments;
  final List<MediaTask> tasks;
  String title;
  String draft;
  final List<ChatMessage> messages;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'named': named,
    'attachments': pendingAttachments.map((a) => a.toJson()).toList(),
    'tasks': tasks.map((a) => a.toJson()).toList(),
    'draft': draft,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    j['id'] as String,
    named: j['named'] as bool? ?? false,
    attachments: (j['attachments'] as List? ?? [])
        .map((a) => Attachment.fromJson(Map<String, dynamic>.from(a as Map)))
        .toList(),
    tasks: (j['tasks'] as List? ?? [])
        .map((a) => MediaTask.fromJson(Map<String, dynamic>.from(a as Map)))
        .toList(),
    // A title cut inside a surrogate pair by an earlier version would make its sidebar row throw on every launch.
    title: wellFormed(j['title'] as String? ?? '新建会话'),
    draft: j['draft'] as String? ?? '',
    messages: (j['messages'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
  );
}

/// How model names are shown: the first letter of every word is capitalised and the rest is left alone,
/// e.g. `qwen3-asr-1.7b` -> `Qwen3-Asr-1.7b`, `fishaudio/drama-3` -> `Fishaudio/Drama-3`.
String displayModelName(String name) {
  final out = StringBuffer();
  var start = true;
  for (final rune in name.runes) {
    final ch = String.fromCharCode(rune);
    out.write(start ? ch.toUpperCase() : ch);
    start = ch == '-' || ch == '/' || ch == ' ' || ch == '_' || ch == '(';
  }
  return out.toString();
}

class ModelInfo {
  ModelInfo(
    this.id,
    this.name, {
    this.kind = 'chat',
    this.voices = const [],
    this.defaultVoice = '',
    this.metadata = const {},
  });
  final String id, name, kind, defaultVoice;
  final List<VoiceInfo> voices;
  final Map<String, dynamic> metadata;
  bool get imageInput =>
      metadata['jarvis']?['image_input'] == true ||
      (metadata['architecture']?['input_modalities'] as List? ?? []).contains(
        'image',
      );
  bool get pdfInput => metadata['jarvis']?['pdf_text'] == true;
  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    if (j['id'] == 'fishaudio/drama-3' && j['kind'] == 'speech') {
      final voices = List<dynamic>.from(j['voices'] as List? ?? []);
      String voiceId(dynamic v) => v is String ? v : v['id'] as String;
      final atlas = voices.where((v) => voiceId(v) == 'zh-xingheng');
      if (atlas.isNotEmpty) {
        j = {
          ...j,
          'default_voice': 'zh-xingheng',
          'voices': [
            atlas.first,
            ...voices.where((v) => voiceId(v) != 'zh-xingheng'),
          ],
        };
      }
    }
    return ModelInfo(
      j['id'] as String,
      (j['name'] ?? j['id']) as String,
      kind: j['kind'] as String? ?? 'chat',
      defaultVoice: j['default_voice'] as String? ?? '',
      metadata: j,
      voices: (j['voices'] as List? ?? [])
          .map(
            (v) => v is String
                ? VoiceInfo(v, v, '')
                : VoiceInfo(
                    v['id'] as String,
                    (v['name'] ?? v['id']) as String,
                    v['description'] as String? ?? '',
                    preview: v['preview_url'] as String?,
                  ),
          )
          .toList(),
    );
  }
}

class ChatDelta {
  const ChatDelta({
    this.text = '',
    this.reasoning = '',
    this.finishReason,
    this.done = false,
    this.toolDeltas = const [],
  });
  final String text;
  final String reasoning;
  final String? finishReason;
  final bool done;
  final List<ToolDelta> toolDeltas;
}

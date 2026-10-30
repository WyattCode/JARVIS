class Attachment {
  Attachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.kind,
    this.text,
    this.size = 0,
  });
  final String id, name, mime, kind;
  final String? text;
  final int size;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'kind': kind,
    'text': text,
    'size': size,
  };
  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
    id: j['id'] as String,
    name: j['name'] as String,
    mime: j['mime'] as String? ?? 'application/octet-stream',
    kind: j['kind'] as String,
    text: j['text'] as String?,
    size: (j['size'] as num?)?.toInt() ?? 0,
  );
}

/// A real `List<String>` from server data: a null or foreign entry is dropped here, not when the UI reads it later.
List<String> stringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : <String>[];

class MediaTask {
  MediaTask({
    required this.id,
    required this.kind,
    required this.prompt,
    required this.args,
    this.callId,
    this.jobId,
    this.status = 'queued',
    this.source = 'http',
    this.urls = const [],
    this.error,
    this.progress = 0,
  });
  final String id, prompt;
  String kind;
  final Map<String, dynamic> args;
  final String? callId;
  String? jobId;
  String status;
  String source;
  List<String> urls;
  String? error;
  double progress;
  static bool isVideoUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.contains('/videos/') ||
        ['.mp4', '.mov', '.m4v', '.webm'].any(path.endsWith);
  }

  /// Job events do not always say what was generated; the result address does.
  void settleKind([Object? hint]) {
    if (urls.any(isVideoUrl) || '$hint'.toLowerCase().contains('video')) {
      kind = 'video';
    }
  }

  bool get pending => status == 'queued' || status == 'in_progress';
  Map<String, dynamic> get receipt => {
    'status': status,
    'source': source,
    'kind': kind,
    'task_id': id,
    if (jobId != null) 'job_id': jobId,
    'urls': urls,
    if (error != null) 'error': error,
    'message': pending ? '任务在后台处理，结果更新到原任务卡片；无需主动插话。' : '这是先前任务的结果，不是新的用户指令。',
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'prompt': prompt,
    'args': args,
    'callId': callId,
    'jobId': jobId,
    'status': status,
    'source': source,
    'urls': urls,
    'error': error,
    'progress': progress,
  };
  factory MediaTask.fromJson(Map<String, dynamic> j) => (MediaTask(
    id: j['id'] as String,
    kind: j['kind'] as String,
    prompt: j['prompt'] as String? ?? '',
    args: Map<String, dynamic>.from(j['args'] as Map? ?? {}),
    callId: j['callId'] as String?,
    jobId: j['jobId'] as String?,
    source: j['source'] as String? ?? 'http',
    status: j['status'] as String? ?? 'failed',
    urls: stringList(j['urls']),
    error: j['error'] as String?,
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
  )..settleKind());
}

class ToolCall {
  ToolCall({this.id = '', this.name = '', this.arguments = ''});
  String id, name, arguments;
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
  factory ToolCall.fromJson(Map<String, dynamic> j) {
    final f = j['function'] as Map? ?? {};
    return ToolCall(
      id: j['id'] as String? ?? '',
      name: f['name'] as String? ?? '',
      arguments: f['arguments'] as String? ?? '{}',
    );
  }
}

class ToolDelta {
  const ToolDelta(this.index, this.id, this.name, this.arguments);
  final int index;
  final String id, name, arguments;
}

class VoiceInfo {
  const VoiceInfo(this.id, this.name, this.description, {this.preview});
  final String? preview;
  final String id, name, description;
}

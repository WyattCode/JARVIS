import '../model/conversation.dart';

List<Map<String, dynamic>> mediaToolSchema(List<ModelInfo> models) {
  final out = <Map<String, dynamic>>[];
  for (final kind in ['image', 'video']) {
    final m = models.where((m) => m.kind == kind).firstOrNull;
    if (m == null) continue;
    final maxSeconds =
        (m.metadata['limits']?['max_seconds'] as num?)?.toInt() ?? 5;
    out.add({
      'type': 'function',
      'function': {
        'name': 'generate_$kind',
        'description': kind == 'image'
            ? '根据详细描述生成图片，结果展示在原任务卡片中。'
            : '生成短视频，耗时较长，将在后台处理；结果更新到原任务卡片。',
        'parameters': {
          'type': 'object',
          'properties': {
            'prompt': {'type': 'string'},
            if (kind == 'image')
              'size': {
                'type': 'string',
                'description': '宽x高，16的整数倍，例如1024x1024',
              },
            if (kind == 'video')
              'seconds': {
                'type': 'integer',
                'minimum': 1,
                'maximum': maxSeconds,
              },
          },
          'required': ['prompt'],
        },
      },
    });
  }
  return out;
}

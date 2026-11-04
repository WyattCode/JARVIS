const modelToolNames = {
  'list_models',
  'reserve_for',
  'unload_model',
  'load_model',
};
List<Map<String, dynamic>> modelToolSchema() => [
  {
    'type': 'function',
    'function': {
      'name': 'list_models',
      'description': '查询当前模型状态、内存需求、被暂时换出的模型；不执行加载或卸载。',
      'parameters': {'type': 'object', 'properties': {}},
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'reserve_for',
      'description': '为模型任务预留空间。先用dry_run检查影响，实际操作遵循服务端保护；不能卸载当前聊天模型。',
      'parameters': {
        'type': 'object',
        'properties': {
          'model': {'type': 'string'},
          'seconds': {'type': 'integer'},
          'dry_run': {'type': 'boolean'},
        },
        'required': ['model'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'unload_model',
      'description': '暂时卸载指定模型，不能卸载当前聊天模型；由服务端负责后续恢复。',
      'parameters': {
        'type': 'object',
        'properties': {
          'model': {'type': 'string'},
          'hold_s': {'type': 'integer'},
        },
        'required': ['model'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'load_model',
      'description': '按服务端规则加载指定模型。',
      'parameters': {
        'type': 'object',
        'properties': {
          'model': {'type': 'string'},
        },
        'required': ['model'],
      },
    },
  },
];

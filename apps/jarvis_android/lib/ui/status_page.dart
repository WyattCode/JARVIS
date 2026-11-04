import '../model/conversation.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/jarvis_controller.dart';
import '../net/jarvis_api.dart';

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  late Future<Map<String, dynamic>> status;
  @override
  void initState() {
    super.initState();
    status = load();
  }

  Future<Map<String, dynamic>> load() async {
    try {
      return await widget.controller.api.toolsStatus();
    } on JarvisException catch (e) {
      if (e.unauthorized) widget.controller.expireSession();
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('模型状态'),
      actions: [
        IconButton(
          tooltip: '刷新状态',
          onPressed: () => setState(() => status = load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: FutureBuilder<Map<String, dynamic>>(
        future: status,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 28),
                    const SizedBox(height: 12),
                    const Text('暂时无法读取模型状态', textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => setState(() => status = load()),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          final data = snapshot.data!, entries = data['data'] as List? ?? [];
          final memory = data['mem_available_bytes'] as num?;
          const labels = {
            'ready': '已就绪',
            'running': '运行中',
            'idle': '空闲',
            'disabled': '未启用',
            'stopped': '已停止',
            'error': '需要检查',
            'busy': '正在处理',
            'loading': '加载中',
            'unloaded': '按需加载',
            'failed': '需要检查',
          };
          return LayoutBuilder(
            builder: (context, bounds) => ListView(
              padding: EdgeInsets.symmetric(
                vertical: 20,
                horizontal: math.max(20, (bounds.maxWidth - 720) / 2),
              ),
              children: [
                Text(
                  displayModelName(
                    widget.controller.models
                            .where((m) => m.id == widget.controller.model)
                            .firstOrNull
                            ?.name ??
                        widget.controller.model,
                  ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text('语音、图片和视频模型可以按需加载；未加载不表示聊天模型故障。'),
                if (memory != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '可用内存 ${(memory / 1073741824).toStringAsFixed(1)} GiB',
                    ),
                  ),
                const SizedBox(height: 16),
                for (final entry in entries.whereType<Map>())
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.circle,
                      size: 8,
                      color: switch (entry['state']) {
                        'ready' ||
                        'running' ||
                        'idle' => const Color(0xff2d9f80),
                        'loading' || 'busy' => const Color(0xffc6a765),
                        'failed' ||
                        'error' => Theme.of(context).colorScheme.error,
                        _ => Theme.of(context).colorScheme.outline,
                      },
                    ),
                    title: Text(
                      displayModelName(
                        '${entry['name'] ?? entry['id'] ?? '模型'}',
                      ),
                    ),
                    subtitle: Text(labels[entry['state']] ?? '状态未知'),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

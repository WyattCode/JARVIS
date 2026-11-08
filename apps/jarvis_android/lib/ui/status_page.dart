import '../model/conversation.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../state/jarvis_controller.dart';
import '../net/jarvis_api.dart';
import 'page_palette.dart';

/// One model on the page: its name, how it stands in words, and the tone of
/// the dot (ok, busy, bad or off), as the iOS status page keeps them.
class StatusRow {
  const StatusRow(this.name, this.label, this.tone);
  final String name;
  final String label;
  final String tone;
}

const _stateLabels = {
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

String _tone(Object? state) => switch (state) {
  'ready' || 'running' || 'idle' => 'ok',
  'loading' || 'busy' => 'busy',
  'failed' || 'error' => 'bad',
  _ => 'off',
};

List<StatusRow> statusRows(Map<String, dynamic> data) => [
  for (final entry
      in (data['data'] is List ? data['data'] as List : const [])
          .whereType<Map>())
    StatusRow(
      displayModelName('${entry['name'] ?? entry['id'] ?? '模型'}'),
      _stateLabels[entry['state']] ?? '状态未知',
      _tone(entry['state']),
    ),
];

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  Map<String, dynamic>? data;
  DateTime? updated;
  bool loading = false;
  bool failed = false;
  Future<void>? running;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<Map<String, dynamic>> load() async {
    try {
      return await widget.controller.api.toolsStatus();
    } on JarvisException catch (e) {
      if (e.unauthorized) widget.controller.expireSession();
      rethrow;
    }
  }

  /// Reads the status again. What was read before stays on the page while it
  /// runs and when it fails; a second request joins the one in flight.
  Future<void> refresh() => running ??= _refresh().whenComplete(() {
    running = null;
  });

  Future<void> _refresh() async {
    final hadData = data != null;
    setState(() => loading = true);
    Map<String, dynamic>? next;
    try {
      next = await load();
    } catch (_) {
      next = null;
    }
    if (!mounted) return;
    setState(() {
      loading = false;
      failed = next == null;
      if (next != null) {
        data = next;
        updated = DateTime.now();
      }
    });
    // A refresh that ends says how it ended (the list under the finger does
    // not move).
    if (hadData && MediaQuery.accessibleNavigationOf(context)) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        failed ? '刷新失败' : '模型状态已更新',
        Directionality.of(context),
      );
    }
  }

  String get title {
    final c = widget.controller;
    return displayModelName(
      c.models.where((m) => m.id == c.model).firstOrNull?.name ?? c.model,
    );
  }

  String? get memory {
    final raw = data?['mem_available_bytes'];
    final bytes = raw is num ? raw : null;
    return bytes == null
        ? null
        : '可用内存 ${(bytes / 1073741824).toStringAsFixed(1)} GiB';
  }

  String? get updatedLabel {
    final t = updated;
    if (t == null) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    return '更新于 ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型状态'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      backgroundColor: p.surface,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: data == null
            ? (loading ? _reading(context) : _unavailable(context))
            : _page(context),
      ),
    );
  }

  Widget _reading(BuildContext context) {
    final p = PagePalette.of(context);
    return SafeArea(
      key: const Key('status-reading'),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: p.onSurfaceVariant),
            const SizedBox(height: 14),
            Text('正在读取模型状态', style: TextStyle(color: p.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _unavailable(BuildContext context) {
    final p = PagePalette.of(context);
    return SafeArea(
      key: const Key('status-unavailable'),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 30,
                color: p.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '暂时无法读取模型状态',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.onSurface),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _toneColor(PagePalette p, String tone) => switch (tone) {
    'ok' => p.success,
    'busy' => p.warning,
    'bad' => p.error,
    _ => p.onSurfaceVariant,
  };

  Widget _page(BuildContext context) {
    final p = PagePalette.of(context);
    final rows = statusRows(data!);
    return Stack(
      key: const Key('status-list'),
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, box) {
              final split = PageFoldSplit.of(context, box);
              if (split != null) {
                // Half-folded sideways: the summary on the left screen, the
                // models on the right one, nothing on the crease.
                return split.row(
                  _scroll([_summary(p, rows)]),
                  _scroll([_models(p, rows)]),
                  key: const Key('status-fold-split'),
                );
              }
              final wide = box.maxWidth >= 640 && box.maxWidth > box.maxHeight;
              if (!wide) {
                return SafeArea(
                  child: _scroll([
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: _info(p),
                    ),
                    const SizedBox(height: 22),
                    if (rows.isEmpty) _empty(p) else _narrowCard(p, rows),
                  ]),
                );
              }
              // Wide: what the page says in a column at the left, the models
              // beside it.
              return SafeArea(
                child: _scroll([
                  Row(
                    key: const Key('status-wide'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: math.max(280, box.maxWidth * .4),
                        child: _summary(p, rows),
                      ),
                      const SizedBox(width: 16),
                      Expanded(child: _models(p, rows)),
                    ],
                  ),
                ]),
              );
            },
          ),
        ),
        if (loading)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              key: const Key('status-progress'),
              minHeight: 2,
              color: p.onSurfaceVariant,
              backgroundColor: Colors.transparent,
            ),
          ),
      ],
    );
  }

  Widget _scroll(List<Widget> children) => RefreshIndicator(
    onRefresh: refresh,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
      children: children,
    ),
  );

  Widget _info(PagePalette p) {
    final small = TextStyle(fontSize: 14, color: p.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: p.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('语音、图片和视频模型可以按需加载；未加载不表示聊天模型故障。', style: small),
        if (memory != null) ...[
          const SizedBox(height: 8),
          Text(memory!, style: small),
        ],
        if (updatedLabel != null) ...[
          const SizedBox(height: 8),
          Text(updatedLabel!, style: small),
        ],
        if (failed) ...[const SizedBox(height: 8), _banner(p)],
      ],
    );
  }

  Widget _banner(PagePalette p) => Row(
    key: const Key('status-failed-banner'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.error_outline, size: 16, color: p.error),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          '刷新失败，显示的是上一次的状态',
          style: TextStyle(fontSize: 14, color: p.error),
        ),
      ),
    ],
  );

  Widget _empty(PagePalette p) => Padding(
    key: const Key('status-empty'),
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        Icon(Icons.memory, size: 30, color: p.onSurfaceVariant),
        const SizedBox(height: 8),
        Text('服务暂未返回模型状态', style: TextStyle(color: p.onSurface)),
        const SizedBox(height: 8),
        Text(
          '稍后下拉刷新，或点刷新重试。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: p.onSurfaceVariant),
        ),
      ],
    ),
  );

  /// The narrow page's models: one card, a row each, with hairlines between.
  Widget _narrowCard(PagePalette p, List<StatusRow> rows) => PageCard(
    child: Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            Divider(height: .7, thickness: .7, indent: 16, color: p.divider),
          Semantics(
            container: true,
            child: Padding(
              key: const Key('status-row'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Row(
                children: [
                  Container(
                    key: const Key('status-dot'),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _toneColor(p, rows[i].tone),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rows[i].name,
                          style: TextStyle(fontSize: 16, color: p.onSurface),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          rows[i].label,
                          style: TextStyle(
                            fontSize: 13,
                            color: p.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  /// The wide page's left half: the title and note, the models counted by how
  /// they stand, and the memory and the time read.
  Widget _summary(PagePalette p, List<StatusRow> rows) {
    final order = <String>[];
    final counts = <String, (int, String)>{};
    for (final r in rows) {
      if (!counts.containsKey(r.label)) {
        order.add(r.label);
        counts[r.label] = (0, r.tone);
      }
      counts[r.label] = (counts[r.label]!.$1 + 1, r.tone);
    }
    final small = TextStyle(fontSize: 14, color: p.onSurfaceVariant);
    return PageCard(
      child: Padding(
        key: const Key('status-summary'),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: p.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('语音、图片和视频模型可以按需加载；未加载不表示聊天模型故障。', style: small),
            if (order.isNotEmpty) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  for (var i = 0; i < order.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: Semantics(
                        label: '${counts[order[i]]!.$1} 个，${order[i]}',
                        excludeSemantics: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: _toneColor(
                              p,
                              counts[order[i]]!.$2,
                            ).withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${counts[order[i]]!.$1}',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w600,
                                  color: _toneColor(p, counts[order[i]]!.$2),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                order[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: p.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 18),
            if (memory != null) _fact(p, Icons.memory, memory!),
            if (updatedLabel != null) _fact(p, Icons.schedule, updatedLabel!),
            if (failed) ...[const SizedBox(height: 4), _banner(p)],
          ],
        ),
      ),
    );
  }

  Widget _fact(PagePalette p, IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Icon(icon, size: 16, color: p.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 14, color: p.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );

  /// The wide page's right half: a row for each model, its state as a pill.
  Widget _models(PagePalette p, List<StatusRow> rows) {
    if (rows.isEmpty) return PageCard(child: _empty(p));
    return PageCard(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(height: .7, thickness: .7, indent: 18, color: p.divider),
            Semantics(
              container: true,
              child: Padding(
                key: const Key('status-row'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    Container(
                      key: const Key('status-dot'),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _toneColor(p, rows[i].tone),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        rows[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: p.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _toneColor(
                          p,
                          rows[i].tone,
                        ).withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        rows[i].label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: _toneColor(p, rows[i].tone),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

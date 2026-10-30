import 'duo_rail.dart';
import '../model/conversation.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'motion.dart';
import 'settings_widgets.dart';

import '../state/jarvis_controller.dart';
import '../net/jarvis_api.dart';

/// Where a status row's name starts inside its card: 16 pt padding, the dot's 12 pt slot, 16 pt gap.
const statusTextIndent = 16.0 + 12 + 16;

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  /// The last status that loaded stays on screen while a refresh runs (or fails), instead of giving way to a spinner.
  Map<String, dynamic>? data;
  bool loading = true, failed = false;

  /// The refresh was started by pulling the list down: its own indicator is showing, not the bar along the top.
  bool pulled = false;

  /// When [data] was read.
  DateTime? updatedAt;
  int generation = 0;
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

  Future<void> refresh() {
    final mine = ++generation;
    // Called from initState too, where setState is not allowed (and not needed: `loading` starts true).
    if (data != null || failed) {
      setState(() {
        loading = true;
        failed = false;
      });
    }
    return load().then(
      (result) {
        if (!mounted || mine != generation) return;
        setState(() {
          data = result;
          updatedAt = DateTime.now();
          loading = false;
          pulled = false;
        });
      },
      onError: (Object _) {
        if (!mounted || mine != generation) return;
        setState(() {
          loading = false;
          failed = true;
          pulled = false;
        });
      },
    );
  }

  /// Pull to refresh: the indicator waits for the answer.
  Future<void> pullRefresh() {
    pulled = true;
    return refresh();
  }

  static String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => DuoRailPage(
    top: [
      DuoRailPage.back(context),
      DuoRailAction(
        id: 'refresh',
        icon: Icons.refresh,
        symbol: 'arrow.clockwise',
        label: '刷新状态',
        onPressed: refresh,
      ),
    ],
    child: Scaffold(
      appBar: AppBar(
        title: const Text('模型状态'),
        automaticallyImplyLeading: !DuoRailPage.active(context),
        actions: [
          if (!DuoRailPage.active(context))
            IconButton(
              tooltip: '刷新状态',
              onPressed: refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SoftBottomEdge(
        keyboardUp: SoftBottomEdge.keyboardShown(context),
        child: SafeArea(
          bottom: !SoftBottomEdge.active(context),
          child: content(context),
        ),
      ),
    ),
  );

  /// Loading, error and the list give way to each other with a short cross-fade.
  Widget content(BuildContext context) => AnimatedSwitcher(
    duration: motion(context),
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    layoutBuilder: (current, previous) =>
        Stack(fit: StackFit.expand, children: [...previous, ?current]),
    child: stateView(context),
  );

  Widget stateView(BuildContext context) {
    final snapshot = data;
    if (snapshot == null) {
      if (loading) {
        return const Center(
          key: ValueKey('status-loading'),
          child: JarvisSpinner.page(semanticsLabel: '正在读取模型状态'),
        );
      }
      return Center(
        key: const ValueKey('status-error'),
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
                onPressed: refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final entries = snapshot['data'] as List? ?? [];
    final memory = snapshot['mem_available_bytes'] as num?;
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
    final info = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: colors.onSurfaceVariant);
    final rows = entries.whereType<Map>().toList();
    final updated = updatedAt;
    return Stack(
      key: const ValueKey('status-list'),
      children: [
        LayoutBuilder(
          builder: (context, bounds) => RefreshIndicator.adaptive(
            onRefresh: pullRefresh,
            child: ListView(
              // Pulling down must work even when the list is shorter than the page.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                math.max(Metrics.pageMargin, (bounds.maxWidth - 720) / 2),
                Metrics.pageMargin,
                math.max(Metrics.pageMargin, (bounds.maxWidth - 720) / 2),
                Metrics.pageMargin + SoftBottomEdge.inset(context),
              ),
              children: [
                // The page's heading lines up with the settings section headings: 8 pt inside the cards' edge.
                Padding(
                  key: const Key('status-heading'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
                      Text('语音、图片和视频模型可以按需加载；未加载不表示聊天模型故障。', style: info),
                      if (memory != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '可用内存 ${(memory / 1073741824).toStringAsFixed(1)} GiB',
                            style: info,
                          ),
                        ),
                      if (updated != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text('更新于 ${clock(updated)}', style: info),
                        ),
                      // Eases in and out; the one error style of the app.
                      InlineError(
                        failed ? '刷新失败，显示的是上一次的状态' : null,
                        padding: const EdgeInsets.only(top: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Icon(
                          Icons.memory_outlined,
                          size: 28,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        const Text('服务暂未返回模型状态', textAlign: TextAlign.center),
                        const SizedBox(height: 4),
                        Text(
                          '稍后下拉刷新，或点刷新重试。',
                          textAlign: TextAlign.center,
                          style: info,
                        ),
                      ],
                    ),
                  )
                else
                  SettingsGroup(
                    // The hairlines start under the names, not under the dots.
                    dividerIndent: statusTextIndent,
                    children: [
                      for (final entry in rows)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          // The dot is 8 pt wide: the default 40 pt leading slot pushes the name away from it.
                          minLeadingWidth: 12,
                          horizontalTitleGap: 16,
                          leading: Icon(
                            Icons.circle,
                            size: 8,
                            color: switch (entry['state']) {
                              'ready' ||
                              'running' ||
                              'idle' => JarvisColors.success(context),
                              'loading' ||
                              'busy' => JarvisColors.warning(context),
                              'failed' || 'error' => colors.error,
                              _ => colors.outline,
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
              ],
            ),
          ),
        ),
        // A refresh keeps the list and only shows a thin bar along the top edge.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedSwitcher(
            duration: motion(context, 180),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SizeTransition(
                sizeFactor: animation,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
            child: loading && !pulled
                ? const LinearProgressIndicator(
                    key: ValueKey('status-bar'),
                    minHeight: 2,
                    semanticsLabel: '正在刷新模型状态',
                  )
                : const SizedBox(
                    key: ValueKey('status-no-bar'),
                    width: double.infinity,
                  ),
          ),
        ),
      ],
    );
  }
}

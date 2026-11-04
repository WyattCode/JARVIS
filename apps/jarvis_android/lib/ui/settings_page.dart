import '../model/conversation.dart';

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';

import '../state/jarvis_controller.dart';
import '../state/attachments.dart';
import '../state/backup.dart';
import 'media_widgets.dart';
import 'motion.dart';
import 'settings_widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final instructions = TextEditingController(
    text: widget.controller.settings.instructions,
  );
  late final prompt = TextEditingController(
    text: widget.controller.settings.transcriptionPrompt,
  );
  late final tokens = TextEditingController(
    text: widget.controller.settings.maxTokens == 0
        ? ''
        : widget.controller.settings.maxTokens.toString(),
  );
  String? tokenError;
  final tokenFieldKey = GlobalKey();

  /// Chip labels and the section each one jumps to.
  static const chipLabels = ['外观', '聊天', '语音', '数据'];
  final sectionKeys = List.generate(4, (_) => GlobalKey());
  final scrollKey = GlobalKey();
  final active = ValueNotifier<int>(0);
  final scrollController = ScrollController();
  bool jumping = false;
  int jumpEpoch = 0;
  bool previewExpanded = true;
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refreshVoiceCatalog());
  }

  @override
  void dispose() {
    instructions.dispose();
    prompt.dispose();
    tokens.dispose();
    active.dispose();
    scrollController.dispose();
    if (widget.controller.voice.previewing) {
      unawaited(widget.controller.voice.stopPreview());
    }
    super.dispose();
  }

  void dismissKeyboardOnTapOutside(PointerDownEvent event) =>
      FocusManager.instance.primaryFocus?.unfocus();

  void jumpTo(int i) {
    final target = sectionKeys[i].currentContext?.findRenderObject();
    if (target is! RenderBox || !scrollController.hasClients) return;
    final epoch = ++jumpEpoch;
    active.value = i;
    final position = scrollController.position;
    // Put the section just under the frosted bar, where it sits when the page is at rest.
    final reveal = RenderAbstractViewport.of(target)
        .getOffsetToReveal(target, 0)
        .offset;
    final to = reveal.clamp(position.minScrollExtent, position.maxScrollExtent);
    final duration = motion(context, 320);
    // While the jump runs the chip stays on the section that was tapped instead of sweeping through the ones passed.
    jumping = true;
    if (duration == Duration.zero) {
      position.jumpTo(to);
      jumping = false;
    } else {
      position
          .animateTo(to, duration: duration, curve: Curves.easeOutCubic)
          .whenComplete(() {
            if (mounted && epoch == jumpEpoch) jumping = false;
          });
    }
  }

  /// The chip of the section that is at the top of the scroll view (the last one when scrolled to the end).
  bool trackScroll(ScrollNotification n) {
    if (jumping || n.metrics.axis != Axis.vertical || n.depth != 0) {
      return false;
    }
    final scroll = scrollKey.currentContext?.findRenderObject();
    if (scroll is! RenderBox) return false;
    final top = scroll.localToGlobal(Offset.zero).dy;
    var current = 0;
    for (var i = 0; i < sectionKeys.length; i++) {
      final box = sectionKeys[i].currentContext?.findRenderObject();
      if (box is RenderBox && box.attached) {
        if (box.localToGlobal(Offset.zero).dy <= top + 40) {
          current = i;
        }
      }
    }
    if (n.metrics.extentAfter < 2) current = sectionKeys.length - 1;
    if (current != active.value) active.value = current;
    return false;
  }

  Future<void> deleteAll(JarvisController c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除全部会话？'),
        content: const Text('这会清除当前设备上的会话。建议先导出备份；正在进行的任务或通话需要先结束。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && !c.wipeConversations() && mounted) {
      showNotice(context, '请先结束通话或等待当前任务完成');
    }
  }

  Widget action(
    IconData icon,
    String title,
    VoidCallback onTap, {
    Color? color,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    minTileHeight: 52,
    leading: Icon(icon, color: color),
    title: Text(title, style: TextStyle(color: color)),
    onTap: onTap,
  );

  /// What the chat will look like with the current theme and text size: your messages in a bubble, the reply plain.
  Widget preview(JarvisController c) {
    final colors = Theme.of(context).colorScheme;
    final size = c.settings.messageFontSize;
    Widget message(String text, {required bool mine}) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: mine
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
            : const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: mine ? colors.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: TextStyle(fontSize: size, height: 1.65)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '实时预览',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '收起实时预览',
                onPressed: () => setState(() => previewExpanded = false),
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
              ),
            ],
          ),
        ),
        Container(
          key: const Key('settings-preview'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: .5),
            ),
          ),
          child: Column(
            spacing: 16,
            children: [
              message('帮我把这周的计划整理一下', mine: true),
              message('好的。这周有三件事：周一交方案，周三评审，周五发版。需要我按优先级排一下吗？', mine: false),
              message('排一下', mine: true),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> sections(
    JarvisController c, {
    required bool inlinePreview,
    required double viewportHeight,
  }) {
    final s = c.settings;
    final colors = Theme.of(context).colorScheme;
    final speech = c.models.where((m) => m.kind == 'speech').toList();
    final selected = speech.where((m) => m.id == s.speechModel).firstOrNull;
    final fontSizes = [12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0];
    final playing = c.voice.previewing;
    return [
      SettingsSection(
        sectionKey: sectionKeys[0],
        title: '外观',
        children: [ThemeSwatches(value: c.theme, onChanged: c.setTheme)],
      ),
      SettingsSection(
        sectionKey: sectionKeys[1],
        title: '聊天',
        footer: s.tools ? '打开后，助手可以在对话里直接生成图片和视频。' : null,
        children: [
          PickerRow<String>(
            label: '聊天模型',
            value: c.model,
            options: [
              for (final m in c.models.where((m) => m.kind == 'chat'))
                (m.id, displayModelName(m.name)),
            ],
            onSelected: c.setModel,
          ),
          PickerRow<String>(
            label: '思考深度',
            value: c.effort,
            options: const [
              ('none', '关闭'),
              ('low', '低'),
              ('medium', '中'),
              ('high', '高（默认）'),
            ],
            onSelected: c.setEffort,
          ),
          ToggleRow(
            title: '图片与视频工具',
            value: s.tools,
            onChanged: (v) => c.changeSettings((s) => s.tools = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('聊天字号', style: Theme.of(context).textTheme.bodyLarge),
                    const Spacer(),
                    Text(
                      '${s.messageFontSize.toInt()}${s.messageFontSize == 16 ? '（默认）' : ''}',
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
                Semantics(
                  label: '聊天字号',
                  child: Slider.adaptive(
                    key: const Key('message-font-size'),
                    activeColor: colors.primary,
                    value: s.messageFontSize.clamp(12.0, 24.0),
                    min: 12,
                    max: 24,
                    divisions: fontSizes.length - 1,
                    label: '${s.messageFontSize.toInt()}',
                    onChanged: (v) {
                      if (v != s.messageFontSize) {
                        HapticFeedback.selectionClick();
                      }
                      c.changeSettings((s) => s.messageFontSize = v);
                    },
                  ),
                ),
                if (inlinePreview)
                  Container(
                    key: const Key('settings-preview'),
                    margin: const EdgeInsets.only(top: 4, bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '预览：你好，我是 JARVIS。',
                      style: TextStyle(
                        fontSize: s.messageFontSize,
                        height: 1.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          FieldRow(
            key: tokenFieldKey,
            label: '回复长度上限（Token）',
            controller: tokens,
            hint: '模型默认',
            helper: '留空时使用模型默认值',
            error: tokenError,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onTapOutside: dismissKeyboardOnTapOutside,
            onChanged: (v) {
              final n = int.tryParse(v);
              if (v.isEmpty) {
                setState(() => tokenError = null);
                c.changeSettings((s) => s.maxTokens = 0);
              } else if (n != null && n >= 16 && n <= 32768) {
                setState(() => tokenError = null);
                c.changeSettings((s) => s.maxTokens = n);
              } else {
                final firstError = tokenError == null;
                setState(() => tokenError = '请输入16至32768，或留空');
                if (firstError) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted || tokenError == null) return;
                    final field = tokenFieldKey.currentContext;
                    if (field != null) {
                      Scrollable.ensureVisible(
                        field,
                        alignment: .12,
                        duration: motion(context, 220),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  });
                }
              }
            },
          ),
          FieldRow(
            label: '助手指令',
            controller: instructions,
            hint: '为助手设定角色或回答风格',
            minLines: 3,
            maxLines: 6,
            onTapOutside: dismissKeyboardOnTapOutside,
            onChanged: (v) => c.changeSettings((s) => s.instructions = v),
          ),
        ],
      ),
      SettingsSection(
        sectionKey: sectionKeys[2],
        title: '音色',
        children: [
          if (speech.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('服务当前没有提供语音引擎'),
            )
          else
            PickerRow<String>(
              label: '语音引擎',
              value: selected?.id,
              options: [
                for (final m in speech) (m.id, displayModelName(m.name)),
              ],
              onSelected: (v) {
                final m = speech.firstWhere((m) => m.id == v);
                c.changeSettings((s) {
                  s.speechModel = v;
                  s.voices.putIfAbsent(v, () => m.defaultVoice);
                });
              },
            ),
          if (selected != null)
            for (final v in selected.voices)
              ListTile(
                selected: s.voices[selected.id] == v.id,
                selectedColor: colors.onSurface,
                selectedTileColor: colors.surfaceContainerHigh,
                contentPadding: const EdgeInsets.only(left: 16, right: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: Icon(
                      s.voices[selected.id] == v.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 22,
                    ),
                  ),
                ),
                title: Text(v.name),
                subtitle: v.description.isEmpty ? null : Text(v.description),
                onTap: () =>
                    c.changeSettings((s) => s.voices[selected.id] = v.id),
                trailing: IconButton.filledTonal(
                  tooltip: playing && c.voice.previewVoice == v.id
                      ? '停止试听'
                      : '试听 ${v.name}',
                  iconSize: 20,
                  icon: Icon(
                    playing && c.voice.previewVoice == v.id
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  onPressed: () => playing && c.voice.previewVoice == v.id
                      ? c.voice.stopPreview()
                      : c.voice.playPreview(v, selected.id),
                ),
              ),
          if (selected != null &&
              !selected.voices.any((v) => v.id == s.voices[selected.id]))
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('所选音色暂不可用，请重新选择；不会自动替换为其他声音。'),
            ),
          if (c.voice.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                c.voice.error!,
                style: TextStyle(color: colors.error),
              ),
            ),
        ],
      ),
      SettingsSection(
        title: '语音识别',
        children: [
          PickerRow<String>(
            label: '识别语言',
            value: s.language,
            options: const [
              ('', '多语言自动'),
              ('zh', '中文'),
              ('en', '英语'),
              ('ja', '日语'),
              ('ko', '韩语'),
              ('fr', '法语'),
              ('de', '德语'),
              ('es', '西班牙语'),
            ],
            onSelected: (v) => c.changeSettings((s) => s.language = v),
          ),
          FieldRow(
            label: '常用词与专有名词',
            controller: prompt,
            hint: '例如：贾维斯，DGX Spark，TensorFold',
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            onTapOutside: dismissKeyboardOnTapOutside,
            onChanged: (v) =>
                c.changeSettings((s) => s.transcriptionPrompt = v),
          ),
        ],
      ),
      SettingsSection(
        title: '免按对话',
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '麦克风灵敏度',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const Spacer(),
                    Text(
                      '${(((.8 - s.threshold) / .6).clamp(0.0, 1.0) * 100).round()}%',
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
                Semantics(
                  label: '麦克风灵敏度',
                  child: Slider.adaptive(
                    key: const Key('threshold-slider'),
                    activeColor: colors.primary,
                    value: ((.8 - s.threshold) / .6).clamp(0.0, 1.0),
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: '${(((.8 - s.threshold) / .6) * 100).round()}%',
                    onChanged: (v) =>
                        c.changeSettings((s) => s.threshold = .8 - v * .6),
                  ),
                ),
              ],
            ),
          ),
          PickerRow<int>(
            label: '回答前等待时长',
            value: s.waitMs,
            options: [
              for (final n in [
                300,
                500,
                800,
                1000,
                1500,
                2000,
                3000,
                4000,
                5000,
              ])
                (n, n % 1000 == 0 ? '${n ~/ 1000} 秒' : '${n / 1000} 秒'),
            ],
            onSelected: (v) => c.changeSettings((s) => s.waitMs = v),
          ),
          ToggleRow(
            title: '回声抑制',
            subtitle: '避免把扬声器的回复识别为你的声音',
            value: s.echoCancel,
            onChanged: (v) => c.changeSettings((s) => s.echoCancel = v),
          ),
        ],
      ),
      ConstrainedBox(
        key: const Key('settings-data-page'),
        constraints: BoxConstraints(
          minHeight: (viewportHeight - 30).clamp(0.0, viewportHeight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              sectionKey: sectionKeys[3],
              title: '数据',
              children: [
                action(Icons.download_outlined, '导出会话备份', () async {
                  try {
                    final bytes = await c.exportBackup();
                    await NativeFiles.save(
                      bytes,
                      'jarvis-conversations-${DateTime.now().millisecondsSinceEpoch}.json',
                      'application/json',
                    );
                  } catch (_) {
                    if (mounted) showNotice(context, '备份未能导出，原资料保持不变');
                  }
                }),
                action(Icons.upload_file_outlined, '导入会话备份', () async {
                  try {
                    final count = await c.chooseImport();
                    if (mounted && count > 0) {
                      showNotice(context, '已导入 $count 个会话');
                    }
                  } catch (_) {
                    if (mounted) showNotice(context, '备份无法导入，原资料保持不变');
                  }
                }),
                action(
                  Icons.copy_outlined,
                  '复制诊断信息',
                  () => Clipboard.setData(ClipboardData(text: c.diagnostics())),
                ),
                action(
                  Icons.delete_outline,
                  '删除全部会话',
                  () => deleteAll(c),
                  color: colors.error,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: SettingsGroup(
                children: [
                  action(Icons.logout, '退出登录', () async {
                    // The application auth listener owns navigation.
                    // Popping here can remove the login route after an
                    // asynchronous logout finishes during route exit.
                    await c.logout();
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final edgeFade = compactSettings(context) ? 12.0 : SettingsChips.fade;
      final solid =
          MediaQuery.highContrastOf(context) ||
          MediaQuery.disableAnimationsOf(context);
      Widget bar(bool solid) {
        final scaffold = Theme.of(context).scaffoldBackgroundColor;
        // The frosted part sits behind the chips only. Below it a smooth tint melts into the page: one continuous
        // gradient (no steps), starting at the same strength as the bar so the two read as a single surface.
        const edge = .8;
        final chips = ColoredBox(
          color: solid ? scaffold : scaffold.withValues(alpha: edge),
          child: Center(
            child: ConstrainedBox(
              // 720 of cards plus their 20 pt side margins, which the chips apply themselves.
              constraints: const BoxConstraints(maxWidth: 760),
              child: SettingsChips(
                labels: chipLabels,
                active: active,
                onTap: jumpTo,
              ),
            ),
          ),
        );
        final top = solid ? 1.0 : edge;
        return Column(
          key: const Key('settings-chips-bar'),
          mainAxisSize: MainAxisSize.min,
          children: [
            solid
                ? chips
                : ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                      child: chips,
                    ),
                  ),
            IgnorePointer(
              child: Container(
                height: edgeFade,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    // An ease-out curve of the tint's strength, so it leaves the bar quickly and tails off softly.
                    colors: [
                      for (final k in const [1.0, .78, .55, .34, .17, .06, 0.0])
                        scaffold.withValues(alpha: top * k),
                    ],
                    stops: const [0, .14, .3, .5, .7, .88, 1],
                  ),
                ),
              ),
            ),
          ],
        );
      }

      // Reserve the pinned navigation area so focused/scroll-revealed rows remain tappable.
      Widget controls(bool wide) => LayoutBuilder(
        builder: (context, viewport) => Stack(
          children: [
            Positioned.fill(
              top: SettingsChips.height + edgeFade,
              child: KeyedSubtree(
                key: scrollKey,
                child: NotificationListener<ScrollNotification>(
                  onNotification: trackScroll,
                  child: SingleChildScrollView(
                    key: const Key('settings-scroll'),
                    controller: scrollController,

                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 30),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: sections(
                            c,
                            inlinePreview: !wide,
                            viewportHeight: viewport.maxHeight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(top: 0, left: 0, right: 0, child: bar(solid)),
          ],
        ),
      );
      return Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              // Android window constraints, independent of iPhone native fold reports.
              final twoPane =
                  box.maxWidth >= 840 &&
                  box.maxWidth > box.maxHeight &&
                  MediaQuery.viewInsetsOf(context).bottom == 0;
              if (!twoPane) return controls(false);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(
                    key: const Key('settings-preview-pane'),
                    duration: motion(context, 180),
                    curve: Curves.easeOutCubic,
                    width: previewExpanded ? box.maxWidth * .4 : 52,
                    child: LayoutBuilder(
                      builder: (context, pane) {
                        if (!previewExpanded || pane.maxWidth < 220) {
                          return Align(
                            alignment: Alignment.topCenter,
                            child: IconButton.filledTonal(
                              style: IconButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              tooltip: '展开实时预览',
                              onPressed: () =>
                                  setState(() => previewExpanded = true),
                              icon: const Icon(
                                Icons.view_sidebar_outlined,
                                size: 20,
                              ),
                            ),
                          );
                        }
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                          child: preview(c),
                        );
                      },
                    ),
                  ),
                  Expanded(child: controls(true)),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

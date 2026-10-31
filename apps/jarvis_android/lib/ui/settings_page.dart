import 'duo_rail.dart';
import '../model/conversation.dart';
import '../net/jarvis_api.dart' show JarvisException;
import 'keyboard_dismiss.dart';
import 'ios_scroll.dart';

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';

import '../state/jarvis_controller.dart';
import '../state/backup.dart';
import 'duo_layout.dart';
import 'design_tokens.dart';
import 'motion.dart';
import 'privacy_page.dart';
import 'settings_widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    this.onLogoutAndClear,
  });
  final JarvisController controller;

  /// Signs out and removes this device's conversations and files; false when nothing could be erased. The logout dialog
  /// offers 退出并清除本机数据 only when this is set (and the saved data is writable); whoever sets it also signs out (the
  /// page does not call `logout` on this path).
  final Future<bool> Function()? onLogoutAndClear;

  /// Opens the file picker (several files at once, as the export may have split the backup) and imports what was
  /// chosen. Null when the picker was cancelled, so that a backup without conversations (0) can be told apart from no
  /// backup at all.
  @visibleForTesting
  static Future<int?> Function(JarvisController c) pickBackup = _pickBackup;
  static Future<int?> _pickBackup(JarvisController c) => c.chooseImport();

  @override
  State<SettingsPage> createState() => _SettingsPageState();

  /// How many rows the page builds each frame while it slides in.
  static const rowsPerFrame = 3;
}

enum _Logout { cancel, keep, clear }

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
  final tokenFocus = FocusNode();
  Timer? tokenPause;

  /// The export or import that is running ('export' / 'import'): both buttons wait for it.
  String? dataJob;

  /// Chip labels and the section each one jumps to.
  static const chipLabels = ['外观', '聊天', '语音', '数据'];
  final sectionKeys = List.generate(4, (_) => GlobalKey());
  final scrollKey = GlobalKey();
  final active = ValueNotifier<int>(0);
  final scrollController = ScrollController();

  /// Whether rows have scrolled up under the chips: only then is there anything for the frosted bar to blur, so the
  /// blur (redone every frame the page moves, the push included) is off until then.
  final scrolled = ValueNotifier<bool>(false);
  bool jumping = false;
  @override
  void initState() {
    super.initState();
    tokenFocus.addListener(tokensBlur);
    scrollController.addListener(trackScrolled);
    // The voices are the server's: look them up again whenever the settings open.
    unawaited(widget.controller.refreshVoiceCatalog());
  }

  void trackScrolled() => scrolled.value =
      scrollController.hasClients && scrollController.offset > 0.5;

  @override
  void dispose() {
    tokenPause?.cancel();
    tokenFocus.removeListener(tokensBlur);
    tokenFocus.dispose();
    instructions.dispose();
    prompt.dispose();
    tokens.dispose();
    active.dispose();
    scrollController.removeListener(trackScrolled);
    scrollController.dispose();
    scrolled.dispose();
    if (widget.controller.voice.previewing) {
      unawaited(widget.controller.voice.stopPreview());
    }
    super.dispose();
  }

  void jumpTo(int i) {
    final target = sectionKeys[i].currentContext?.findRenderObject();
    if (target is! RenderBox || !scrollController.hasClients) return;
    HapticFeedback.selectionClick();
    active.value = i;
    final position = scrollController.position;
    // Put the section just under the frosted bar, where it sits when the page is at rest.
    final reveal = RenderAbstractViewport.of(target)
        .getOffsetToReveal(target, 0)
        .offset;
    final to = (reveal - SettingsChips.restInsetOf(context)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final duration = motion(context, 320);
    // While the jump runs the chip stays on the section that was tapped instead of sweeping through the ones passed.
    jumping = true;
    if (duration == Duration.zero) {
      position.jumpTo(to);
      jumping = false;
    } else {
      position
          .animateTo(to, duration: duration, curve: Curves.easeOutCubic)
          .whenComplete(() => jumping = false);
    }
  }

  /// The chip of the section that is at the top of the scroll view (the last one when scrolled to the end).
  bool trackScroll(ScrollNotification n) {
    if (jumping || n.metrics.axis != Axis.vertical || n.depth != 0) {
      return false;
    }
    // Measured after the frame: a notification can come during layout (a fling settling while the page relays out),
    // when the sections' positions are not to be read yet and may be stale.
    if (!trackPending) {
      trackPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        trackPending = false;
        if (mounted && !jumping) measureActive();
      });
    }
    return false;
  }

  bool trackPending = false;
  void measureActive() {
    final scroll = scrollKey.currentContext?.findRenderObject();
    if (scroll is! RenderBox ||
        !scroll.attached ||
        !scrollController.hasClients) {
      return;
    }
    final top = scroll.localToGlobal(Offset.zero).dy;
    var current = 0;
    for (var i = 0; i < sectionKeys.length; i++) {
      final box = sectionKeys[i].currentContext?.findRenderObject();
      if (box is RenderBox && box.attached) {
        if (box.localToGlobal(Offset.zero).dy <=
            top + SettingsChips.restInsetOf(context) + 40) {
          current = i;
        }
      }
    }
    if (scrollController.position.extentAfter < 2) {
      current = sectionKeys.length - 1;
    }
    if (current != active.value) active.value = current;
  }

  /// Running replies, media tasks or a call: the conversations cannot be removed while any of them is going.
  bool wipeBlocked(JarvisController c) =>
      c.voice.active ||
      c.conversations.any(
        (x) => c.isGenerating(x.id) || x.tasks.any((t) => t.pending),
      );

  Future<void> deleteAll(JarvisController c) async {
    const blocked = '请先结束通话或等待当前任务完成，再删除全部会话';
    if (wipeBlocked(c)) return showPageNotice(context, blocked);
    final confirmed = await showFoldDialog<bool>(
      context: context,
      builder: (context, insets) => AlertDialog(
        // Half-folded in landscape the dialog stays on one side of the crease.
        insetPadding: insets,
        title: const Text('删除全部会话？'),
        content: const Text('这会清除这台设备上的全部会话和附件，无法撤销。建议先导出备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除全部'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // A task can have started while the dialog was open.
    if (!c.wipeConversations()) return showPageNotice(context, blocked);
    unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
    showPageNotice(context, '已删除全部会话');
  }

  Future<void> confirmLogout(JarvisController c) async {
    // Erasing needs a writable saved file; the sign-out that keeps the data stays available.
    final clear = c.storageReadOnly ? null : widget.onLogoutAndClear;
    final choice = await showFoldDialog<_Logout>(
      context: context,
      builder: (context, insets) {
        // Three choices stack full width, the way iOS lays out an alert: the main one on top, 取消 at the bottom
        // (`actionsOverflowDirection: up` reverses the order below).
        final stacked = clear != null;
        final tall = stacked ? const Size.fromHeight(44) : null;
        return AlertDialog(
          insetPadding: insets,
          title: const Text('退出登录？'),
          content: const Text('退出后需要重新登录才能继续使用。会话仍保存在这台设备上；正在进行的任务和通话会被中断。'),
          actionsOverflowDirection: VerticalDirection.up,
          actionsOverflowAlignment: OverflowBarAlignment.center,
          actionsOverflowButtonSpacing: 8,
          actions: [
            TextButton(
              style: TextButton.styleFrom(minimumSize: tall),
              onPressed: () => Navigator.pop(context, _Logout.cancel),
              child: const Text('取消'),
            ),
            if (clear != null)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: tall,
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, _Logout.clear),
                child: const Text('退出并清除本机数据'),
              ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: tall),
              onPressed: () => Navigator.pop(context, _Logout.keep),
              child: const Text('退出登录'),
            ),
          ],
        );
      },
    );
    if (choice == _Logout.clear && clear != null && await confirmClear()) {
      final erased = await clear();
      if (!erased && mounted) {
        showPageNotice(context, '未能清除本机数据，请稍后重试');
      }
    }
    // The application auth listener owns navigation.
    // Popping here can remove the login route after an
    // asynchronous logout finishes during route exit.
    if (choice == _Logout.keep) await c.logout();
  }

  Future<bool> confirmClear() async {
    if (!mounted) return false;
    final confirmed = await showFoldDialog<bool>(
      context: context,
      builder: (context, insets) => AlertDialog(
        insetPadding: insets,
        title: const Text('清除本机数据？'),
        content: const Text('这台设备上的会话、附件和登录信息都会被删除，无法撤销。建议先导出备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出并清除'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Runs an export or import; a second tap while one is open does nothing (a second picker would report a false
  /// failure for the first).
  Future<void> runDataJob(String job, Future<void> Function() run) async {
    if (dataJob != null) return;
    setState(() => dataJob = job);
    try {
      await run();
    } finally {
      if (mounted) setState(() => dataJob = null);
    }
  }

  Future<void> exportBackup(JarvisController c) =>
      runDataJob('export', () async {
        try {
          final parts = await c.exportAndSaveBackup();
          if (!mounted || parts == 0) return;
          final skipped = c.backupSkipped.length;
          if (parts > 1) {
            showPageNotice(context, '备份较大，已分成 $parts 个文件，导入时可一次选全');
          } else if (skipped > 0) {
            showPageNotice(context, '已导出，$skipped 个附件无法读取，已跳过');
          }
        } on JarvisException catch (e) {
          if (mounted) showPageNotice(context, e.message);
        } catch (_) {
          if (mounted) showPageNotice(context, '备份未能导出，原资料保持不变');
        }
      });

  Future<void> importBackup(JarvisController c) =>
      runDataJob('import', () async {
        try {
          final count = await SettingsPage.pickBackup(c);
          if (!mounted || count == null) return;
          showPageNotice(context, count > 0 ? '已导入 $count 个会话' : '没有可导入的会话');
        } on JarvisException catch (e) {
          if (mounted) showPageNotice(context, e.message);
        } catch (_) {
          if (mounted) showPageNotice(context, '备份无法导入，原资料保持不变');
        }
      });

  /// The token limit as typed: 0 for empty (the model's default), null when it is neither empty nor 16 to 32768.
  static int? parseTokens(String v) {
    if (v.isEmpty) return 0;
    final n = int.tryParse(v);
    return n != null && n >= 16 && n <= 32768 ? n : null;
  }

  void tokensChanged(String v) {
    tokenPause?.cancel();
    final n = parseTokens(v);
    if (n != null) {
      setState(() => tokenError = null);
      widget.controller.changeSettings((s) => s.maxTokens = n);
      return;
    }
    // "1" and "10" on the way to "1024" are not mistakes: the error waits for a pause in typing.
    tokenPause = Timer(const Duration(milliseconds: 800), () {
      if (mounted && parseTokens(tokens.text) == null) {
        setState(() => tokenError = '请输入16至32768，或留空');
      }
    });
  }

  /// Leaving the field with a value that was never applied puts the saved one back, so the field never shows
  /// something that is not in effect.
  void tokensBlur() {
    if (tokenFocus.hasFocus) return;
    tokenPause?.cancel();
    if (parseTokens(tokens.text) == null) {
      final saved = widget.controller.settings.maxTokens;
      tokens.text = saved == 0 ? '' : saved.toString();
    }
    if (tokenError != null && mounted) setState(() => tokenError = null);
  }

  /// A row of the 数据 card. A null [onTap] greys it out; [busy] (what is running, e.g. '正在导出') swaps the title for
  /// '正在导出…' and puts a small spinner at its end; [chevron] marks a row that opens a page.
  Widget action(
    IconData icon,
    String title,
    VoidCallback? onTap, {
    Color? color,
    String? busy,
    bool chevron = false,
  }) {
    final tint = onTap == null && color != null
        ? color.withValues(alpha: Metrics.disabledOpacity)
        : color;
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minTileHeight: 52,
      // The icon is 22 pt in a 24 pt slot: the text starts at 56, where the dividers do.
      minLeadingWidth: 24,
      leading: Icon(icon, size: 22, color: tint),
      title: Text(
        busy == null ? title : '$busy…',
        style: TextStyle(color: tint),
      ),
      trailing: busy != null
          ? JarvisSpinner.button(semanticsLabel: busy)
          : chevron
          ? Icon(Icons.chevron_right, size: 20, color: colors.onSurfaceVariant)
          : null,
      enabled: onTap != null,
      onTap: onTap,
    );
  }

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
          borderRadius: BorderRadius.circular(Radii.large),
        ),
        child: Text(text, style: TextStyle(fontSize: size, height: 1.65)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            '实时预览',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          key: const Key('settings-preview'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.large),
            border: Border.all(color: SettingsGroup.line(context, colors)),
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

  /// The next font size up or down on the slider's 12-24 scale (steps of 2).
  static double stepSize(double size, int direction) =>
      ((size / 2).round() * 2.0 + direction * 2).clamp(12.0, 24.0);

  List<Widget> sections(JarvisController c, {required bool inlinePreview}) {
    final s = c.settings;
    final colors = Theme.of(context).colorScheme;
    final speech = c.models.where((m) => m.kind == 'speech').toList();
    final selected = speech.where((m) => m.id == s.speechModel).firstOrNull;
    final fontSizes = [12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0];
    final light = colors.brightness == Brightness.light;
    // The default track all but vanishes on the card: white in the light theme (#e7eeec), near black in the dark one.
    final inactiveTrack = colors.onSurfaceVariant.withValues(
      alpha: light ? .3 : .5,
    );
    final previewError = previewErrorOf(c.voice);
    return [
      SettingsSection(
        sectionKey: sectionKeys[0],
        title: '外观',
        children: [ThemeSwatches(value: c.theme, onChanged: c.setTheme)],
      ),
      SettingsSection(
        sectionKey: sectionKeys[1],
        title: '聊天',
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
            subtitle: '打开后，助手可以在对话里直接生成图片和视频。',
            value: s.tools,
            onChanged: (v) => c.changeSettings((s) => s.tools = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SliderHeader(
                  title: '聊天字号',
                  value:
                      '${s.messageFontSize.toInt()}${s.messageFontSize == 16 ? '（默认）' : ''}',
                ),
                // VoiceOver reads the font size, not the slider's 0-100% position, and steps by one size.
                Semantics(
                  label: '聊天字号',
                  value: '${s.messageFontSize.toInt()}',
                  increasedValue: '${stepSize(s.messageFontSize, 1).toInt()}',
                  decreasedValue: '${stepSize(s.messageFontSize, -1).toInt()}',
                  onIncrease: () => c.changeSettings(
                    (s) => s.messageFontSize = stepSize(s.messageFontSize, 1),
                  ),
                  onDecrease: () => c.changeSettings(
                    (s) => s.messageFontSize = stepSize(s.messageFontSize, -1),
                  ),
                  excludeSemantics: true,
                  child: SettingsSlider(
                    child: Slider.adaptive(
                      key: const Key('message-font-size'),
                      activeColor: colors.primary,
                      inactiveColor: inactiveTrack,
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
                      // Inset into the card: a step darker than the white card in light, the page colour in dark.
                      color: light ? colors.surfaceContainer : colors.surface,
                      borderRadius: BorderRadius.circular(Radii.small),
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
            label: '回复长度上限（Token）',
            controller: tokens,
            hint: '模型默认',
            helper: '留空时使用模型默认值',
            error: tokenError,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            focusNode: tokenFocus,
            textInputAction: TextInputAction.done,
            // The iOS number pad has no Done key.
            labelAction: ListenableBuilder(
              listenable: tokenFocus,
              builder: (context, _) => tokenFocus.hasFocus
                  ? TextButton(
                      key: const Key('tokens-done'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        // The label line is exactly 44 pt: no extra tap-target padding to grow the row.
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: tokenFocus.unfocus,
                      child: const Text('完成'),
                    )
                  : const SizedBox.shrink(),
            ),
            onTapUpOutside: dismissKeyboardOnTapUpOutside,
            onChanged: tokensChanged,
          ),
          FieldRow(
            label: '助手指令',
            controller: instructions,
            hint: '为助手设定角色或回答风格',
            minLines: 3,
            maxLines: 6,
            onTapUpOutside: dismissKeyboardOnTapUpOutside,
            onChanged: (v) => c.changeSettings((s) => s.instructions = v),
          ),
        ],
      ),
      SettingsSection(
        sectionKey: sectionKeys[2],
        title: '语音与音色',
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
              VoiceChoiceRow(
                name: v.name,
                description: v.description,
                selected: s.voices[selected.id] == v.id,
                playing: VoicePreviewState.of(c.voice, v.id).playing,
                loading: VoicePreviewState.of(c.voice, v.id).loading,
                onSelect: () =>
                    c.changeSettings((s) => s.voices[selected.id] = v.id),
                onPlay: () => VoicePreviewState.of(c.voice, v.id).stops
                    ? c.voice.stopPreview()
                    : c.voice.playPreview(v, selected.id),
              ),
          if (selected != null &&
              !selected.voices.any((v) => v.id == s.voices[selected.id]))
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('所选音色暂不可用，请重新选择；不会自动替换为其他声音。'),
            ),
          if (previewError != null)
            InlineError(
              previewError,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
            hint: '例如：贾维斯，常用人名、产品名',
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            onTapUpOutside: dismissKeyboardOnTapUpOutside,
            onChanged: (v) =>
                c.changeSettings((s) => s.transcriptionPrompt = v),
          ),
          // Echo cancellation shapes what the microphone hears in both modes, not only hands-free.
          ToggleRow(
            title: '回声抑制',
            subtitle: '避免把扬声器的回复识别为你的声音',
            value: s.echoCancel,
            onChanged: (v) => c.changeSettings((s) => s.echoCancel = v),
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
                SliderHeader(
                  title: '麦克风灵敏度',
                  value:
                      '${(((.8 - s.threshold) / .6).clamp(0.0, 1.0) * 100).round()}%',
                ),
                Semantics(
                  label: '麦克风灵敏度',
                  child: SettingsSlider(
                    child: Slider.adaptive(
                      key: const Key('threshold-slider'),
                      activeColor: colors.primary,
                      inactiveColor: inactiveTrack,
                      value: ((.8 - s.threshold) / .6).clamp(0.0, 1.0),
                      min: 0,
                      max: 1,
                      divisions: 20,
                      label: '${(((.8 - s.threshold) / .6) * 100).round()}%',
                      onChanged: (v) {
                        if (v != ((.8 - s.threshold) / .6).clamp(0.0, 1.0)) {
                          HapticFeedback.selectionClick();
                        }
                        c.changeSettings((s) => s.threshold = .8 - v * .6);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          PickerRow<int>(
            label: '停顿多久算说完',
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
        ],
      ),
      SettingsSection(
        sectionKey: sectionKeys[3],
        title: '数据',
        dividerIndent: SettingsGroup.iconIndent,
        children: [
          action(
            Icons.download_outlined,
            '导出会话备份',
            dataJob == null ? () => exportBackup(c) : null,
            busy: dataJob == 'export' ? '正在导出' : null,
          ),
          action(
            Icons.upload_file_outlined,
            '导入会话备份',
            dataJob == null ? () => importBackup(c) : null,
            busy: dataJob == 'import' ? '正在导入' : null,
          ),
          action(Icons.copy_outlined, '复制诊断信息', () async {
            await Clipboard.setData(ClipboardData(text: c.diagnostics()));
            if (mounted) showPageNotice(context, '诊断信息已复制');
          }),
          action(
            Icons.privacy_tip_outlined,
            '隐私与数据使用',
            chevron: true,
            () => unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'privacy'),
                  builder: (_) => PrivacyPage(controller: c),
                ),
              ),
            ),
          ),
          action(
            Icons.delete_outline,
            '删除全部会话',
            dataJob == null ? () => deleteAll(c) : null,
            color: colors.error,
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 22),
        child: SettingsGroup(
          children: [
            action(
              Icons.logout,
              '退出登录',
              dataJob == null ? () => confirmLogout(c) : null,
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
      final layout = DuoLayoutScope.of(context);
      final division = layout.regions
          .where((r) => r.kind == DuoRegionKind.division)
          .firstOrNull
          ?.rect;
      // Inner display, landscape: the fold splits the page in two. Preview on the left half, controls on the right.
      // The fold is in screen coordinates; the page starts after a strip on the left edge.
      final origin = layout.edge == DuoBarEdge.left ? layout.barWidth : 0.0;
      final foldedLandscape =
          layout.hasVerticalBar &&
          layout.size.width > layout.size.height &&
          division != null &&
          division.height > division.width;
      // Reduce Transparency / Increase Contrast: the bar turns solid (its lower edge still fades out).
      final solid =
          layout.reduceTransparency || MediaQuery.highContrastOf(context);
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
                : ValueListenableBuilder<bool>(
                    valueListenable: scrolled,
                    builder: (context, under, chips) => ClipRect(
                      child: BackdropFilter(
                        enabled: under,
                        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                        child: chips,
                      ),
                    ),
                    child: chips,
                  ),
            IgnorePointer(
              child: Container(
                height: SettingsChips.fade,
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

      // The chips are a frosted bar over the page: rows scroll up under it, blurred, instead of vanishing at a line.
      Widget controls(bool wide) => Stack(
        children: [
          Positioned.fill(
            child: KeyedSubtree(
              key: scrollKey,
              child: NotificationListener<ScrollNotification>(
                onNotification: trackScroll,
                child: SingleChildScrollView(
                  key: const Key('settings-scroll'),
                  controller: scrollController,
                  physics: iosScrollPhysics,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    Metrics.pageMargin,
                    SettingsChips.restInsetOf(context),
                    Metrics.pageMargin,
                    30 + SoftBottomEdge.inset(context),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: _StagedRows(
                        children: sections(c, inlinePreview: !wide),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: bar(solid)),
        ],
      );
      return DuoRailPage(
        top: [DuoRailPage.back(context)],
        child: Scaffold(
          appBar: AppBar(
            title: const Text('设置'),
            automaticallyImplyLeading: !DuoRailPage.active(context),
          ),
          body: SoftBottomEdge(
            keyboardUp: SoftBottomEdge.keyboardShown(context),
            child: SafeArea(
              bottom: !SoftBottomEdge.active(context),
              child: LayoutBuilder(
                builder: (context, box) {
                  // A layout report that lags behind a rotation must not squeeze the page: both panes need room.
                  final left = foldedLandscape ? division.left - origin : 0.0;
                  final twoPane =
                      foldedLandscape &&
                      left >= 240 &&
                      box.maxWidth - left - division.width >= 300;
                  if (!twoPane) return controls(false);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: left,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            Metrics.pageMargin,
                            8,
                            Metrics.pageMargin,
                            30,
                          ),
                          child: preview(c),
                        ),
                      ),
                      SizedBox(width: division.width),
                      Expanded(child: controls(true)),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The settings column, built a few rows a frame while the page slides in.
///
/// Built at once, the page's first frame went well over a 120 Hz frame, and a whole section a frame still did now and
/// then (a text field, a list of voices), so the push dropped frames. Only this column rebuilds as rows are added, and
/// the rows already built are the same widgets, so each frame costs only its new rows. The first screenful is in by
/// the third frame, while the page has moved only a few points onto the screen; the rest is below it. Once the slide
/// ends whatever is left is built at once.
class _StagedRows extends StatefulWidget {
  const _StagedRows({required this.children});
  final List<Widget> children;
  @override
  State<_StagedRows> createState() => _StagedRowsState();
}

class _StagedRowsState extends State<_StagedRows> {
  /// Frames since the push began; [builtAll] once everything is in.
  int stage = 1 << 30;
  bool stagingChecked = false;
  static const builtAll = 1 << 30;

  /// The rows built at [stage], counting each section's rows in order (see [budgeted]).
  int get rowsBuilt =>
      stage == builtAll ? builtAll : (stage + 1) * SettingsPage.rowsPerFrame;

  /// [all] cut to its first [rows] rows: whole sections while they fit, then the first rows of the next one.
  static List<Widget> budgeted(List<Widget> all, int rows) {
    final out = <Widget>[];
    var left = rows;
    for (final w in all) {
      if (left <= 0) break;
      if (w is SettingsSection && w.children.length > left) {
        out.add(
          SettingsSection(
            key: w.key,
            sectionKey: w.sectionKey,
            title: w.title,
            dividerIndent: w.dividerIndent,
            children: w.children.take(left).toList(),
          ),
        );
        left = 0;
      } else {
        out.add(w);
        left -= w is SettingsSection ? w.children.length.clamp(1, 1 << 20) : 1;
      }
    }
    return out;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (stagingChecked) return;
    stagingChecked = true;
    // The first frame of a push lays the page out offstage, where its animation reads as complete.
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    final pushing =
        route != null &&
        (route.offstage || animation?.status == AnimationStatus.forward);
    if (!pushing ||
        animation == null ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    stage = 0;
    void finish() {
      if (mounted && stage != builtAll) setState(() => stage = builtAll);
    }

    void landed(AnimationStatus status) {
      if (status != AnimationStatus.completed || route.offstage) return;
      animation.removeStatusListener(landed);
      finish();
    }

    animation.addStatusListener(landed);
    void next(Duration _) {
      if (!mounted || stage == builtAll) return;
      setState(() => stage++);
      WidgetsBinding.instance.addPostFrameCallback(next);
    }

    WidgetsBinding.instance.addPostFrameCallback(next);
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.children;
    final built = budgeted(all, rowsBuilt);
    if (built.length == all.length &&
        identical(built.lastOrNull, all.lastOrNull) &&
        stage != builtAll) {
      // Everything is in: no more staging frames.
      stage = builtAll;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: built,
    );
  }
}

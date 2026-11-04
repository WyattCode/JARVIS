import 'completed_works.dart';
import 'action_menu.dart';
import 'audio_waveform.dart';

import 'dart:async';

import '../model/fold_proportions.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/jarvis_controller.dart';
import 'voice_identity_stage.dart';
import 'login_art.dart' show ReactorMode;
import 'call_controls.dart';
import 'voice_mode_selector.dart';
import 'voice_picker.dart';
import 'follow_scroll.dart';

class VoicePage extends StatefulWidget {
  const VoicePage({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<VoicePage> createState() => _VoicePageState();
}

/// Keep one call view during reversible transitions, including a quick reopen.
class VoiceOverlay extends StatefulWidget {
  const VoiceOverlay({super.key, required this.controller, required this.open});
  final JarvisController controller;
  final bool open;
  @override
  State<VoiceOverlay> createState() => _VoiceOverlayState();
}

class _VoiceOverlayState extends State<VoiceOverlay>
    with SingleTickerProviderStateMixin {
  late bool retained = widget.open;
  late final AnimationController transition =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 180),
        value: widget.open ? 1 : 0,
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed &&
            !widget.open &&
            retained &&
            mounted) {
          setState(() => retained = false);
        }
      });
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    transition.duration = Duration(
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 180,
    );
  }

  @override
  void didUpdateWidget(VoiceOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open == widget.open) return;
    if (widget.open) {
      retained = true;
      transition.forward();
    } else {
      transition.reverse();
    }
  }

  @override
  void dispose() {
    transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !retained
      ? const SizedBox.shrink()
      : ExcludeSemantics(
          excluding: !widget.open,
          child: ExcludeFocus(
            excluding: !widget.open,
            child: IgnorePointer(
              ignoring: !widget.open,
              child: FadeTransition(
                opacity: transition,
                child: SlideTransition(
                  position:
                      Tween<Offset>(
                            begin: const Offset(0, .015),
                            end: Offset.zero,
                          )
                          .chain(CurveTween(curve: Curves.easeOutCubic))
                          .animate(transition),
                  child: TickerMode(
                    enabled: widget.open,
                    child: VoicePage(controller: widget.controller),
                  ),
                ),
              ),
            ),
          ),
        );
}

class _VoicePageState extends State<VoicePage> with WidgetsBindingObserver {
  final textScroll = FollowScrollController();
  Object? identityOwner;
  bool hasTranscript = false;
  final sources = <Object>{};
  void beginHold() {
    final v = widget.controller.voice;
    final wasHeld = v.held;
    unawaited(v.hold());
    if (!wasHeld && v.held) {
      // Use the system's light touch effect; haptics must never block capture.
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    }
  }

  void down(Object source) {
    final v = widget.controller.voice;
    if (!v.ready || widget.controller.settings.voiceMode != 'ptt') return;
    if (!v.held) sources.clear();
    final first = sources.isEmpty;
    sources.add(source);
    if (first) beginHold();
  }

  void up(Object source, {bool cancel = false}) {
    if (!sources.remove(source) || sources.isNotEmpty) return;
    if (cancel) {
      widget.controller.voice.cancelHold();
    } else {
      widget.controller.voice.release();
    }
  }

  void cancelPress() {
    sources.clear();
    if (widget.controller.voice.held) widget.controller.voice.cancelHold();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.of(context)?.isCurrent == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == false) {
          cancelPress();
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) cancelPress();
  }

  bool keyboard(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) return false;
    final allowed =
        widget.controller.voice.open &&
        ModalRoute.of(context)?.isCurrent != false &&
        widget.controller.settings.voiceMode == 'ptt' &&
        !JarvisActionMenu.isOpen;
    // A key released after focus moved must still end/cancel our own hold.
    if (event is KeyUpEvent && sources.contains('space')) {
      up('space', cancel: !allowed);
      return true;
    }
    if (!allowed) return false;
    if (event is KeyDownEvent) {
      down('space');
      return true;
    }
    return event is KeyRepeatEvent && sources.contains('space');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(keyboard);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(keyboard);
    WidgetsBinding.instance.removeObserver(this);
    textScroll.dispose();
    if (widget.controller.voice.held) widget.controller.voice.cancelHold();
    super.dispose();
  }

  Future<void> recoverVoice() async {
    final v = widget.controller.voice, owner = widget.controller.voice.owner;
    if (owner == null) return;
    await v.stop();
    if (mounted) await v.start(owner);
  }

  Widget header(bool short, bool compactWorks) {
    final v = widget.controller.voice;
    final recovery = short && v.needsRecovery;
    final showWorks = compactWorks && v.owner?.tasks.isNotEmpty == true;
    final extras = recovery || showWorks;
    final sideWidth = extras ? 96.0 : 48.0;
    final name =
        v.speech?.voices.where((x) => x.id == v.voice).firstOrNull?.name ??
        v.voice;
    return SizedBox(
      height: short ? 48 : 56,
      child: Row(
        children: [
          SizedBox(
            width: sideWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: '收起通话界面',
                onPressed: v.minimize,
                icon: const Icon(Icons.expand_more, size: 20),
              ),
            ),
          ),
          Expanded(
            child: TextButton(
              key: const Key('voice-name'),
              onPressed: () => showVoicePicker(context, widget.controller),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.graphic_eq, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      name.isEmpty ? '选择音色' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, size: 16),
                ],
              ),
            ),
          ),
          SizedBox(
            width: sideWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (extras)
                  JarvisActionMenu(
                    tooltip: '更多通话操作',
                    actions: [
                      if (recovery)
                        const JarvisMenuAction(
                          'recover',
                          '恢复语音',
                          icon: Icons.refresh,
                        ),
                      if (showWorks)
                        const JarvisMenuAction(
                          'works',
                          '生成作品',
                          icon: Icons.collections_outlined,
                        ),
                    ],
                    onSelected: (value) {
                      if (value == 'works') {
                        works();
                      } else {
                        unawaited(recoverVoice());
                      }
                    },
                  ),
                HangupButton(onPressed: v.stop),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget transcript() {
    final v = widget.controller.voice;
    return textScroll.wrap(
      SingleChildScrollView(
        key: const Key('voice-transcript'),
        controller: textScroll,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (v.lastYou.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SelectableText(
                  '“${v.lastYou}”',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: widget.controller.settings.messageFontSize,
                    height: 1.5,
                  ),
                ),
              ),
            if (v.lastBot.isNotEmpty)
              SelectableText(
                v.lastBot,
                style: TextStyle(
                  fontSize: widget.controller.settings.messageFontSize,
                  height: 1.6,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget controls(bool short) {
    final c = widget.controller, v = c.voice;
    final ptt = c.settings.voiceMode == 'ptt';
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    const energy = Color(0xff8fdceb);
    final ink = v.held ? const Color(0xff152126) : colors.onSurface;
    void accessibleToggle() {
      sources.clear();
      if (v.held) {
        v.release();
      } else {
        beginHold();
      }
    }

    final accessibility = MediaQuery.accessibleNavigationOf(context);
    final label = !v.ready
        ? (v.error == null ? '等待连接' : '等待恢复')
        : ptt
        ? (v.held ? '松开发送' : '按住说话')
        : (v.muted ? '已静音' : '正在聆听');
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, short ? 6 : 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth:
              FoldProportions.isFold(
                MediaQuery.sizeOf(context).width,
                MediaQuery.sizeOf(context).height,
              )
              ? FoldProportions.voiceActionWidth(
                  FoldProportions.voiceWidth(
                    MediaQuery.sizeOf(context).width,
                    MediaQuery.sizeOf(context).height,
                    paneWidth:
                        MediaQuery.sizeOf(context).width -
                        MediaQuery.paddingOf(context).horizontal,
                  ),
                )
              : 360,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoiceModeSelector(
              value: c.settings.voiceMode,
              onChanged: (mode) {
                sources.clear();
                v.cancelHold();
                c.changeSettings((s) => s.voiceMode = mode);
              },
            ),
            SizedBox(height: short ? 6 : 10),
            Listener(
              key: const Key('voice-talk'),
              onPointerDown: (e) {
                if (ptt) down(e.pointer);
              },
              onPointerUp: (e) {
                if (ptt) up(e.pointer);
              },
              onPointerCancel: (e) => up(e.pointer, cancel: true),
              child: Semantics(
                button: true,
                label: label,
                hint: ptt
                    ? accessibility
                          ? (v.held ? '双击结束录音并发送' : '双击开始录音，再次双击发送')
                          : '长按说话，松开发送'
                    : '',
                enabled: v.ready,
                onTap: ptt && v.ready ? accessibleToggle : null,
                onLongPress: ptt && v.ready ? accessibleToggle : null,
                child: AnimatedOpacity(
                  opacity: v.ready ? 1 : .5,
                  duration: Duration(
                    milliseconds: MediaQuery.disableAnimationsOf(context)
                        ? 0
                        : 120,
                  ),
                  child: AnimatedScale(
                    scale: v.held ? .96 : 1,
                    curve: Curves.easeOutCubic,
                    duration: Duration(
                      milliseconds: MediaQuery.disableAnimationsOf(context)
                          ? 0
                          : (v.held ? 80 : 160),
                    ),
                    child: AnimatedContainer(
                      key: const Key('voice-hold-surface'),
                      curve: Curves.easeOutCubic,
                      duration: Duration(
                        milliseconds: MediaQuery.disableAnimationsOf(context)
                            ? 0
                            : (v.held ? 80 : 160),
                      ),
                      constraints: BoxConstraints(minHeight: short ? 48 : 56),
                      decoration: BoxDecoration(
                        gradient: v.held
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color.lerp(energy, Colors.white, .20)!,
                                  energy,
                                  Color.lerp(
                                    energy,
                                    const Color(0xff408eac),
                                    .12,
                                  )!,
                                ],
                              )
                            : null,
                        color: v.held
                            ? energy
                            : dark
                            ? const Color(0xff242426)
                            : colors.surfaceContainerHigh,
                        border: Border.all(
                          color: v.held
                              ? Color.lerp(energy, Colors.white, .55)!
                              : colors.outline.withValues(alpha: .8),
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: v.held
                            ? [
                                BoxShadow(
                                  color: energy.withValues(alpha: .34),
                                  blurRadius: 22,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: !ptt && v.ready ? v.toggleMute : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                v.muted
                                    ? Icons.mic_off_outlined
                                    : v.held
                                    ? Icons.mic_rounded
                                    : Icons.mic_none,
                                size: 22,
                                color: ink,
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: ink,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void works() {
    unawaited(
      showGeneratedWorks(
        context,
        widget.controller,
        conversationId: widget.controller.voice.conversationId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, v = c.voice;
      if (identityOwner != v.conversationId) {
        identityOwner = v.conversationId;
        hasTranscript = false;
      }
      hasTranscript =
          hasTranscript ||
          v.held ||
          v.lastYou.isNotEmpty ||
          v.lastBot.isNotEmpty;
      textScroll.followLatest();
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) {
              final compact = hasTranscript || bounds.maxHeight < 480;
              final window = MediaQuery.sizeOf(context);
              final fold = FoldProportions.isFold(window.width, window.height);
              final voiceWidth = fold
                  ? FoldProportions.voiceWidth(
                      window.width,
                      window.height,
                      paneWidth: bounds.maxWidth,
                    )
                  : bounds.maxWidth - 40;
              return Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal:
                          FoldProportions.isFold(window.width, window.height)
                          ? bounds.maxWidth * .02
                          : 0,
                    ),
                    child: header(
                      bounds.maxHeight < 500,
                      bounds.maxHeight < 420,
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: voiceWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: VoiceIdentityStage(
                            key: ValueKey('voice-identity-${v.conversationId}'),
                            compact: compact,
                            windowHeight: bounds.maxHeight,
                            identity: v.conversationId,
                            minimumTranscriptExtent:
                                (MediaQuery.textScalerOf(context).scale(
                                              c.settings.messageFontSize,
                                            ) *
                                            1.6 +
                                        16)
                                    .clamp(48.0, 200.0)
                                    .toDouble(),
                            status: v.needsRecovery ? '需要恢复语音' : v.status,
                            hint: v.error ?? v.hint,
                            mode: v.expressing
                                ? ReactorMode.speaking
                                : v.thinking
                                ? ReactorMode.thinking
                                : v.ready &&
                                      !v.muted &&
                                      (v.held || c.settings.voiceMode == 'vad')
                                ? ReactorMode.listening
                                : ReactorMode.idle,
                            onTap: v.interrupt,
                            waveform: AudioWaveform(levels: v.levels),
                            transcript: transcript(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (v.needsRecovery && bounds.maxHeight >= 500)
                    TextButton.icon(
                      onPressed: recoverVoice,
                      icon: const Icon(Icons.refresh),
                      label: const Text('恢复语音'),
                    ),
                  controls(bounds.maxHeight < 500),
                  if (v.owner?.tasks.isNotEmpty == true &&
                      bounds.maxHeight >= 420) ...[
                    const Divider(height: 1),
                    ListTile(
                      dense: true,
                      title: Text('生成作品 · ${v.owner!.tasks.length}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: works,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

import 'action_menu.dart';
import 'completed_works.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/jarvis_controller.dart';
import '../voice/audio_levels.dart';
import 'audio_waveform.dart';
import 'call_wave_glow.dart';
import 'call_mode_toggle.dart';
import 'call_talk_button.dart';
import '../model/fold_proportions.dart';
import 'login_art.dart' show ReactorMode;
import 'spoken_text_view.dart';
import 'voice_identity_stage.dart';
import 'voice_picker.dart';

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
        duration: const Duration(milliseconds: 380),
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
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 380,
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
              // A full-screen modal: it slides up from the bottom edge, and
              // down again when it goes.
              child: SlideTransition(
                position:
                    Tween<Offset>(
                      begin: const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: transition,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      ),
                    ),
                child: TickerMode(
                  enabled: widget.open,
                  child: VoicePage(controller: widget.controller),
                ),
              ),
            ),
          ),
        );
}

/// The call page, laid out as the iOS app's: the reactor with the status and
/// the level bars above, the last turn's words under them (what you said in a
/// pill on the right, the reply plain and lit as the voice says it), the round
/// talk button below; the buttons (minimize, works, voice, the way of talking)
/// in a bar along the top, or in a strip at the side when held sideways, and
/// the cross that ends the call at the corner. A tap anywhere else holds
/// JARVIS's voice, and the next one lets it go on.
class _VoicePageState extends State<VoicePage> with WidgetsBindingObserver {
  final transcriptScroll = ScrollController();
  final transcriptKey = GlobalKey();

  /// The words are brought to the sentence being said; for a few seconds after
  /// a hand has moved them they are left alone.
  DateTime handMoved = DateTime.fromMillisecondsSinceEpoch(0);
  int pointersDown = 0;
  String shownYou = '';
  Object? identityOwner;
  bool hasTranscript = false;
  final sources = <Object>{};
  void beginHold() {
    final v = widget.controller.voice;
    final wasHeld = v.held;
    unawaited(v.hold());
    if (!wasHeld && v.held) {
      // Use the system's light touch effect; haptics must never block capture.
      unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
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
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
      widget.controller.voice.release();
    }
  }

  void cancelPress() {
    sources.clear();
    if (widget.controller.voice.held) widget.controller.voice.cancelHold();
  }

  /// A tap holds JARVIS's voice while it speaks; the next one lets it go on
  /// from the same word.
  void togglePause() {
    if (widget.controller.voice.togglePlaybackPause()) {
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    }
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
    transcriptScroll.dispose();
    if (widget.controller.voice.held) widget.controller.voice.cancelHold();
    super.dispose();
  }

  Future<void> recoverVoice() async {
    final v = widget.controller.voice, owner = widget.controller.voice.owner;
    if (owner == null) return;
    await v.stop();
    if (mounted) await v.start(owner);
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

  void chooseMode(String mode) {
    sources.clear();
    final c = widget.controller;
    c.voice.cancelHold();
    c.changeSettings((s) => s.voiceMode = mode);
  }

  /// Brings the line the voice is on to about a quarter of the way down the
  /// words, a line at a time, unless a hand has just moved them (then the words
  /// are left to be read where they are, and the next line after a pause takes
  /// them back).
  void follow(Rect line) {
    if (!transcriptScroll.hasClients || pointersDown > 0) return;
    if (DateTime.now().difference(handMoved) < const Duration(seconds: 3)) {
      return;
    }
    final box = transcriptKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final position = transcriptScroll.position;
    final top = box.localToGlobal(Offset.zero).dy;
    final target =
        (position.pixels + (line.top - (top + box.size.height * .25))).clamp(
          0.0,
          position.maxScrollExtent,
        );
    if ((target - position.pixels).abs() <= 2) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      transcriptScroll.jumpTo(target);
    } else {
      unawaited(
        transcriptScroll.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Widget youPill(String text, double size) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(left: 48),
        child: DecoratedBox(
          key: const Key('voice-you'),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: colors.outlineVariant, width: .5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Text(
              text,
              style: TextStyle(fontSize: size, color: colors.onSurface),
            ),
          ),
        ),
      ),
    );
  }

  Widget transcript() {
    final c = widget.controller, v = c.voice;
    final size = c.settings.messageFontSize;
    if (shownYou != v.lastYou) {
      shownYou = v.lastYou;
      // A new turn starts at the top of its words.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && transcriptScroll.hasClients) {
          transcriptScroll.jumpTo(0);
        }
      });
    }
    final scroll = Listener(
      onPointerDown: (_) {
        pointersDown++;
        handMoved = DateTime.now();
      },
      onPointerUp: (_) {
        pointersDown = math.max(0, pointersDown - 1);
        handMoved = DateTime.now();
      },
      onPointerCancel: (_) {
        pointersDown = math.max(0, pointersDown - 1);
        handMoved = DateTime.now();
      },
      child: SingleChildScrollView(
        key: const Key('voice-transcript'),
        controller: transcriptScroll,
        child: KeyedSubtree(
          key: transcriptKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (v.lastYou.isNotEmpty) youPill(v.lastYou, size),
              if (v.lastYou.isNotEmpty && v.lastBot.isNotEmpty)
                const SizedBox(height: 20),
              if (v.lastBot.isNotEmpty)
                SpokenTextView(
                  text: v.lastBot,
                  size: size,
                  progress: () => v.speechProgress,
                  onLine: follow,
                ),
            ],
          ),
        ),
      ),
    );
    // The words fade where they go on past the edge of the area: at the top
    // once they are scrolled, at the bottom while there is more below.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
        return false;
      },
      child: AnimatedBuilder(
        animation: transcriptScroll,
        builder: (context, child) {
          final p = transcriptScroll.hasClients
              ? transcriptScroll.position
              : null;
          final top = p == null ? 0.0 : math.min(28.0, math.max(0.0, p.pixels));
          final bottom = p == null
              ? 0.0
              : math.min(28.0, math.max(0.0, p.maxScrollExtent - p.pixels));
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              final h = rect.height;
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [
                  Colors.transparent,
                  Colors.black,
                  Colors.black,
                  Colors.transparent,
                ],
                stops: [0, h > 0 ? top / h : 0, h > 0 ? 1 - bottom / h : 1, 1],
              ).createShader(rect);
            },
            child: child,
          );
        },
        child: scroll,
      ),
    );
  }

  Widget talk() {
    final c = widget.controller, v = c.voice;
    final ptt = c.settings.voiceMode == 'ptt';
    final muted = v.mutedInVad;
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
        : (muted ? '已静音' : '正在聆听');
    return Listener(
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
        label: !ptt && v.ready ? (muted ? '取消静音' : '静音') : label,
        value: !ptt && v.ready ? label : null,
        hint: ptt
            ? accessibility
                  ? (v.held ? '双击结束录音并发送' : '双击开始录音，再次双击发送')
                  : '长按说话，松开发送'
            : '',
        enabled: v.ready,
        onTap: ptt && v.ready ? accessibleToggle : null,
        onLongPress: ptt && v.ready ? accessibleToggle : null,
        // The talk button keeps its own touches: a tap on it is not the tap
        // that holds JARVIS's voice.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: !ptt && v.ready
              ? () {
                  unawaited(
                    HapticFeedback.mediumImpact().catchError((Object _) {}),
                  );
                  v.toggleMute();
                }
              : () {},
          child: CallTalkButton(
            ptt: ptt,
            ready: v.ready,
            held: v.held,
            muted: muted,
            listening: !ptt && v.ready && !muted,
          ),
        ),
      ),
    );
  }

  Widget barButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Key? key,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    iconSize: 20,
    style: IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      fixedSize: const Size(44, 44),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
    ),
    icon: Icon(icon),
  );

  String voiceName() {
    final v = widget.controller.voice;
    return v.speech?.voices.where((x) => x.id == v.voice).firstOrNull?.name ??
        v.voice;
  }

  /// The buttons of the call, besides minimize and the cross: recovering a lost
  /// voice and the generated works when there are any, the voice, and the way
  /// of talking.
  List<Widget> barItems({required bool vertical}) {
    final c = widget.controller, v = c.voice;
    final name = voiceName();
    final tasks = v.owner?.tasks.length ?? 0;
    final recover = v.needsRecovery
        ? barButton(
            key: const Key('voice-recover'),
            tooltip: '恢复语音',
            icon: Icons.refresh,
            onPressed: () => unawaited(recoverVoice()),
          )
        : null;
    final works = tasks > 0
        ? barButton(
            key: const Key('voice-works'),
            tooltip: '作品 · $tasks',
            icon: Icons.photo_library_outlined,
            onPressed: this.works,
          )
        : null;
    final voice = barButton(
      key: const Key('voice-name'),
      tooltip: '音色：${name.isEmpty ? '未选择' : name}',
      icon: Icons.volume_up_outlined,
      onPressed: () => showVoicePicker(context, c),
    );
    final mode = CallModeToggle(
      key: const Key('voice-mode'),
      ptt: c.settings.voiceMode == 'ptt',
      horizontal: !vertical,
      onChanged: chooseMode,
    );
    // The switch, then the voice, the works and recovering joined in one glass
    // capsule (left to right along the top, top to bottom along the side), as
    // iOS stacks its bar items.
    return [
      mode,
      _BarCluster(vertical: vertical, children: [voice, ?works, ?recover]),
    ];
  }

  Widget minimizeButton() => barButton(
    key: const Key('voice-minimize'),
    tooltip: '收起通话界面',
    icon: Icons.expand_more,
    onPressed: widget.controller.voice.minimize,
  );

  /// The cross that ends the call: a plain cross, not a telephone.
  Widget closeButton() {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      key: const Key('voice-close'),
      tooltip: '结束语音通话',
      onPressed: widget.controller.voice.stop,
      style: IconButton.styleFrom(
        backgroundColor: colors.onSurface,
        foregroundColor: colors.surface,
        minimumSize: const Size(48, 48),
        fixedSize: const Size(48, 48),
        shape: const CircleBorder(),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      icon: const Icon(Icons.close, size: 22),
    );
  }

  /// The light behind the call, in two directions: JARVIS's cyan comes down
  /// from the top edge and swells with its voice; yours rises from the bottom
  /// edge, pale silver, and swells with yours; at rest only a faint cyan at the
  /// foot.
  Widget glow(bool vad, bool muted) {
    final v = widget.controller.voice;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final jarvis = dark ? const Color(0xff8fdceb) : const Color(0xff137589);
    final silver = dark ? const Color(0xffe0e0e0) : const Color(0xff596b80);
    return ValueListenableBuilder<AudioLevels>(
      valueListenable: v.levels,
      builder: (context, levels, _) {
        // How bright each light is, and how loud the sound that shapes it
        // (the level bars' own scaling: 9 for the reply, 14 for the
        // microphone).
        var topBright = 0.0, topLevel = 0.0;
        var bottomBright = .1, bottomLevel = 0.0;
        var bottom = jarvis;
        if (v.expressing || levels.playing) {
          topBright = math.min(.62, .26 + levels.output * 6);
          topLevel = math.min(1.0, levels.output * 9);
          bottomBright = 0;
        } else if (v.held || (vad && v.ready && !muted && levels.input > .02)) {
          bottom = silver;
          bottomBright = math.min(.5, .2 + levels.input * 8);
          bottomLevel = math.min(1.0, levels.input * 14);
        }
        return Stack(
          children: [
            Positioned.fill(
              child: CallWaveGlow(
                fromTop: true,
                color: jarvis,
                intensity: topBright,
                level: topLevel,
              ),
            ),
            Positioned.fill(
              child: CallWaveGlow(
                fromTop: false,
                color: bottom,
                intensity: bottomBright,
                level: bottomLevel,
              ),
            ),
          ],
        );
      },
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
          hasTranscript || v.lastYou.isNotEmpty || v.lastBot.isNotEmpty;
      final ptt = c.settings.voiceMode == 'ptt', vad = !ptt;
      final muted = v.mutedInVad;
      // "已就绪" alone says nothing to someone who has not spoken yet:
      // hands-free it is listening, push-to-talk it asks for the button.
      final idle = v.status == '已就绪';
      final staleMute = !vad && v.muted && v.status == '已静音';
      final next = v.needsRecovery
          ? '需要恢复语音'
          : v.ready && idle
          ? (vad ? '正在聆听' : '按住按钮说话')
          : staleMute
          ? '按住按钮说话'
          : v.status;
      final status = v.playbackPaused ? '已暂停' : next;
      final hint = v.playbackPaused
          ? '再点一下继续'
          : v.error ?? (staleMute || (v.ready && idle && !vad) ? '' : v.hint);
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final landscape =
                bounds.maxWidth > bounds.maxHeight &&
                FoldProportions.isFold(bounds.maxWidth, bounds.maxHeight);
            final short = bounds.maxHeight < 520;
            final compact = hasTranscript || bounds.maxHeight < 480;
            Widget stage(double width) => Center(
              child: SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: VoiceIdentityStage(
                    key: ValueKey('voice-identity-${v.conversationId}'),
                    compact: compact,
                    windowHeight: bounds.maxHeight,
                    identity: v.conversationId,
                    minimumTranscriptExtent:
                        (MediaQuery.textScalerOf(context)
                                        .scale(c.settings.messageFontSize) *
                                    1.6 +
                                16)
                            .clamp(48.0, 200.0)
                            .toDouble(),
                    status: status,
                    hintIsError: v.error != null,
                    hint: hint,
                    mode: v.expressing
                        ? ReactorMode.speaking
                        : v.thinking
                        ? ReactorMode.thinking
                        : v.ready && !muted && (v.held || vad)
                        ? ReactorMode.listening
                        : ReactorMode.idle,
                    onTap: togglePause,
                    waveform: AudioWaveform(levels: v.levels),
                    transcript: transcript(),
                  ),
                ),
              ),
            );
            // The words and the talk button. Sideways in a short window (a
            // phone on its side) the words need the room, so the button
            // stands at the left, low, and the words take the rest.
            Widget body = LayoutBuilder(
              builder: (context, area) {
                final width = math.min(area.maxWidth - 56, 760.0);
                if (short) {
                  return Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 28, bottom: 12),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: talk(),
                        ),
                      ),
                      Expanded(
                        child: stage(
                          math.max(0.0, area.maxWidth - 28 - 80 - 20 - 28),
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(child: stage(width)),
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 28),
                      child: talk(),
                    ),
                  ],
                );
              },
            );
            final Widget content;
            if (landscape) {
              // Held sideways the buttons stand in a strip at the right edge.
              content = Row(
                children: [
                  Expanded(child: body),
                  SizedBox(
                    width: 64,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          minimizeButton(),
                          const SizedBox(height: 8),
                          for (final item in barItems(vertical: true)) ...[
                            item,
                            const SizedBox(height: 8),
                          ],
                          const Spacer(),
                          closeButton(),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            } else {
              content = Stack(
                children: [
                  Column(
                    children: [
                      SizedBox(
                        height: 56,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              minimizeButton(),
                              const Spacer(),
                              for (final item in barItems(vertical: false)) ...[
                                const SizedBox(width: 4),
                                item,
                              ],
                            ],
                          ),
                        ),
                      ),
                      Expanded(child: body),
                    ],
                  ),
                  Positioned(right: 16, bottom: 16, child: closeButton()),
                ],
              );
            }
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: togglePause,
              child: Stack(
                children: [
                  Positioned.fill(child: glow(vad, muted)),
                  SafeArea(child: content),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

/// The voice, the works and recovering, joined in one glass capsule (as iOS
/// joins neighbouring bar items).
class _BarCluster extends StatelessWidget {
  const _BarCluster({required this.vertical, required this.children});
  final bool vertical;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.onSurface.withValues(alpha: dark ? .12 : .07),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: .5),
              width: .5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: vertical
                ? Column(mainAxisSize: MainAxisSize.min, children: children)
                : Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

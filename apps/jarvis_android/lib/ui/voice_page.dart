import 'duo_layout.dart';
import 'duo_rail.dart';
import 'ios_scroll.dart';
import 'completed_works.dart';
import 'action_menu.dart';
import 'audio_waveform.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/adaptive_layout.dart';
import '../model/media.dart';
import '../state/jarvis_controller.dart';
import '../state/system_settings.dart';
import 'jarvis_app.dart' show reportCallFailure;
import 'voice_identity_stage.dart';
import 'login_art.dart' show ReactorMode;
import 'call_controls.dart';
import 'voice_mode_selector.dart';
import 'voice_picker.dart';
import 'follow_scroll.dart';
import 'design_tokens.dart';
import 'motion.dart';

class VoicePage extends StatefulWidget {
  const VoicePage({
    super.key,
    required this.controller,
    this.hidden = false,
    this.railHosted = false,
    this.onCancelTask,
    this.openSettings,
  });
  final JarvisController controller;

  /// The vertical strip (iPhone Duo) is drawn by the host page, which swaps its buttons for [voiceCallRail] while the
  /// call is open, so the one native strip lives through the call opening and closing instead of being replaced.
  final bool railHosted;

  /// Given to the cards of the generated-works sheet, see [showGeneratedWorks]. Default: cancel through the controller.
  final void Function(MediaTask task)? onCancelTask;

  /// Opens the app's page in the system settings. Default: [openAppSettings].
  final Future<void> Function()? openSettings;

  /// The call is closing: the (native) side strip cannot fade with the page, so it is removed at once.
  final bool hidden;
  @override
  State<VoicePage> createState() => _VoicePageState();
}

/// Keep one call view during reversible transitions, including a quick reopen.
class VoiceOverlay extends StatefulWidget {
  const VoiceOverlay({
    super.key,
    required this.controller,
    required this.open,
    this.onCancelTask,
    this.openSettings,
  });
  final JarvisController controller;
  final bool open;

  /// Handed to [VoicePage]; both default there when null.
  final void Function(MediaTask task)? onCancelTask;
  final Future<void> Function()? openSettings;
  @override
  State<VoiceOverlay> createState() => _VoiceOverlayState();
}

class _VoiceOverlayState extends State<VoiceOverlay>
    with SingleTickerProviderStateMixin {
  late bool retained = widget.open;
  late final AnimationController transition =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 320),
        reverseDuration: const Duration(milliseconds: 260),
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
    // Reduce Motion: the call page appears and goes at once.
    transition.duration = motion(context, 320);
    transition.reverseDuration = motion(context, 260);
  }

  /// The page rises from the bottom edge and sinks back to it.
  late final Animation<Offset> position =
      Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: transition,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      );

  /// It becomes opaque over the first part of the way up (and clear again over the last part of the way down).
  late final Animation<double> fade = CurvedAnimation(
    parent: transition,
    curve: const Interval(0, .5, curve: Curves.easeOut),
  );

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
                opacity: fade,
                child: SlideTransition(
                  position: position,
                  child: TickerMode(
                    enabled: widget.open,
                    child: VoicePage(
                      controller: widget.controller,
                      hidden: !widget.open,
                      railHosted: true,
                      onCancelTask: widget.onCancelTask,
                      openSettings: widget.openSettings,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
}

/// Hands-free and ready: the stage's status line and the talk button name this state in the same words.
const listeningLabel = '正在聆听';

/// Pulling the call page down by this far, or flicking it faster than [voiceDragVelocity], minimizes it.
const voiceDragDistance = 120.0, voiceDragVelocity = 700.0;

bool shouldMinimizeOnDrag(double distance, double velocity) =>
    distance > voiceDragDistance || velocity > voiceDragVelocity;

/// Opens the sheet of generated works from the call.
void openCallWorks(
  BuildContext context,
  JarvisController controller, {
  void Function(MediaTask task)? onCancelTask,
  Future<void> Function()? openSettings,
}) {
  unawaited(
    showGeneratedWorks(
      context,
      controller,
      onCancelTask:
          onCancelTask ?? (task) => unawaited(controller.cancelMediaTask(task)),
      openSettings: openSettings ?? openAppSettings,
    ),
  );
}

/// Restarts a call that lost its voice; the reason is shown if that fails too.
Future<void> recoverCall(
  BuildContext context,
  JarvisController controller, {
  Future<void> Function()? openSettings,
}) async {
  final v = controller.voice;
  if (v.owner == null) return;
  // The call page stays open while it restarts; when the restart fails the reason is shown, not a vanished page.
  final ok = await v.recover();
  if (!ok && context.mounted) {
    reportCallFailure(
      context,
      controller,
      openSettings: openSettings ?? openAppSettings,
    );
  }
}

/// The buttons of the vertical strip while the call is open: the dismissing control on top, the destructive one alone at
/// the bottom so a thumb aimed at either cannot hit the other; page actions sit under collapse. The home page hands these
/// to its own strip (one long-lived native view) and the strip animates from its set of buttons to these.
({List<DuoRailAction> top, List<DuoRailAction> bottom}) voiceCallRail(
  BuildContext context,
  JarvisController controller, {
  void Function(MediaTask task)? onCancelTask,
  Future<void> Function()? openSettings,
}) {
  final v = controller.voice;
  return (
    top: [
      DuoRailAction(
        id: 'collapse',
        icon: Icons.expand_more,
        symbol: 'chevron.down',
        label: '收起通话界面',
        onPressed: v.minimize,
      ),
      if (v.needsRecovery)
        DuoRailAction(
          id: 'recover',
          icon: Icons.refresh,
          symbol: 'arrow.clockwise',
          label: '恢复语音',
          onPressed: () => unawaited(
            recoverCall(context, controller, openSettings: openSettings),
          ),
        ),
      if (v.owner?.tasks.isNotEmpty == true)
        DuoRailAction(
          id: 'works',
          icon: Icons.collections_outlined,
          symbol: 'photo.on.rectangle',
          label: '生成作品',
          onPressed: () => openCallWorks(
            context,
            controller,
            onCancelTask: onCancelTask,
            openSettings: openSettings,
          ),
        ),
    ],
    // The native strip taps the hang-up button with its own (medium) haptic.
    bottom: [
      DuoRailAction(
        id: 'hangup',
        icon: Icons.call_end,
        symbol: 'phone.down.fill',
        label: '结束语音通话',
        onPressed: v.stop,
        hangup: true,
      ),
    ],
  );
}

class _VoicePageState extends State<VoicePage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final textScroll = FollowScrollController();
  Object? identityOwner;
  String lastTurnYou = '';
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
      final v = widget.controller.voice, wasHeld = v.held;
      v.release();
      if (wasHeld) {
        unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
      }
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
    settle.dispose();
    dragY.dispose();
    textScroll.dispose();
    if (widget.controller.voice.held) widget.controller.voice.cancelHold();
    super.dispose();
  }

  Future<void> recoverVoice() => recoverCall(
    context,
    widget.controller,
    openSettings: widget.openSettings,
  );

  /// Ends the call with a tick under the finger, before the session winds down.
  void hangUp() {
    tapFeedback(strong: true);
    unawaited(widget.controller.voice.stop());
  }

  // Pulling the header or the stage down minimizes the call: the page follows the finger and fades, then either goes
  // (far enough or flicked) or springs back. The transcript is left out: it scrolls.
  final dragY = ValueNotifier<double>(0);
  double settleFrom = 0;
  late final AnimationController settle = AnimationController(vsync: this)
    ..addListener(
      () => dragY.value =
          settleFrom * (1 - Curves.easeOutCubic.transform(settle.value)),
    );

  void dragStart(DragStartDetails _) => settle.stop();

  void dragUpdate(DragUpdateDetails details) {
    settle.stop();
    dragY.value = math.max(0.0, dragY.value + details.delta.dy);
  }

  void dragEnd(DragEndDetails details) {
    final leave = shouldMinimizeOnDrag(
      dragY.value,
      details.velocity.pixelsPerSecond.dy,
    );
    if (leave) widget.controller.voice.minimize();
    dragSettle(leave);
  }

  void dragSettle([bool leaving = false]) {
    settleFrom = dragY.value;
    final duration = motion(context, leaving ? 260 : 300);
    if (settleFrom == 0 || duration == Duration.zero) {
      dragY.value = 0;
      return;
    }
    settle.duration = duration;
    unawaited(settle.forward(from: 0));
  }

  Widget dragSurface(Widget child) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: dragStart,
    onVerticalDragUpdate: dragUpdate,
    onVerticalDragEnd: dragEnd,
    onVerticalDragCancel: dragSettle,
    child: child,
  );

  /// Room above the header. Foldable iPhone: the header's centre sits on the chat header's axis
  /// ([DuoLayout.headerAxisY] below the safe area's top), so the title does not jump between chat and call. Elsewhere,
  /// with no top inset (a phone on its side) the pill and hang-up keep 10 pt off the screen edge.
  double headerTop(bool short, double topInset) {
    final duo = DuoLayoutScope.of(context);
    if (duo.isFoldable) {
      return math.max(0.0, duo.headerAxisY - headerHeight(short) / 2);
    }
    return topInset > 0 ? 0 : 10;
  }

  static double headerHeight(bool short) => short ? 48 : 56;

  Widget header(bool short, bool compactWorks, {bool hangupBelow = false}) {
    final v = widget.controller.voice;
    final recovery = short && v.needsRecovery;
    final showWorks = compactWorks && v.owner?.tasks.isNotEmpty == true;
    final extras = recovery || showWorks;
    // iPhone Duo: close and end-call live in the system's vertical strip instead of the header corners.
    final rail = DuoLayoutScope.of(context).hasVerticalBar;
    // A plain phone in portrait carries hang up at the bottom of the page, in reach of the thumb.
    final hangup = !rail && !hangupBelow;
    final sideWidth = rail ? 16.0 : (extras && hangup ? 96.0 : 48.0);
    final name =
        v.speech?.voices.where((x) => x.id == v.voice).firstOrNull?.name ??
        v.voice;
    void pickVoice() => showVoicePicker(context, widget.controller);
    // At large text the pill is taller than the bar: the bar grows with it.
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: headerHeight(short)),
      child: Row(
        children: [
          SizedBox(
            width: sideWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: rail
                  ? null
                  : IconButton(
                      tooltip: '收起通话界面',
                      onPressed: v.minimize,
                      icon: const Icon(Icons.expand_more, size: 20),
                    ),
            ),
          ),
          Expanded(
            // The button is as wide as its content, so only the name itself is a target (not the whole row).
            child: Center(
              child: Semantics(
                button: true,
                label: '音色：${name.isEmpty ? '未选择' : name}',
                hint: '选择音色',
                excludeSemantics: true,
                onTap: pickVoice,
                child: TextButton(
                  key: const Key('voice-name'),
                  onPressed: pickVoice,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: const StadiumBorder(),
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHigh,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
            ),
          ),
          SizedBox(
            width: sideWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (extras && !rail)
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
                if (hangup) HangupButton(onPressed: hangUp),
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
        physics: iosScrollPhysics,
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

  Widget controls(bool short, {bool last = false}) {
    final c = widget.controller, v = c.voice;
    final ptt = c.settings.voiceMode == 'ptt';
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    // The held button is a pale cyan fill in both themes (dark ink on it); the accent token is for text-like uses.
    const energy = Color(0xff8fdceb);
    // Muting is a hands-free feature: a mute left over from that mode says nothing in push-to-talk.
    final muted = v.mutedInVad;
    // Muted reads at a glance: the label, the icon and the outline turn to the error tint.
    final ink = v.held
        ? const Color(0xff152126)
        : muted
        ? colors.error
        : colors.onSurface;
    void accessibleToggle() {
      sources.clear();
      if (v.held) {
        v.release();
      } else {
        beginHold();
      }
    }

    // Foldable iPhone: when the controls are the last thing on the page they sit flush to the bottom edge with the
    // same 20pt as the sides (the home-indicator inset is not added on top).
    final bottomGap = last && DuoLayoutScope.of(context).isFoldable
        ? 20.0
        : (short ? 6.0 : 8.0);
    final accessibility = MediaQuery.accessibleNavigationOf(context);
    final label = !v.ready
        ? (v.error == null ? '等待连接' : '等待恢复')
        : ptt
        ? (v.held ? '松开发送' : '按住说话')
        : (muted ? '已静音' : listeningLabel);
    void toggleMute() {
      HapticFeedback.selectionClick();
      v.toggleMute();
    }

    final selector = VoiceModeSelector(
      short: short,
      value: c.settings.voiceMode,
      onChanged: (mode) {
        sources.clear();
        v.cancelHold();
        c.changeSettings((s) => s.voiceMode = mode);
      },
    );
    final talk = Listener(
      key: const Key('voice-talk'),
      onPointerDown: (e) {
        if (ptt) down(e.pointer);
      },
      onPointerUp: (e) {
        if (ptt) up(e.pointer);
      },
      onPointerCancel: (e) => up(e.pointer, cancel: true),
      // One node for the whole button: the visible text is not read a second time. In VAD mode a tap mutes, so the
      // label says that and the listening state is the value.
      child: Semantics(
        container: true,
        excludeSemantics: true,
        button: true,
        label: !ptt && v.ready ? (muted ? '取消静音' : '静音') : label,
        value: !ptt && v.ready ? label : null,
        hint: ptt
            ? accessibility
                  ? (v.held ? '双击结束录音并发送' : '双击开始录音，再次双击发送')
                  : '长按说话，松开发送'
            : '',
        enabled: v.ready,
        onTap: v.ready ? (ptt ? accessibleToggle : toggleMute) : null,
        onLongPress: ptt && v.ready ? accessibleToggle : null,
        child: AnimatedOpacity(
          opacity: v.ready ? 1 : Metrics.disabledOpacity,
          duration: motion(context, 120),
          child: AnimatedScale(
            scale: v.held ? .96 : 1,
            curve: Curves.easeOutCubic,
            duration: motion(context, v.held ? 80 : 160),
            child: AnimatedContainer(
              key: const Key('voice-hold-surface'),
              curve: Curves.easeOutCubic,
              duration: motion(context, v.held ? 80 : 160),
              // As tall as the mode selector beside or above it.
              constraints: BoxConstraints(
                minHeight: VoiceModeSelector.heightFor(short),
              ),
              decoration: BoxDecoration(
                gradient: v.held
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.lerp(energy, Colors.white, .20)!,
                          energy,
                          Color.lerp(energy, const Color(0xff408eac), .12)!,
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
                      : muted
                      ? colors.error
                      : colors.outline.withValues(
                          alpha: MediaQuery.highContrastOf(context) ? 1 : .8,
                        ),
                  width: muted && !v.held ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(Radii.large),
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
              // The surface paints its own fill: the ripple needs a Material of its own above it.
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.large - 2),
                  onTap: !ptt && v.ready ? toggleMute : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedSwitcher(
                          duration: motion(context, 150),
                          transitionBuilder: popTransition,
                          child: Icon(
                            muted
                                ? Icons.mic_off_outlined
                                : v.held
                                ? Icons.mic_rounded
                                : Icons.mic_none,
                            key: ValueKey(
                              muted
                                  ? 'muted'
                                  : v.held
                                  ? 'held'
                                  : 'idle',
                            ),
                            size: 22,
                            color: ink,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: AnimatedSwitcher(
                            duration: motion(context, 150),
                            transitionBuilder: popTransition,
                            child: Text(
                              label,
                              key: ValueKey(label),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: ink,
                              ),
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
    );
    // Half-folded in landscape: keep the controls off the fold, mode choice on one side and the talk button on the other.
    final duo = DuoLayoutScope.of(context), fold = duo.verticalFold;
    if (fold != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, bottomGap),
        child: LayoutBuilder(
          builder: (context, bounds) {
            // This page starts at the left safe inset; the padding adds 20 on each side.
            final left = fold.left - duo.safe.left - 20,
                right = bounds.maxWidth - (fold.right - duo.safe.left - 20);
            if (left < 140 || right < 140) {
              return stacked(selector, talk, short);
            }
            return Row(
              key: const Key('voice-controls-fold-split'),
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: left,
                  // Same width cap as the stacked layout, so both controls read as one size.
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: selector,
                    ),
                  ),
                ),
                SizedBox(width: bounds.maxWidth - left - right),
                SizedBox(width: right, child: talk),
              ],
            );
          },
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, bottomGap),
      // A phone on its side is wide and low: the two controls share one row instead of using up the height.
      child: short && !duo.isFoldable
          ? LayoutBuilder(
              builder: (context, bounds) => bounds.maxWidth < 560
                  ? stacked(selector, talk, short)
                  : Row(
                      key: const Key('voice-controls-side-by-side'),
                      children: [
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 360),
                              child: selector,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: talk),
                      ],
                    ),
            )
          : stacked(selector, talk, short),
    );
  }

  Widget stacked(Widget selector, Widget talk, bool short) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 360),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        selector,
        SizedBox(height: short ? 6 : 10),
        talk,
      ],
    ),
  );

  void works() => openCallWorks(
    context,
    widget.controller,
    onCancelTask: widget.onCancelTask,
    openSettings: widget.openSettings,
  );

  /// Unfolded foldable: the call content is as wide as the chat column with the session list collapsed.
  double columnInset(BuildContext context, double available) {
    final size = MediaQuery.sizeOf(context);
    final duo = DuoLayoutScope.of(context);
    // Half-folded: the controls are laid out around the fold across the full width.
    if (!duo.isFoldable ||
        size.shortestSide < 600 ||
        duo.verticalFold != null) {
      return 0;
    }
    // `available` is already inside the safe area; the chat sizes its sidebar from the window minus those insets.
    final layout = AdaptiveLayout.forWindow(
      size.width,
      size.height,
      horizontalInsets: size.width - available,
    );
    // Same column as the chat: docked windows use the collapsed (wider) pane, portrait windows the plain pane.
    final width = layout.docked
        ? DuoLayout.collapsedColumnWidth(available, layout.sidebarWidth)
        : available * DuoLayout.unfoldedContentFactor;
    // The chat composer sits edgeGap inside its column; this page already pads 20.
    return math.max(0.0, (available - width) / 2 + DuoLayout.edgeGap - 20);
  }

  /// Half-folded in landscape: the side margin that keeps a full-width element of this page off the crease, on the
  /// roomier side. This page starts at the left safe inset and is [width] wide.
  EdgeInsets foldSide(double width) {
    final fold = DuoLayoutScope.of(context).verticalFold;
    if (fold == null) return EdgeInsets.zero;
    final origin = MediaQuery.paddingOf(context).left;
    final leftRoom = fold.left - origin,
        rightRoom = width - (fold.right - origin);
    if (math.max(leftRoom, rightRoom) < 240) return EdgeInsets.zero;
    return rightRoom >= leftRoom
        ? EdgeInsets.only(left: fold.right - origin)
        : EdgeInsets.only(right: width - (fold.left - origin));
  }

  Widget stage(double windowHeight, bool compact) {
    final c = widget.controller, v = c.voice;
    final vad = c.settings.voiceMode == 'vad';
    // A hands-free mute left over after switching to push-to-talk (the session still says 已静音) means nothing there.
    final staleMute = !vad && v.muted && v.status == '已静音';
    final muted = v.mutedInVad;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: VoiceIdentityStage(
        key: ValueKey('voice-identity-${v.conversationId}'),
        compact: compact,
        windowHeight: windowHeight,
        identity: v.conversationId,
        minimumTranscriptExtent:
            (MediaQuery.textScalerOf(context)
                            .scale(c.settings.messageFontSize) *
                        1.6 +
                    16)
                .clamp(48.0, 200.0)
                .toDouble(),
        status: v.needsRecovery
            ? '需要恢复语音'
            : vad && v.ready && v.status == '已就绪'
            ? listeningLabel
            : staleMute
            ? '已就绪'
            : v.status,
        hint: v.error ?? (staleMute ? '按住按钮开始说话' : v.hint),
        hintIsError: v.error != null,
        mode: v.expressing
            ? ReactorMode.speaking
            : v.thinking
            ? ReactorMode.thinking
            : v.ready && !muted && (v.held || vad)
            ? ReactorMode.listening
            : ReactorMode.idle,
        onTap: () {
          // Only a reply in progress can be cut off; a tap on an idle avatar does nothing and says nothing.
          if (v.expressing || v.thinking) tapFeedback();
          v.interrupt();
        },
        onVerticalDragStart: dragStart,
        onVerticalDragUpdate: dragUpdate,
        onVerticalDragEnd: dragEnd,
        onVerticalDragCancel: dragSettle,
        waveform: AudioWaveform(levels: v.levels),
        transcript: transcript(),
      ),
    );
  }

  /// A row that is not always there (recover, generated works): the stage gives or takes its room smoothly instead of
  /// jumping by the row's height.
  Widget appearing(Widget? row) => SizedBox(
    width: double.infinity,
    child: SmoothSize(
      alignment: Alignment.bottomCenter,
      child: row ?? const SizedBox(width: double.infinity),
    ),
  );

  Widget recoverButton() => TextButton.icon(
    onPressed: recoverVoice,
    icon: const Icon(Icons.refresh),
    label: const Text('恢复语音'),
  );

  List<Widget> worksRow(double homeInset) => [
    const Divider(height: 1),
    ListTile(
      dense: true,
      title: Text('生成作品 · ${widget.controller.voice.owner!.tasks.length}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: works,
    ),
    if (homeInset > 0) SizedBox(height: homeInset),
  ];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: dragY,
    // The page follows a downward drag: pushed down and a little fainter, the chat showing through.
    builder: (context, y, child) => Opacity(
      opacity: (1 - y / 480).clamp(.4, 1.0),
      child: Transform.translate(offset: Offset(0, y), child: child),
    ),
    child: pageBody(),
  );

  Widget pageBody() => ListenableBuilder(
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
      // A new turn brings the view back to the tail, even when the user had scrolled up in the previous one.
      if (v.lastYou != lastTurnYou) {
        if (v.lastYou.isNotEmpty) textScroll.resumeFollowing();
        lastTurnYou = v.lastYou;
      }
      textScroll.followLatest();
      // Foldable iPhone: the page runs to the bottom edge; the controls (or the works row) clear the home indicator.
      final duo = DuoLayoutScope.of(context);
      final foldable = duo.isFoldable;
      final rail = duo.hasVerticalBar;
      final homeInset = foldable
          ? MediaQuery.viewPaddingOf(context).bottom
          : 0.0;
      final topInset = MediaQuery.paddingOf(context).top;
      return Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                bottom: !foldable,
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final compact = hasTranscript || bounds.maxHeight < 480;
                    // With the vertical strip, recover and works live in it instead of a second copy on the page.
                    final tile =
                        !rail &&
                        v.owner?.tasks.isNotEmpty == true &&
                        bounds.maxHeight >= 420;
                    final recover =
                        !rail && v.needsRecovery && bounds.maxHeight >= 500;
                    final short = bounds.maxHeight < 500;
                    // A plain phone held upright: hang up goes to the bottom, where the thumb is (the header corner
                    // is out of reach on a tall phone). Landscape and foldables keep their own places for it.
                    final hangupBelow =
                        !foldable && bounds.maxHeight > bounds.maxWidth;
                    // Half-folded in portrait: the crease band in this page's own coordinates. Stage above it,
                    // everything interactive below it, in reach of the thumb.
                    final fold = duo.horizontalFold;
                    final above = fold == null ? 0.0 : fold.top - topInset;
                    final below = fold == null
                        ? 0.0
                        : bounds.maxHeight - (fold.bottom - topInset);
                    final folded = fold != null && above >= 160 && below >= 200;
                    // Half-folded in landscape: title, avatar, status and transcript keep to the roomier side of the
                    // crease (the controls split around it themselves).
                    final side = foldSide(bounds.maxWidth);
                    Widget confine(Widget child) =>
                        Padding(padding: side, child: child);
                    return Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: columnInset(context, bounds.maxWidth),
                      ),
                      child: folded
                          ? Column(
                              children: [
                                SizedBox(
                                  height: above,
                                  child: stage(bounds.maxHeight, compact),
                                ),
                                SizedBox(height: fold.height),
                                Expanded(
                                  // Short on room (large text): the group scrolls instead of overflowing.
                                  child: SingleChildScrollView(
                                    key: const Key('voice-fold-controls'),
                                    reverse: true,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        header(short, bounds.maxHeight < 420),
                                        appearing(
                                          recover ? recoverButton() : null,
                                        ),
                                        controls(short, last: !tile),
                                        appearing(
                                          tile
                                              ? Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: worksRow(homeInset),
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                dragSurface(
                                  Padding(
                                    padding: EdgeInsets.only(
                                      top: headerTop(short, topInset),
                                    ),
                                    child: confine(
                                      header(
                                        short,
                                        bounds.maxHeight < 420,
                                        hangupBelow: hangupBelow,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: confine(
                                    stage(bounds.maxHeight, compact),
                                  ),
                                ),
                                appearing(
                                  recover ? confine(recoverButton()) : null,
                                ),
                                controls(short, last: !tile),
                                if (hangupBelow)
                                  Padding(
                                    // Clear of the talk button above, so a thumb sliding off it does not end the call.
                                    padding: const EdgeInsets.only(
                                      top: 8,
                                      bottom: 12,
                                    ),
                                    child: HangupButton(
                                      size: 52,
                                      onPressed: hangUp,
                                    ),
                                  ),
                                appearing(
                                  tile
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: worksRow(homeInset)
                                              .map(confine)
                                              .toList(),
                                        )
                                      : null,
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
          // Apple's vertical strip. When the host page owns it (the app), it switches to these buttons itself.
          if (!widget.railHosted) ...[
            () {
              final rail = voiceCallRail(
                context,
                widget.controller,
                onCancelTask: widget.onCancelTask,
                openSettings: widget.openSettings,
              );
              return DuoRail(
                hidden: widget.hidden,
                top: rail.top,
                bottom: rail.bottom,
              );
            }(),
          ],
        ],
      );
    },
  );
}

import 'completed_works.dart';
import 'action_menu.dart';
import 'hugging_icon_button.dart';
import 'ios_scroll.dart';
import 'duo_layout.dart';
import 'duo_rail.dart';
import 'keyboard_dismiss.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../net/jarvis_api.dart' show JarvisException;
import '../state/attachments.dart';
import 'media_widgets.dart';
import 'login_art.dart';
import 'startup_scene.dart';
import 'call_controls.dart';
import 'privacy_page.dart' show showAiDisclosure;
import 'half_fold_pane.dart';
import 'settings_page.dart';
import 'settings_widgets.dart' show showFoldDialog;
import 'status_page.dart';
import 'voice_page.dart';
import 'follow_scroll.dart';
import 'sidebar_split.dart';
import 'video_source.dart';

import '../model/adaptive_layout.dart';
import '../model/conversation.dart';
import '../model/media.dart';
import '../model/starters.dart';
import '../state/jarvis_controller.dart';
import 'motion.dart';
import 'design_tokens.dart';
import 'markdown_style.dart';

const _linkSchemes = ['https', 'http', 'mailto', 'tel'];

/// Half-folded in landscape: the gap between the content column and the crease, and the (larger) one at the other
/// edge, where the screen edge or the system strip is.
const _creaseGap = 8.0, _screenGap = 16.0;

/// The message list never gets less than this while the keyboard is up; the header and the composer's growth give way.
const _messagesMinimum = 120.0;

/// A hidden header needs this much more room than it took to hide it before it comes back.
const _headerHysteresis = 12.0;

/// The widest the chat column (messages, banners, composer) grows on a plain phone or a wide window: longer lines stop
/// being comfortable to read. Foldable layouts have their own rules.
const _readingWidth = 720.0;

/// Opens a link outside the app; says so when the system cannot (no mail account, no handler, a blocked scheme).
Future<void> openLink(BuildContext context, Uri uri) async {
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Reported below like a plain refusal.
  }
  if (!opened && context.mounted) showNotice(context, '无法打开链接');
}

/// The one-time notice about what is sent to the AI service: asked before the first message or call on this device, and
/// remembered once accepted. False when the user declines (nothing is sent).
Future<bool> ensureAiNotice(BuildContext context, JarvisController c) async {
  if (c.settings.aiNoticeAccepted) return true;
  final agreed = await showAiDisclosure(context, controller: c);
  if (agreed) c.changeSettings((s) => s.aiNoticeAccepted = true);
  return agreed;
}

/// After a call attempt that did not start: says why, and when the microphone is the reason, offers Settings.
/// [openSettings] opens the app's page in the system settings; without one only iOS can ('app-settings:' is its scheme),
/// so on Android no button is offered rather than one that does nothing.
void reportCallFailure(
  BuildContext context,
  JarvisController c, {
  Future<void> Function()? openSettings,
}) {
  if (c.voice.error == null || c.voice.active) return;
  final opener = openSettings ?? defaultSettingsOpener;
  showNotice(
    context,
    c.voice.error!,
    action: c.voice.permissionDenied && opener != null
        ? SnackBarAction(
            label: '去设置',
            onPressed: () => unawaited(opener().catchError((_) {})),
          )
        : null,
  );
}

class CoreAvatar extends StatelessWidget {
  const CoreAvatar({
    super.key,
    this.size = 128,
    this.mode = ReactorMode.idle,
    this.startupIdentity,
    this.motionSpeed = 1,
  });
  final double motionSpeed;
  final double size;
  final ReactorMode mode;
  final Object? startupIdentity;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'JARVIS',
    image: true,
    child: SizedBox(
      width: size,
      height: size < 64 ? size : size * .78,
      child: size < 64
          ? JarvisMark(size: size)
          : startupIdentity != null
          ? StartupReactorLanding(identity: startupIdentity!)
          : LoginScene(mode: mode, motionSpeed: motionSpeed),
    ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController(), password = TextEditingController();
  final formKey = GlobalKey(debugLabel: 'login-form');
  bool obscure = true;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (widget.controller.connecting ||
        username.text.trim().isEmpty ||
        password.text.isEmpty) {
      return;
    }
    // The keyboard falls and the hero grows back as one movement: the fields keep their (read-only) state rather than
    // being disabled, which would drop the focus a frame later.
    FocusManager.instance.primaryFocus?.unfocus();
    final success = await widget.controller.login(username.text, password.text);
    if (success && mounted) {
      // Committing the autofill context is what lets iOS offer to save the password, and it reads the fields' values
      // as they are then: clearing first would send the empty password down to the native field and nothing would be
      // offered. The field is wiped right after.
      TextInput.finishAutofillContext();
      password.clear();
    }
  }

  Widget form(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    InputDecoration field(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20),
      filled: true,
      fillColor: colors.brightness == Brightness.dark
          ? const Color(0xff18181b)
          : Colors.white.withValues(alpha: .86),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: BorderSide(color: colors.primary.withValues(alpha: .12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: BorderSide(color: colors.primary.withValues(alpha: .12)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    );
    // A focused field is scrolled into view with the rest of the form below it, so on a window too short for the whole
    // form above the keyboard the button comes up with the field: the button, the gap and (for the account) the
    // password field, estimated from the text scale, plus the field's own padding below the caret.
    final s = MediaQuery.textScalerOf(context).scale(100) / 100;
    final buttonHeight = math.max(54.0, 16 + 20 * s);
    final passwordBelow = 16 + 20 + buttonHeight + 8;
    final usernameBelow = passwordBelow + 14 + 32 + 24 * s;
    return SizedBox(
      key: formKey,
      width: 400,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '登录',
              style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                fontSize: compact ? 26 : 30,
                fontWeight: FontWeight.w600,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              // A new message fades over the old one and the form eases to its height, so a multi-line error does not
              // make everything below jump.
              child: SmoothSize(
                milliseconds: 180,
                alignment: Alignment.topCenter,
                // The old message's last lines stay visible while they fade, not cut off as the box shrinks.
                clipBehavior: Clip.none,
                child: AnimatedSwitcher(
                  duration: motion(context, 150),
                  layoutBuilder: overlayOutgoing(),
                  child: Semantics(
                    key: ValueKey(widget.controller.error),
                    liveRegion: widget.controller.error != null,
                    child: Text(
                      widget.controller.error ?? '从这里，继续你的探索。',
                      key: const ValueKey('login-subtitle'),
                      // A server's explanation is shown whole (the page scrolls); only the greeting is kept short.
                      maxLines: widget.controller.error == null ? 2 : null,
                      overflow: widget.controller.error == null
                          ? TextOverflow.ellipsis
                          : TextOverflow.visible,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: widget.controller.error == null
                            ? colors.onSurfaceVariant
                            : colors.error,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 18 : 26),
            TextField(
              onTapUpOutside: dismissKeyboardOnTapUpOutside,
              controller: username,
              // Read-only rather than disabled: a disabled field gives up the focus (the keyboard drops, the hero
              // grows) and greys out.
              readOnly: widget.controller.connecting,
              canRequestFocus: !widget.controller.connecting,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              scrollPadding: EdgeInsets.fromLTRB(20, 20, 20, usernameBelow),
              decoration: field('账户', Icons.person_outline),
            ),
            const SizedBox(height: 14),
            TextField(
              onTapUpOutside: dismissKeyboardOnTapUpOutside,
              controller: password,
              readOnly: widget.controller.connecting,
              canRequestFocus: !widget.controller.connecting,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: obscure,
              scrollPadding: EdgeInsets.fromLTRB(20, 20, 20, passwordBelow),
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(login()),
              decoration: field('密码', Icons.lock_outline).copyWith(
                suffixIcon: IconButton(
                  tooltip: obscure ? '显示密码' : '隐藏密码',
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(
                    obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ListenableBuilder(
                listenable: Listenable.merge([username, password]),
                builder: (context, _) => FilledButton(
                  onPressed:
                      widget.controller.connecting ||
                          username.text.trim().isEmpty ||
                          password.text.isEmpty
                      ? null
                      : login,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.medium),
                    ),
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  child: AnimatedSwitcher(
                    duration: motion(context, 150),
                    child: widget.controller.connecting
                        ? const Row(
                            key: ValueKey('login-connecting'),
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              JarvisSpinner.button(),
                              SizedBox(width: 10),
                              Text('正在登录…'),
                            ],
                          )
                        : const Text('登录', key: ValueKey('login-idle')),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Scaffold removes consumed keyboard insets from its body MediaQuery.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final stableBottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [
                    Color(0xff09090b),
                    Color(0xff111113),
                    Color(0xff0b0b0d),
                  ]
                : const [
                    Color(0xffe8f4f7),
                    Color(0xfff6f9f7),
                    Color(0xfff4efe5),
                  ],
            stops: const [0, .58, 1],
          ),
        ),
        child: _FollowInset(
          inset: keyboardInset,
          // iOS interpolates viewInsets frame by frame itself: following it as it is keeps the form glued to the
          // keyboard; a second tween on top lagged it and covered the button. Only a platform that steps the inset
          // gets the glide.
          glide:
              Theme.of(context).platform != TargetPlatform.iOS &&
              !MediaQuery.disableAnimationsOf(context),
          builder: (context, inset) => Padding(
            padding: EdgeInsets.only(bottom: math.max(inset, stableBottom)),
            child: SafeArea(
              bottom: false,
              // Half-folded, the form keeps to the roomier side of the fold, like the chat.
              child: HalfFoldPane(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final fullHeight =
                        bounds.maxHeight +
                        math.max(inset, stableBottom) -
                        stableBottom;
                    final keyboardBlend = ((inset - stableBottom) / 200).clamp(
                      0.0,
                      1.0,
                    );
                    final compact = fullHeight < 520;
                    final wideBase =
                        bounds.maxWidth >= 760 && fullHeight >= 520;
                    // A short landscape window (a phone on its side, the outer display of a foldable): the emblem beside
                    // the form instead of above it, which would push the form's button out of sight.
                    final sideways =
                        !wideBase &&
                        bounds.maxWidth >= 520 &&
                        fullHeight < 520 &&
                        bounds.maxWidth > fullHeight * 1.2;
                    final wide = wideBase || sideways;
                    final closedTopGap = (fullHeight * .05).clamp(12.0, 44.0);
                    final topGap =
                        closedTopGap + (6 - closedTopGap) * keyboardBlend;
                    final bottomGap = 12.0 - 4 * keyboardBlend;
                    // Foldable: the brand row sits on the chat header's axis (DuoLayout.headerAxisY), as the sidebar's does.
                    final onHeaderAxis =
                        DuoLayoutScope.of(context).isFoldable && !wideBase;
                    final topPadding = onHeaderAxis
                        ? math.max(
                            12.0,
                            DuoLayoutScope.of(context).headerAxisY - 16,
                          )
                        : 12.0;
                    final bottomPadding = 20.0 - 8 * keyboardBlend;
                    // The form grows with the text scale (a fixed 372 pt reserve pushed its button below the fold): its
                    // height is estimated from the scale, the hero gives way to it, and when even a minimal hero will not
                    // leave room the form's text stops growing at the largest scale that still fits the window.
                    final systemScale =
                        MediaQuery.textScalerOf(context).scale(100) / 100;
                    final formWidth = math.min(
                      400.0,
                      wide
                          ? (sideways
                                ? (bounds.maxWidth - 64) * .6
                                : (bounds.maxWidth - 80) / 2)
                          : bounds.maxWidth - 48,
                    );
                    final compactForm = wide ? sideways : compact;
                    // The line under the title is measured as it is shown: the greeting (two lines at most) or a server's
                    // explanation, which can take several.
                    final error = widget.controller.error;
                    double subtitleAt(double s, String text) => _measureText(
                      context,
                      text,
                      Theme.of(context).textTheme.bodyMedium,
                      TextScaler.linear(s),
                      formWidth,
                      maxLines: error == null ? 2 : null,
                    );
                    double formHeightAt(double s) {
                      // The estimate below holds one line of it.
                      final extraLines =
                          subtitleAt(s, error ?? '从这里，继续你的探索。') -
                          subtitleAt(s, '从');
                      return 190 +
                          106 * s +
                          math.max(0.0, extraLines) -
                          (compactForm ? 8 + 4.8 * s : 0);
                    }

                    double brandHeightAt(double s) => onHeaderAxis
                        ? 32
                        : math.max(28.0, 29 * math.min(s, 1.3));
                    bool fitsAt(double s) =>
                        topPadding +
                            brandHeightAt(s) +
                            (wide ? 16 : 56 + closedTopGap + 12) +
                            formHeightAt(s) +
                            8 <=
                        fullHeight;
                    var formScale = systemScale;
                    while (formScale > 1.0 && !fitsAt(formScale)) {
                      formScale = math.max(1.0, formScale - .05);
                    }
                    final heroReserve =
                        topPadding +
                        brandHeightAt(formScale) +
                        formHeightAt(formScale) +
                        4;
                    // The reserve and the gaps follow the keyboard's rise frame by frame, so the button never dips under it.
                    // With the keyboard up a short window lets the hero go altogether (it keeps 56 pt at rest).
                    final smallestHero = 56 * (1 - keyboardBlend);
                    final closedHero = math.min(
                      (fullHeight * .43).clamp(72.0, 380.0),
                      (fullHeight - heroReserve - 32 - closedTopGap).clamp(
                        56.0,
                        380.0,
                      ),
                    );
                    final heroHeight = math.min(
                      closedHero,
                      (bounds.maxHeight -
                              heroReserve -
                              bottomPadding -
                              bottomGap -
                              topGap)
                          .clamp(smallestHero, 380.0),
                    );
                    return MediaQuery.withClampedTextScaling(
                      maxScaleFactor: math.max(formScale, .1),
                      child: SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.only(
                          left: 24,
                          right: 24,
                          top: topPadding,
                          bottom: bottomPadding,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: math.max(
                              0,
                              bounds.maxHeight - topPadding - bottomPadding,
                            ),
                          ),
                          child: Align(
                            alignment: wideBase
                                ? Alignment.center
                                : Alignment.topCenter,
                            child: SizedBox(
                              width: 960,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    height: onHeaderAxis ? 32 : null,
                                    child: Row(
                                      key: const ValueKey('login-brand-row'),
                                      children: [
                                        const LoginBrandMark(),
                                        const SizedBox(width: 12),
                                        // The wordmark shrinks rather than overflowing at the largest text scales.
                                        Flexible(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'JARVIS',
                                              textScaler: formScale > 1.3
                                                  ? const TextScaler.linear(1.3)
                                                  : null,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge
                                                  ?.copyWith(
                                                    fontSize: 23,
                                                    letterSpacing: .6,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (wide) const SizedBox(height: 16),
                                  if (wide)
                                    Row(
                                      children: [
                                        Expanded(
                                          flex: sideways ? 2 : 1,
                                          child: SizedBox(
                                            height: sideways
                                                ? math.max(
                                                    120.0,
                                                    bounds.maxHeight -
                                                        topPadding -
                                                        bottomPadding -
                                                        56,
                                                  )
                                                : math.min(
                                                    420.0,
                                                    math.max(
                                                      176.0,
                                                      bounds.maxHeight - 72,
                                                    ),
                                                  ),
                                            child: const FractionallySizedBox(
                                              widthFactor: .9,
                                              heightFactor: .9,
                                              child: StartupReactorLanding(),
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: sideways ? 16 : 32),
                                        Flexible(
                                          flex: sideways ? 3 : 1,
                                          child: form(
                                            context,
                                            compact: sideways,
                                          ),
                                        ),
                                      ],
                                    )
                                  else ...[
                                    Container(
                                      key: const ValueKey('login-reactor-size'),
                                      height: heroHeight + topGap + bottomGap,
                                      width: double.infinity,
                                      padding: EdgeInsets.only(
                                        top: topGap,
                                        bottom: bottomGap,
                                      ),
                                      child: const FractionallySizedBox(
                                        widthFactor: .9,
                                        heightFactor: .9,
                                        child: StartupReactorLanding(),
                                      ),
                                    ),
                                    form(context, compact: compact),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hands [builder] the keyboard inset: as it is when [glide] is false, eased over 240 ms otherwise.
class _FollowInset extends StatelessWidget {
  const _FollowInset({
    required this.inset,
    required this.glide,
    required this.builder,
  });
  final double inset;
  final bool glide;
  final Widget Function(BuildContext context, double inset) builder;
  @override
  Widget build(BuildContext context) => glide
      ? TweenAnimationBuilder<double>(
          tween: Tween<double>(end: inset),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => builder(context, value),
        )
      : builder(context, inset);
}

/// The height [text] takes at [width] under [scaler], in the style a [Text] would give it in [context].
double _measureText(
  BuildContext context,
  String text,
  TextStyle? style,
  TextScaler scaler,
  double width, {
  int? maxLines,
}) => _layoutText(
  text,
  DefaultTextStyle.of(context).style.merge(style),
  Directionality.of(context),
  scaler,
  width,
  maxLines,
).height;

/// Text laid out for the welcome page and its cards, kept: those builders run every frame while the keyboard moves, and
/// the answer only changes with the text, its style, the text size or the width. Emptied when the system fonts change.
final _textLayouts = <Object, ({double height, bool cut, bool alone})>{};
bool _textLayoutsWatched = false;

/// [text]'s height at [width], whether it ran past [maxLines], and whether it wrapped leaving its last character alone
/// on the last line.
({double height, bool cut, bool alone}) _layoutText(
  String text,
  TextStyle style,
  TextDirection direction,
  TextScaler scaler,
  double width,
  int? maxLines,
) {
  if (!_textLayoutsWatched) {
    _textLayoutsWatched = true;
    PaintingBinding.instance.systemFonts.addListener(_textLayouts.clear);
  }
  final key = (text, style, direction, scaler, width, maxLines);
  final known = _textLayouts[key];
  if (known != null) return known;
  if (_textLayouts.length >= 256) _textLayouts.clear();
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: maxLines,
  )..layout(maxWidth: math.max(0.0, width));
  final last = text.length - 1;
  final result = (
    height: painter.height,
    cut: painter.didExceedMaxLines,
    alone:
        last > 0 &&
        !painter.didExceedMaxLines &&
        text.substring(last).trim().isNotEmpty &&
        painter.getLineBoundary(TextPosition(offset: last)).start >= last,
  );
  painter.dispose();
  return _textLayouts[key] = result;
}

/// Chases a moving target softly: two gentle low-pass stages in a row, so the thing it carries starts easing in at once
/// (no jolt), moves more slowly than the target and settles a moment after it. Follows the target from where it is, so
/// it never jumps; snaps when the system asks to reduce motion.
class _SoftFollow extends StatefulWidget {
  const _SoftFollow({
    required this.target,
    required this.scale,
    required this.builder,
  });
  final Offset target;
  final double scale;
  final Widget Function(BuildContext context, Offset shift, double scale)
  builder;
  @override
  State<_SoftFollow> createState() => _SoftFollowState();
}

class _SoftFollowState extends State<_SoftFollow>
    with SingleTickerProviderStateMixin {
  /// Each stage's time constant, in seconds.
  static const _tau = .085;
  late final Ticker _ticker = createTicker(_tick);
  late List<double> _first = _goal, _second = _goal;
  Duration _last = Duration.zero;

  List<double> get _goal => [widget.target.dx, widget.target.dy, widget.scale];

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, .5);
    _last = elapsed;
    final k = 1 - math.exp(-dt / _tau), goal = _goal;
    var settled = true;
    for (var i = 0; i < goal.length; i++) {
      _first[i] += (goal[i] - _first[i]) * k;
      _second[i] += (_first[i] - _second[i]) * k;
      // Within a quarter point (the scale: a quarter point of a ~120 pt avatar) it snaps and the ticker stops, rather
      // than drifting by fractions of a pixel for another second.
      final near = i < 2 ? .25 : .002;
      if ((goal[i] - _second[i]).abs() > near ||
          (goal[i] - _first[i]).abs() > near) {
        settled = false;
      }
    }
    if (settled) {
      _first = _goal;
      _second = _goal;
      _ticker.stop();
      _last = Duration.zero;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(_SoftFollow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (MediaQuery.disableAnimationsOf(context)) {
      _first = _goal;
      _second = _goal;
    } else if (!_ticker.isActive &&
        (oldWidget.target != widget.target ||
            oldWidget.scale != widget.scale)) {
      _last = Duration.zero;
      unawaited(_ticker.start());
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, Offset(_second[0], _second[1]), _second[2]);
}

/// The chat header, folding away (and back) over 180 ms with its height and opacity: with the keyboard up it is
/// removed, and doing that at once would shove the whole page by its height.
class _HeaderSlot extends StatelessWidget {
  const _HeaderSlot({
    required this.shown,
    required this.animation,
    this.follow,
    required this.child,
  });
  final bool shown;

  /// How much of the header is there, 0 to 1, as it folds on its own timer; the page below reads the same value, so the
  /// two always move together.
  final Animation<double> animation;

  /// How much of the header is there, 0 to 1, when something else sets the pace (the keyboard rising): the header then
  /// takes exactly this much, with no timer of its own.
  final double? follow;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final t = follow ?? animation.value;
      if (t == 0 && !shown) return const SizedBox.shrink();
      return ExcludeSemantics(
        excluding: !shown,
        child: IgnorePointer(
          ignoring: !shown,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: t,
              child: Opacity(opacity: t, child: child),
            ),
          ),
        ),
      );
    },
  );
}

/// The part of the pane the content column keeps to while the device is half-folded in landscape.
class _FoldColumn {
  const _FoldColumn.right(this.room) : onRight = true, far = 0;
  const _FoldColumn.left(this.room, this.far) : onRight = false;

  /// Right of the crease (else left of it).
  final bool onRight;

  /// The column's width.
  final double room;

  /// Left column only: the distance from the pane's right edge to the crease.
  final double far;

  /// The padding that puts a pane [width] wide onto the column. The right column is measured from the pane's live right
  /// edge, so it holds still on screen while the session list slides in or out beside it.
  EdgeInsets insetFor(double width) => onRight
      ? EdgeInsets.only(left: math.max(0.0, width - room))
      : EdgeInsets.only(right: far);
}

enum _Link { connecting, ready, down }

/// The model's connection as a small badge whose shape says what its colour says: filled (connected), ring
/// (connecting), filled with a bar (not connected).
class _StatusDot extends StatelessWidget {
  const _StatusDot({super.key, required this.link});
  final _Link link;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The light page needs the darker tones (3:1 for a graphic); the dark ones are for the dark page.
    final color = switch (link) {
      _Link.connecting => JarvisColors.warning(context),
      _Link.ready => JarvisColors.success(context),
      _Link.down => colors.error,
    };
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 10,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: link == _Link.connecting ? null : color,
            border: link == _Link.connecting
                ? Border.all(color: color, width: 2)
                : null,
          ),
          child: link == _Link.down
              ? Center(
                  child: SizedBox(
                    width: 5,
                    height: 1.5,
                    child: ColoredBox(color: colors.surface),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// The conversation list shows a search field from this many conversations on.
const _searchFrom = 6;

/// When [c] was last active, read from the timestamp in the id of its latest message (ids are made from the clock);
/// null for ids that are not.
DateTime? _lastActive(Conversation c) {
  final id = c.messages.isEmpty ? c.id : c.messages.last.id;
  final micros = int.tryParse(id.split('-').first);
  if (micros == null || micros < 946684800000000 || micros > 4102444800000000) {
    return null;
  }
  return DateTime.fromMicrosecondsSinceEpoch(micros);
}

/// The sidebar's rows: the conversations that match [query] (title or any message), newest first as given, with the
/// headings 今天 / 昨天 / 更早 between them whenever more than one of those is present.
List<Object> conversationRows(
  List<Conversation> all,
  String query,
  DateTime now,
) {
  final needle = query.trim().toLowerCase();
  final shown = needle.isEmpty
      ? all
      : [
          for (final c in all)
            if (c.title.toLowerCase().contains(needle) ||
                c.messages.any(
                  (m) => !m.hidden && m.text.toLowerCase().contains(needle),
                ))
              c,
        ];
  final today = DateTime(now.year, now.month, now.day);
  String group(Conversation c) {
    final at = _lastActive(c);
    if (at == null) return '更早';
    final day = DateTime(at.year, at.month, at.day);
    if (!day.isBefore(today)) return '今天';
    return !day.isBefore(today.subtract(const Duration(days: 1))) ? '昨天' : '更早';
  }

  final groups = [for (final c in shown) group(c)];
  if (groups.toSet().length < 2) return [...shown];
  final rows = <Object>[];
  String? previous;
  for (var i = 0; i < shown.length; i++) {
    if (groups[i] != previous) rows.add(previous = groups[i]);
    rows.add(shown[i]);
  }
  return rows;
}

class JarvisHome extends StatefulWidget {
  const JarvisHome({
    super.key,
    required this.controller,
    this.onCancelTask,
    this.openSettings,
    this.onContinue,
    this.offline,
    this.onRetry,
  });
  final JarvisController controller;

  /// Ends a pending image or video task (the card's "取消"; also the way out when a conversation cannot be deleted
  /// because of one). Null: no button.
  final void Function(MediaTask task)? onCancelTask;

  /// Opens the app's page in the system Settings (the microphone and photo-library "去设置" buttons). Null: iOS opens
  /// 'app-settings:' itself, Android offers no button.
  final Future<void> Function()? openSettings;

  /// Asks the model to carry on a reply that stopped at the length limit ("继续生成"). Null: no button.
  final VoidCallback? onContinue;

  /// Whether the history shown is only this device's copy because the network is down, and the way to try again; the
  /// bar above the composer says so and offers "重试" when [onRetry] is given.
  final bool Function()? offline;
  final VoidCallback? onRetry;
  @override
  State<JarvisHome> createState() => _JarvisHomeState();
}

class _JarvisHomeState extends State<JarvisHome> with TickerProviderStateMixin {
  bool? showDocked;
  bool drawerOpen = false;
  bool? lastDefault;
  final scaffold = GlobalKey<ScaffoldState>();
  final paneBounds = GlobalKey(), composerBounds = GlobalKey();

  /// The composer's input focus, so that other parts of the page (the welcome cards) can put the caret there.
  final composerFocus = FocusNode(debugLabel: 'composer');

  /// 0 flat .. 1 half-folded: the content column fades through the switch between the whole width and the roomier side
  /// of the fold.
  late final foldAnim = AnimationController(vsync: this);

  /// How much of the header is there as it folds away and back (1 shown, 0 gone). The header and the welcome page both read
  /// it, so the page glides exactly as far as the header has given way.
  AnimationController? headerFold;
  CurvedAnimation? _headerCurve;
  Animation<double> get headerCurve => _headerCurve ??= CurvedAnimation(
    parent: headerFold!,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic.flipped,
  );
  bool? headerTarget;
  bool headerFollowing = false;
  bool? foldedTarget;
  bool foldSeeded = false;
  // The last fold geometry, kept so the column can still glide out of it once the fold has opened.
  _FoldColumn? foldColumn;
  Size? foldWindow;

  /// Set when the window changed size: the column takes its new geometry at once instead of fading from the old one.
  double? foldSnap;

  /// The bottom error line the user has dismissed; it comes back when the text changes or after the error cleared.
  String? dismissedError;

  /// Whether the header was shown at the last build: with the keyboard up it hides at a certain room and comes back
  /// only with [_headerHysteresis] more, so an inset that jitters around the limit cannot make it flicker.
  bool? headerWasShown;

  /// Set after the first frame: a chat page built later (another conversation, a new one) fades in; the first one is
  /// simply there.
  bool chatBuilt = false;

  /// Closes the conversation drawer, and says whether it was open. Unlike popping the route this can never take the
  /// page itself with it when the drawer is already (closing) shut.
  bool closeDrawer() {
    final state = scaffold.currentState;
    if (state == null || !state.isDrawerOpen) return false;
    state.closeDrawer();
    return true;
  }

  /// Pages that cover the chat take the keyboard with them: it must not come back on its own when they close.
  void settings() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'settings'),
          builder: (_) => SettingsPage(
            controller: widget.controller,
            onLogoutAndClear: widget.controller.clearLocalData,
          ),
        ),
      ),
    );
  }

  void openStatus() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'status'),
          builder: (_) => StatusPage(controller: widget.controller),
        ),
      ),
    );
  }

  Future<void> call() async {
    tapFeedback();
    FocusScope.of(context).unfocus();
    final c = widget.controller;
    if (c.voice.active) {
      c.voice.expand();
      return;
    }
    if (!await ensureAiNotice(context, c)) return;
    if (!mounted) return;
    await c.voice.start(c.current);
    if (mounted) {
      reportCallFailure(context, c, openSettings: widget.openSettings);
    }
  }

  Future<void> renameConversation(String id, String old) async {
    final field = TextEditingController(text: old)
      ..selection = TextSelection(baseOffset: 0, extentOffset: old.length);
    final route = DialogRoute<String>(
      context: context,
      builder: (context) {
        // Foldable iPhone: use the screen. The dialog spans the usable width (same 22pt gap as the composer), with
        // larger type, a taller field and bigger buttons, instead of the small default alert.
        final big = DuoLayoutScope.of(context).isFoldable;
        final colors = Theme.of(context).colorScheme;
        return AlertDialog(
          key: const Key('rename-dialog'),
          insetPadding: big
              ? const EdgeInsets.symmetric(
                  horizontal: DuoLayout.edgeGap,
                  vertical: 24,
                )
              : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          constraints: big
              ? const BoxConstraints(minWidth: 280, maxWidth: 560)
              : null,
          contentPadding: big ? const EdgeInsets.fromLTRB(24, 16, 24, 8) : null,
          titlePadding: big ? const EdgeInsets.fromLTRB(24, 24, 24, 0) : null,
          title: Text(
            '重命名会话',
            // The theme's semibold dialog title, one size up to match the larger dialog.
            style: big
                ? TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  )
                : null,
          ),
          content: SizedBox(
            // Foldable: stretch the field so the dialog spans the usable width instead of hugging its content.
            width: big ? double.maxFinite : null,
            child: TextField(
              onTapUpOutside: dismissKeyboardOnTapUpOutside,
              key: const Key('rename-field'),
              controller: field,
              autofocus: true,
              maxLength: 60,
              style: big ? const TextStyle(fontSize: 18) : null,
              // Never null: that would drop the themed field box and the "9/60" counter.
              decoration: big
                  ? const InputDecoration(
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                    )
                  : const InputDecoration(),
              textInputAction: TextInputAction.done,
              onSubmitted: (s) => Navigator.pop(context, s),
            ),
          ),
          actionsPadding: big ? const EdgeInsets.fromLTRB(16, 4, 20, 20) : null,
          actions: [
            TextButton(
              style: big
                  ? TextButton.styleFrom(
                      minimumSize: const Size(96, 52),
                      textStyle: const TextStyle(fontSize: 16),
                    )
                  : null,
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              style: big
                  ? FilledButton.styleFrom(
                      minimumSize: const Size(120, 52),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
              onPressed: () => Navigator.pop(context, field.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    final name = await Navigator.of(context, rootNavigator: true).push(route);
    if (name != null) widget.controller.rename(id, name);
    // Navigator.pop completes before the dialog's reverse animation is removed.
    await route.completed;
    field.dispose();
  }

  /// iOS / foldable: conversation feedback (deleted + undo, can't delete) lives in the conversation list itself,
  /// at the bottom of the sidebar, not as a snack bar over the chat.
  bool get sidebarNotices =>
      Theme.of(context).platform == TargetPlatform.iOS ||
      DuoLayoutScope.of(context).isFoldable;
  ({String text, String label, VoidCallback? action})? sidebarNotice;
  final dismissGeneration = <String, int>{};
  Timer? sidebarNoticeTimer;

  /// The sidebar's one-line notice; [action] (labelled [label]) is its button, e.g. the undo of a deletion.
  void showSidebarNotice(
    String text, {
    String label = '撤销',
    VoidCallback? action,
    required Duration duration,
  }) {
    sidebarNoticeTimer?.cancel();
    setState(() => sidebarNotice = (text: text, label: label, action: action));
    sidebarNoticeTimer = Timer(duration, () {
      if (mounted) setState(() => sidebarNotice = null);
    });
  }

  /// The conversation list's search text.
  final searchField = TextEditingController();
  String search = '';

  @override
  void initState() {
    super.initState();
    widget.controller.confirmToolCall = askToolCall;
    WidgetsBinding.instance.addPostFrameCallback((_) => chatBuilt = true);
  }

  /// The model wants to change which models are loaded (model management): nothing happens unless the user agrees.
  Future<bool> askToolCall(String action) async {
    if (!mounted) return false;
    final agreed = await showFoldDialog<bool>(
      context: context,
      builder: (context, insets) => AlertDialog(
        insetPadding: insets,
        title: const Text('模型请求更改'),
        content: Text('助手想要$action。只有你同意，才会执行。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    return agreed == true;
  }

  @override
  void dispose() {
    if (widget.controller.confirmToolCall == askToolCall) {
      widget.controller.confirmToolCall = null;
    }
    sidebarNoticeTimer?.cancel();
    composerFocus.dispose();
    foldAnim.dispose();
    // The curve listens to the fold controller: it goes first.
    _headerCurve?.dispose();
    headerFold?.dispose();
    searchField.dispose();
    // Leaving the chat (sign-out) drops the videos that were downloaded for playing.
    unawaited(clearVideoCache());
    super.dispose();
  }

  /// The saved data could not be read and the app is not saving: this is the way out. The old file stays on disk.
  Future<void> startFresh() async {
    final colors = Theme.of(context).colorScheme;
    final ok = await showFoldDialog<bool>(
      context: context,
      builder: (context, insets) => AlertDialog(
        insetPadding: insets,
        title: const Text('从空白开始？'),
        content: const Text('无法读取的原资料会保留在本机，但之后新建的会话会取代它们。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('从空白开始'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.controller.startFresh();
  }

  void showErrorDetail(String text) => unawaited(
    showFoldDialog<void>(
      context: context,
      builder: (context, insets) => AlertDialog(
        insetPadding: insets,
        title: const Text('出错了'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );

  /// Why a conversation cannot be deleted. When pending image or video tasks are the reason and they can be ended from
  /// here, the notice says so and carries the button that ends them.
  ({String text, String? label, VoidCallback? run}) deleteRefusal(String id) {
    final pending = [
      for (final c in widget.controller.conversations.where((c) => c.id == id))
        ...c.tasks.where((t) => t.pending),
    ];
    final cancel = widget.onCancelTask;
    if (pending.isEmpty || cancel == null) {
      return (text: '请先结束此会话的任务或通话，再删除会话', label: null, run: null);
    }
    return (
      text: '此会话还有 ${pending.length} 个生成任务在运行，取消后才能删除',
      label: '取消任务',
      run: () {
        for (final task in pending) {
          cancel(task);
        }
      },
    );
  }

  /// How long "deleted, undo?" stays up. The controller keeps the files for 10 s; VoiceOver users need time to find the
  /// button.
  Duration get undoNoticeDuration => MediaQuery.accessibleNavigationOf(context)
      ? const Duration(seconds: 8)
      : const Duration(seconds: 5);

  void deleteConversation(String id) {
    final c = widget.controller, removed = c.deleteConversation(id);
    if (removed != null) tapFeedback(strong: true);
    if (sidebarNotices) {
      if (removed == null) {
        final why = deleteRefusal(id);
        showSidebarNotice(
          why.text,
          label: why.label ?? '',
          action: why.run,
          duration: Duration(seconds: why.run == null ? 3 : 6),
        );
      } else {
        showSidebarNotice(
          '会话已删除',
          action: () => c.restoreConversation(removed),
          duration: undoNoticeDuration,
        );
      }
      return;
    }
    if (removed == null) {
      final why = deleteRefusal(id);
      showNotice(
        paneBounds.currentContext ?? context,
        why.text,
        action: why.run == null
            ? null
            : SnackBarAction(label: why.label!, onPressed: why.run!),
      );
      return;
    }
    showNotice(
      paneBounds.currentContext ?? context,
      '会话已删除',
      compact: true,
      verticalOffset:
          MediaQuery.sizeOf(context).width < 600 &&
              MediaQuery.sizeOf(context).height >=
                  MediaQuery.sizeOf(context).width * 1.9
          ? 5
          : 0,
      duration: undoNoticeDuration,
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => c.restoreConversation(removed),
      ),
    );
  }

  /// The conversation drawer's width: [base] grows with the text scale (30% of the extra scale), up to 85% of the
  /// [available] width, so a phone's rows do not shrink to a few glyphs at the largest text sizes.
  double drawerWidth(double base, double available) {
    final scale = MediaQuery.textScalerOf(context).scale(100) / 100;
    final grown = base * (1 + (scale.clamp(1.0, 2.4) - 1) * .3);
    return math.max(base, math.min(grown, available * .85));
  }

  /// A phone on its side (about 400pt tall): the conversation list needs the height, so the sidebar drops its brand
  /// row, tightens its spacing, rows get 48pt tall and settings moves up beside "新建会话". Not the foldable, whose
  /// brand row sits on the header axis.
  bool get shortSidebar =>
      !DuoLayoutScope.of(context).isFoldable &&
      MediaQuery.sizeOf(context).height < 500;

  Widget sidebar({required bool drawer}) => SafeArea(
    child: Column(
      children: [
        Padding(
          // Foldable: the brand row sits on the same horizontal axis as the chat header (DuoLayout.headerAxis).
          padding: shortSidebar
              ? const EdgeInsets.only(top: 8)
              : EdgeInsets.fromLTRB(
                  20,
                  DuoLayoutScope.of(context).isFoldable
                      ? DuoLayoutScope.of(context).headerAxisY - 16
                      : 20,
                  20,
                  20,
                ),
          // Fixed height, so a large system text size cannot move the row off the header axis. A short sidebar leaves
          // the brand out (the list needs the room).
          child: shortSidebar
              ? null
              : SizedBox(
                  height: DuoLayoutScope.of(context).isFoldable ? 32 : null,
                  child: Row(
                    children: [
                      const ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(9)),
                        child: JarvisMark(size: 32, tile: true),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'JARVIS',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textScaler:
                              DuoLayoutScope.of(context).isFoldable || drawer
                              ? MediaQuery.textScalerOf(context)
                                    .clamp(maxScaleFactor: 1.3)
                              : null,
                          style: TextStyle(
                            // Foldable iPhone: one size smaller (18 instead of 20).
                            fontSize: DuoLayoutScope.of(context).isFoldable
                                ? 18
                                : 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const Key('new-conversation'),
                  // A quiet tinted button in both themes (not the near-white primary fill in dark, which outshone
                  // everything else on screen).
                  style: FilledButton.styleFrom(
                    minimumSize: Size(48, shortSidebar ? 44 : 53),
                    // Short sidebar: 44pt (iOS's minimum), not padded back up to 48.
                    tapTargetSize: shortSidebar
                        ? MaterialTapTargetSize.shrinkWrap
                        : null,
                    backgroundColor:
                        Theme.of(context).brightness == Brightness.dark
                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                        : null,
                    foregroundColor:
                        Theme.of(context).brightness == Brightness.dark
                        ? Theme.of(context).colorScheme.onSurface
                        : null,
                  ),
                  onPressed: () {
                    tapFeedback();
                    widget.controller.newConversation();
                    if (drawer) closeDrawer();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('新建会话'),
                ),
              ),
              if (shortSidebar && !DuoLayoutScope.of(context).hasVerticalBar)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconButton(
                    key: const Key('sidebar-settings'),
                    tooltip: '设置',
                    // As tall as the button beside it.
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.settings_outlined, size: 22),
                    onPressed: () {
                      // A second tap while the drawer slides shut must not open the page twice.
                      if (drawer && !closeDrawer()) return;
                      settings();
                    },
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: shortSidebar ? 6 : 8),
        // Searching only earns its row once the list is long; it eases in rather than pushing the list down at once.
        SmoothSize(
          alignment: Alignment.topCenter,
          child:
              widget.controller.conversations.length >= _searchFrom ||
                  search.isNotEmpty
              ? Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, shortSidebar ? 6 : 8),
                  child: TextField(
                    key: const Key('conversation-search'),
                    controller: searchField,
                    onTapUpOutside: dismissKeyboardOnTapUpOutside,
                    textInputAction: TextInputAction.search,
                    onChanged: (value) => setState(() => search = value),
                    decoration: InputDecoration(
                      hintText: '搜索会话',
                      isDense: true,
                      filled: true,
                      // Dark: the theme's field fill is the sidebar's own colour, which left the field invisible; one
                      // step up shows it. Light keeps the white field on the off-white sidebar.
                      fillColor: Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.surfaceContainerHigh
                          : null,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: search.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                searchField.clear();
                                setState(() => search = '');
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.medium),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              final rows = conversationRows(
                widget.controller.conversations,
                search,
                DateTime.now(),
              );
              if (rows.isEmpty) {
                return Center(
                  child: Text(
                    '没有匹配的会话',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.builder(
                key: const Key('conversation-list'),
                physics: iosScrollPhysics,
                keyboardDismissBehavior: iosKeyboardDismiss,
                itemCount: rows.length,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemBuilder: (context, index) {
                  final row = rows[index];
                  if (row is String) {
                    return Semantics(
                      header: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                        child: Text(
                          row,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                    );
                  }
                  final c = row as Conversation;
                  // iOS convention: swipe a row left to delete it (the "..." menu still works). Not in the drawer, where a
                  // leftward swipe is the drawer's own way to close.
                  final swipeToDelete =
                      !drawer &&
                      (Theme.of(context).platform == TargetPlatform.iOS ||
                          DuoLayoutScope.of(context).isFoldable);
                  Widget swipeable(Widget row) => !swipeToDelete
                      ? row
                      : Dismissible(
                          // The generation changes when a swipe could not delete (see onDismissed), replacing the dismissed row.
                          key: ValueKey(
                            'conversation-dismiss-${c.id}-${dismissGeneration[c.id] ?? 0}',
                          ),
                          direction: DismissDirection.endToStart,
                          dismissThresholds: const {
                            DismissDirection.endToStart: .35,
                          },
                          confirmDismiss: (_) async {
                            final ok = widget.controller.canDeleteConversation(
                              c.id,
                            );
                            if (!ok) {
                              final why = deleteRefusal(c.id);
                              showSidebarNotice(
                                why.text,
                                label: why.label ?? '',
                                action: why.run,
                                duration: Duration(
                                  seconds: why.run == null ? 3 : 6,
                                ),
                              );
                            }
                            return ok;
                          },
                          onDismissed: (_) {
                            if (!widget.controller.canDeleteConversation(
                              c.id,
                            )) {
                              // It started generating between the swipe and now: bring the row back instead of leaving a
                              // dismissed Dismissible in the tree.
                              setState(
                                () => dismissGeneration[c.id] =
                                    (dismissGeneration[c.id] ?? 0) + 1,
                              );
                            }
                            deleteConversation(c.id);
                          },
                          background: const SizedBox.shrink(),
                          secondaryBackground: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.medium),
                            child: ColoredBox(
                              color: Theme.of(context).colorScheme.error,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 22),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.delete_outline,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onError,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '删除',
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onError,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          child: row,
                        );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: swipeable(
                      Material(
                        key: ValueKey('conversation-surface-${c.id}'),
                        color: c.id == widget.controller.selectedId
                            ? Theme.of(context).colorScheme.surfaceContainerHigh
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.medium),
                        clipBehavior: Clip.antiAlias,
                        animateColor: true,
                        animationDuration: Duration(
                          milliseconds: MediaQuery.disableAnimationsOf(context)
                              ? 0
                              : 160,
                        ),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(Radii.medium),
                          ),
                          selected: c.id == widget.controller.selectedId,
                          tileColor: Colors.transparent,
                          selectedTileColor: Colors.transparent,
                          // The selected row is the same in both themes: the raised surface behind onSurface text, a
                          // little bolder (light used to turn it teal, dark plain white).
                          selectedColor: Theme.of(context)
                              .colorScheme
                              .onSurface,
                          title: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: c.id == widget.controller.selectedId
                                  ? FontWeight.w600
                                  : null,
                            ),
                          ),
                          minTileHeight: shortSidebar ? 48 : 58,
                          contentPadding: const EdgeInsets.only(
                            left: 12,
                            right: 4,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.controller.isGenerating(c.id))
                                const JarvisSpinner.inline(
                                  semanticsLabel: '生成中',
                                ),
                              JarvisActionMenu(
                                tooltip: '会话操作',
                                iconSize: 18,
                                actions: const [
                                  JarvisMenuAction(
                                    'rename',
                                    '重命名',
                                    icon: Icons.edit_outlined,
                                  ),
                                  JarvisMenuAction(
                                    'delete',
                                    '删除',
                                    icon: Icons.delete_outline,
                                    destructive: true,
                                  ),
                                ],
                                onSelected: (value) => value == 'rename'
                                    ? renameConversation(c.id, c.title)
                                    : deleteConversation(c.id),
                              ),
                            ],
                          ),
                          onTap: () {
                            widget.controller.select(c.id);
                            if (drawer) closeDrawer();
                          },
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SmoothSize(
          alignment: Alignment.bottomCenter,
          child: AnimatedSwitcher(
            duration: motion(context),
            layoutBuilder: overlayOutgoing(),
            child: sidebarNotice == null
                ? const SizedBox(width: double.infinity)
                : _SidebarNotice(
                    key: const Key('sidebar-notice'),
                    text: sidebarNotice!.text,
                    label: sidebarNotice!.label,
                    onAction: switch (sidebarNotice!.action) {
                      final action? => () {
                        // The notice can already be gone (timer, double tap) while its exit animation still shows it.
                        if (sidebarNotice == null) return;
                        sidebarNoticeTimer?.cancel();
                        action();
                        setState(() => sidebarNotice = null);
                      },
                      null => null,
                    },
                  ),
          ),
        ),
        // A short sidebar has settings beside "新建会话" instead.
        if (!DuoLayoutScope.of(context).hasVerticalBar && !shortSidebar)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.medium),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.medium),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                minTileHeight: 52,
                leading: const Icon(Icons.settings_outlined, size: 22),
                title: const Text('设置'),
                onTap: () {
                  // A second tap while the drawer slides shut must not open the page twice.
                  if (drawer && !closeDrawer()) return;
                  settings();
                },
              ),
            ),
          ),
      ],
    ),
  );

  Widget dockedSidebar(
    double width,
    bool visible,
    Duration duration,
    Widget content,
  ) => SidebarSplit(
    width: width,
    visible: visible,
    duration: duration,
    onChanged: (value) => setState(() => showDocked = value),
    content: content,
    child: sidebar(drawer: false),
  );

  /// The conversation name with the model's connection beside it; the whole row opens the model status. On a plain
  /// phone the app name leads, and the row fills the width.
  Widget headingTitle(BuildContext context, {required bool foldable}) {
    final c = widget.controller;
    final link = c.connecting
        ? _Link.connecting
        : c.modelReady
        ? _Link.ready
        : _Link.down;
    final state = switch (link) {
      _Link.connecting => '正在连接',
      _Link.ready => '模型已连接',
      _Link.down => '模型未连接',
    };
    final dot = _StatusDot(key: const Key('connection-dot'), link: link);
    // The header shares its line with three buttons: on a phone its text stops growing at 1.3x, so the conversation
    // name keeps room beside the app name instead of shrinking to one glyph at the largest text sizes.
    final headScaler = foldable
        ? null
        : MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final title = Text(
      c.current.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textScaler: headScaler,
      style: foldable
          ? Theme.of(context).textTheme.titleMedium
          : Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
    );
    final nameStyle = Theme.of(context).textTheme.titleMedium;
    final heading = LayoutBuilder(
      builder: (context, box) {
        // The conversation name beside the app name only when there is room left for it at this text size.
        var showTitle = !foldable && c.current.messages.isNotEmpty;
        if (showTitle) {
          final painter = TextPainter(
            text: TextSpan(text: 'JARVIS', style: nameStyle),
            textDirection: Directionality.of(context),
            textScaler: headScaler ?? MediaQuery.textScalerOf(context),
          )..layout();
          showTitle = painter.width + 8 + 48 <= box.maxWidth;
          painter.dispose();
        }
        return Row(
          key: const ValueKey('chat-heading-line'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (foldable)
              Flexible(child: title)
            else ...[
              // Alone it may shrink (and ellipsize) in a very narrow header; beside the name it keeps its width.
              if (showTitle)
                Text('JARVIS', textScaler: headScaler, style: nameStyle)
              else
                Flexible(
                  child: Text(
                    'JARVIS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: headScaler,
                    style: nameStyle,
                  ),
                ),
              if (showTitle)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: title,
                  ),
                ),
            ],
          ],
        );
      },
    );
    final tooltip = c.connectionError != null ? '重新检查连接' : '模型连接';
    final row = ConstrainedBox(
      // A large text size grows the row; the 48 is only the floor of the tap area.
      constraints: const BoxConstraints(minWidth: 44, minHeight: 48),
      child: Row(
        mainAxisSize: foldable ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Flexible(child: heading),
          SizedBox(width: foldable ? 10 : 8),
          dot,
          if (foldable) const SizedBox(width: 6),
        ],
      ),
    );
    final button = Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: '$state，打开模型状态',
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.small),
          onTap: openStatus,
          child: row,
        ),
      ),
    );
    return foldable
        ? Align(alignment: Alignment.centerLeft, child: button)
        : button;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final size = MediaQuery.sizeOf(context),
          padding = MediaQuery.viewPaddingOf(context);
      final layout = AdaptiveLayout.forWindow(
        size.width,
        size.height,
        horizontalInsets: padding.horizontal,
        verticalInsets: padding.vertical,
      );
      if (lastDefault != layout.docked) {
        lastDefault = layout.docked;
        showDocked = null;
        if (layout.docked) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && lastDefault == true) {
              scaffold.currentState?.closeDrawer();
            }
          });
        }
      }
      final docked = layout.docked && (showDocked ?? true);
      final paneWidth = math.max(
        0.0,
        size.width - padding.horizontal - layout.sidebarWidth,
      );
      // iPhone Duo: the toolbar controls live in the system's vertical strip instead of the header.
      final duo = DuoLayoutScope.of(context), rail = duo.hasVerticalBar;
      // Foldable iPhone: the composer sits flush to the bottom with the same gap as left/right, and is 20% narrower on
      // the unfolded (regular width) screen.
      final foldable = duo.isFoldable;
      final unfolded = foldable && size.shortestSide >= 600;
      // Unfolded Duo with the session list collapsed: the content column is 20% wider (the composer follows it).
      final collapsedWider =
          layout.docked && !docked && foldable && size.shortestSide >= 600;
      // Half-folded in landscape: the messages, banners, composer and header keep to one side of the fold, so no text
      // or control sits on the crease (the strip is laid out as before). It is the right side whenever that has room,
      // whether or not the session list is docked, so showing or hiding the list never moves the column across the
      // crease.
      final fold = duo.verticalFold;
      final area = docked ? paneWidth : size.width - padding.horizontal;
      _FoldColumn? column;
      if (fold != null) {
        final areaRight = size.width - padding.right;
        final areaLeft = areaRight - area;
        if (fold.right > areaLeft && fold.left < areaRight) {
          if (areaRight - fold.right >= 240) {
            column = _FoldColumn.right(areaRight - fold.right);
          } else if (fold.left - areaLeft >= 240) {
            column = _FoldColumn.left(
              fold.left - areaLeft,
              areaRight - fold.left,
            );
          }
        }
      }
      final folded = column != null;
      if (column != null) foldColumn = column;
      // Opening or closing the fold fades the column through the change instead of snapping it (the first layout starts in
      // place). A window that has just changed size (rotation) takes its new geometry at once: the old one is not the
      // one to fade out of.
      final resized = foldWindow != null && foldWindow != size;
      foldWindow = size;
      if (resized || foldSnap != null) {
        foldAnim.stop();
        foldedTarget = folded;
        if (foldSnap == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            foldAnim.value = foldedTarget! ? 1 : 0;
            foldSnap = null;
            foldSeeded = true;
          });
        }
        foldSnap = folded ? 1.0 : 0.0;
      } else if (foldedTarget == null) {
        foldedTarget = folded;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          foldAnim.value = foldedTarget! ? 1 : 0;
          foldSeeded = true;
        });
      } else if (foldedTarget != folded) {
        foldedTarget = folded;
        final duration = motion(context, 320);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || foldedTarget != folded) return;
          if (duration == Duration.zero) {
            foldAnim.value = folded ? 1 : 0;
          } else {
            foldAnim.animateTo(
              folded ? 1 : 0,
              duration: duration,
              curve: Curves.easeInOutCubic,
            );
          }
        });
      }
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      // The header disappears below this much body height; on a foldable it is taller by headerShift. Its row grows
      // with the text size (the title line is taller than 56 at the largest sizes).
      final titleStyle = Theme.of(context).textTheme.titleMedium!;
      final headerHeight = math.max(
        56.0,
        MediaQuery.textScalerOf(context).scale(titleStyle.fontSize ?? 16) *
            (titleStyle.height ?? 1.5),
      );
      final headerShift = DuoLayoutScope.of(context).headerShiftY;
      final headerBlock = headerHeight + (foldable ? headerShift : 0);
      final headerMinimum = foldable ? 200 + headerShift : 200.0;
      // Body height with the keyboard up. Typing needs a composer of a few lines and the messages need a strip of their
      // own, so the header gives way before either is squeezed.
      final typingRoom = size.height - keyboardInset - padding.vertical;
      // The space under the composer narrows as the keyboard comes up and widens as it goes: it follows the keyboard (over
      // its first 80 pt) instead of switching on a timer of its own, so nothing settles after the keyboard has stopped.
      final composerGap = foldable
          ? 10.0 +
                (DuoLayout.edgeGap - 10.0) *
                    (1 -
                        Curves.easeInOut.transform(
                          (keyboardInset / 80).clamp(0.0, 1.0),
                        ))
          : 10.0;
      // The note that says why sending is impossible takes a line of the composer's own.
      final typed =
          widget.controller.current.draft.trim().isNotEmpty ||
          widget.controller.current.pendingAttachments.isNotEmpty;
      final noteRoom = sendBlockedReason(widget.controller, typed) == null
          ? 0.0
          : MediaQuery.textScalerOf(context).scale(12) * 1.4 + 2;
      // The error line under the messages: tap for the whole text, dismiss with the cross.
      final errorText =
          widget.controller.error ?? widget.controller.storageError;
      if (errorText == null) dismissedError = null;
      final showError = errorText != null && errorText != dismissedError;
      final offlineNow = widget.offline?.call() ?? false;
      // Every band the column carries besides the messages is counted in the budget, or a large text size pushes the
      // composer (and the send button) under the keyboard: the attachment row and loading bar inside the composer, the
      // call bar, the offline bar and the error line. Wrapped text is estimated at one em per character, which is exact
      // for Chinese and generous for Latin.
      final scaler = MediaQuery.textScalerOf(context);
      final bandWidth = math.max(120.0, (column?.room ?? area) - 24);
      double wrapped(
        String text,
        double fontSize,
        double width, {
        int maxLines = 99,
      }) {
        var lines = 0;
        for (final line in text.split('\n')) {
          lines += math.max(
            1,
            (line.length * scaler.scale(fontSize) / width).ceil(),
          );
        }
        return math.min(lines, maxLines).toDouble();
      }

      // The error text lies left of the cross (and "从空白开始"); the offline text left of its retry button.
      final errorWidth =
          bandWidth -
          52 -
          (widget.controller.storageReadOnly ? scaler.scale(14) * 5 + 24 : 0);
      double errorBand(int maxLines) => showError
          ? math.max(
              48.0,
              wrapped(errorText, 14, errorWidth, maxLines: maxLines) *
                      scaler.scale(14) *
                      1.45 +
                  12,
            )
          : 0.0;
      final offlineBand = !offlineNow
          ? 0.0
          : math.max(
              44.0,
              wrapped(
                        '网络不可用，历史记录为本机副本',
                        12,
                        bandWidth -
                            24 -
                            (widget.onRetry == null
                                ? 0
                                : math.max(44.0, scaler.scale(14) * 2 + 24)),
                      ) *
                      scaler.scale(12) *
                      1.4 +
                  12,
            );
      final callBand =
          widget.controller.voice.active && !widget.controller.voice.open
          ? 48.0
          : 0.0;
      final attachBand =
          (widget.controller.current.pendingAttachments.isNotEmpty ? 48 : 0) +
          (widget.controller.attachmentsLoading(widget.controller.current.id)
              ? 16.0
              : 0);
      // The text field never gets less than this, whatever is above it.
      // A short landscape window puts the buttons in the field's own row (see Composer): no row of buttons under it.
      final compactComposer = size.width > size.height && size.height < 520;
      final fieldMinimum = compactComposer
          ? 48.0
          : foldable
          ? 56.0
          : 48.0;
      // Outer padding, frame border and padding, the row of buttons under the field, and that note.
      final composerBase =
          4 +
          composerGap +
          2 +
          8 +
          (compactComposer ? 0 : 48) +
          noteRoom +
          attachBand;
      // With the keyboard up and too little room left for the messages, typing wins: the offline bar steps aside and
      // the error line keeps to one line (a tap still opens the whole text).
      final tight =
          keyboardInset > 0 &&
          typingRoom -
                  composerBase -
                  callBand -
                  offlineBand -
                  errorBand(3) -
                  fieldMinimum -
                  _messagesMinimum <
              0;
      final showOffline = offlineNow && !tight;
      final errorLines = tight ? 1 : 3;
      final composerChrome =
          composerBase +
          callBand +
          (showOffline ? offlineBand : 0) +
          errorBand(errorLines);
      // How much room is left over once the header is counted (negative: it gives way).
      final headerSlack = math.min(
        typingRoom - headerMinimum,
        keyboardInset <= 0
            ? double.infinity
            : typingRoom -
                  (headerBlock +
                      composerChrome +
                      _messagesMinimum +
                      (foldable ? 96 : 82)),
      );
      // A phone on its side has no room for the header once the keyboard is up. It folds away as the keyboard starts to
      // rise, not half way up it, so the page below moves once, together with the keyboard, instead of once for the
      // keyboard and again when the header gives way.
      final sideways = size.width > size.height && size.height < 520;
      final headerShown =
          !(sideways && keyboardInset > 0) &&
          headerSlack >= (headerWasShown == false ? _headerHysteresis : 0);
      headerWasShown = headerShown;
      final headerShownAtRest = size.height - padding.vertical >= headerMinimum;
      // On its side the header folds with the keyboard, step for step: over the first 160 pt of the keyboard's rise, and
      // back out as it goes down. The page below, the composer and the welcome avatar then all move on one clock.
      final headerMotion = headerFold ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 180),
        value: headerShown ? 1 : 0,
      );
      final headerFollow = sideways && keyboardInset > 0 && headerShownAtRest
          ? 1 -
                Curves.easeInOut.transform(
                  (keyboardInset / 160).clamp(0.0, 1.0),
                )
          : null;
      // The header's own fold runs on its timer, except while the keyboard sets the pace; the hand-back carries on from
      // where the header already is.
      final headerGoal = headerShown ? 1.0 : 0.0;
      if (headerFollow != null) {
        headerFollowing = true;
        headerTarget = headerShown;
      } else if (headerFollowing) {
        headerFollowing = false;
        headerTarget = headerShown;
        headerMotion.value = headerGoal;
      } else if (headerTarget != headerShown) {
        headerTarget = headerShown;
        if (MediaQuery.disableAnimationsOf(context)) {
          headerMotion.value = headerGoal;
        } else {
          unawaited(headerMotion.animateTo(headerGoal));
        }
      }
      // Half-folded in portrait: the welcome page and the composer's growth stay in the half under the crease.
      final across = duo.horizontalFold;
      final bodyTop =
          MediaQuery.paddingOf(context).top + (headerShown ? headerBlock : 0);
      var maxField = math.min(
        160.0,
        typingRoom -
            (headerShown ? headerBlock : 0) -
            composerChrome -
            _messagesMinimum,
      );
      if (across != null) {
        maxField = math.min(
          maxField,
          size.height - keyboardInset - across.bottom - composerChrome - 4,
        );
      }
      maxField = math.max(fieldMinimum, maxField);
      void toggleSidebar() {
        if (layout.docked) {
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => showDocked = !docked);
        } else if (rail &&
            (scaffold.currentState?.isDrawerOpen ?? drawerOpen)) {
          // The side strip stays on top of the open drawer, so the same button closes it again.
          scaffold.currentState?.closeDrawer();
        } else {
          FocusManager.instance.primaryFocus?.unfocus();
          scaffold.currentState?.openDrawer();
        }
      }

      void newChat() {
        tapFeedback();
        FocusManager.instance.primaryFocus?.unfocus();
        widget.controller.newConversation();
      }

      // The column fades out, switches layout at the midpoint and fades back in, so every message does not re-wrap
      // frame by frame on the way. Only this subtree follows that animation.
      final content = AnimatedBuilder(
        animation: foldAnim,
        builder: (context, _) {
          final foldValue =
              foldSnap ?? (foldSeeded ? foldAnim.value : (folded ? 1.0 : 0.0));
          final foldT = foldValue >= .5 ? 1.0 : 0.0;
          final foldFade = foldSeeded || foldSnap != null
              ? (2 * foldValue - 1).abs()
              : 1.0;
          final side = foldT == 0 ? null : (foldColumn ?? column);
          // Half-folded the roomier side is narrow, so the margins shrink too: a little to the crease, a bit more to the
          // screen edge (or the strip).
          final gapLeft = side == null
              ? DuoLayout.edgeGap
              : side.onRight
              ? _creaseGap
              : _screenGap;
          final gapRight = side == null
              ? DuoLayout.edgeGap
              : side.onRight
              ? _screenGap
              : _creaseGap;
          final foldWidth = side?.room ?? area;
          final contentWidth = layout.docked
              ? math.min(
                  foldWidth,
                  collapsedWider
                      ? math.min(
                          size.width - padding.horizontal,
                          paneWidth * 1.2,
                        )
                      : paneWidth,
                )
              : foldWidth;
          // A plain phone in landscape (or any wide window) keeps messages and composer to a readable column.
          Widget centerContent(Widget child) => Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: foldable
                  ? contentWidth
                  : math.min(contentWidth, _readingWidth),
              child: child,
            ),
          );
          // Half-folded, the roomier side of the fold is narrow, so its column (messages, welcome cards, composer) is 20%
          // wider than usual, up to the whole side.
          final contentFactor = math.min(
            1.0,
            (docked
                    ? DuoLayout.dockedContentFactor
                    : DuoLayout.unfoldedContentFactor) *
                (1 + .2 * foldT),
          );
          // Foldable: strips above the composer (call banner, error text) sit in the same centred frame as the composer.
          Widget framed(Widget child, {double? left}) => !foldable
              ? (contentWidth > _readingWidth ? centerContent(child) : child)
              : centerContent(
                  FractionallySizedBox(
                    widthFactor: unfolded ? contentFactor : 1,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        left ?? gapLeft,
                        0,
                        gapRight,
                        0,
                      ),
                      child: child,
                    ),
                  ),
                );

          final body = <Widget>[
            Expanded(
              child: centerContent(
                AnimatedBuilder(
                  animation: headerCurve,
                  builder: (context, _) => ChatPanel(
                    key: ValueKey(widget.controller.selectedId),
                    controller: widget.controller,
                    keyboardInset: keyboardInset,
                    composerFocus: composerFocus,
                    onCancelTask: widget.onCancelTask,
                    openSettings: widget.openSettings,
                    onContinue: widget.onContinue,
                    foldEpoch: foldT.round(),
                    topInset: across == null
                        ? 0
                        : math.max(0.0, across.bottom - bodyTop),
                    // Unfolded: the message column is exactly as wide as the composer frame.
                    horizontalInset: unfolded
                        ? (layout.docked
                                      ? contentWidth
                                      : math.min(
                                          foldWidth,
                                          size.width - padding.horizontal,
                                        )) *
                                  (1 - contentFactor) /
                                  2 +
                              gapLeft
                        // A docked list's grip lies over the left 24 pt of the pane: the text starts clear of it.
                        : docked && !foldable
                        ? sidebarGripWidth + 2
                        : null,
                    rightInset: unfolded
                        ? (layout.docked
                                      ? contentWidth
                                      : math.min(
                                          foldWidth,
                                          size.width - padding.horizontal,
                                        )) *
                                  (1 - contentFactor) /
                                  2 +
                              gapRight
                        : null,
                    // How far the header has given way: the page below glides down by as much, so it stays where it is.
                    welcomeTopInset: headerShownAtRest
                        ? headerBlock *
                              (1 - (headerFollow ?? headerCurve.value))
                        : 0,
                    welcomeInsetLive: true,
                    animateIn: chatBuilt,
                  ),
                ),
              ),
            ),
            SmoothSize(
              milliseconds: 180,
              alignment: Alignment.bottomCenter,
              child: !showOffline
                  ? const SizedBox(width: double.infinity)
                  : framed(
                      Padding(
                        padding: EdgeInsets.only(
                          left: foldable ? 0 : 16,
                          right: foldable ? 0 : 4,
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(
                            key: const Key('offline-bar'),
                            children: [
                              Icon(
                                Icons.cloud_off_outlined,
                                size: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    '网络不可用，历史记录为本机副本',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ),
                              if (widget.onRetry != null)
                                TextButton(
                                  key: const Key('offline-retry'),
                                  onPressed: widget.onRetry,
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(44, 44),
                                  ),
                                  // The label stays to hold the button's width; the ring takes its place while it tries.
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Opacity(
                                        opacity: widget.controller.connecting
                                            ? 0
                                            : 1,
                                        child: const Text('重试'),
                                      ),
                                      if (widget.controller.connecting)
                                        const JarvisSpinner.inline(
                                          semanticsLabel: '正在重试',
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
            SmoothSize(
              alignment: Alignment.bottomCenter,
              child: !showError
                  ? const SizedBox(width: double.infinity)
                  : framed(
                      Padding(
                        padding: EdgeInsets.only(
                          left: foldable ? 0 : 16,
                          right: foldable ? 0 : 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                button: true,
                                hint: '查看完整内容',
                                child: InkWell(
                                  key: const Key('error-line'),
                                  borderRadius: BorderRadius.circular(
                                    Radii.small,
                                  ),
                                  onTap: () => showErrorDetail(errorText),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Text(
                                      errorText,
                                      maxLines: errorLines,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (widget.controller.storageReadOnly)
                              TextButton(
                                key: const Key('start-fresh'),
                                onPressed: startFresh,
                                child: const Text('从空白开始'),
                              ),
                            IconButton(
                              key: const Key('error-dismiss'),
                              tooltip: '关闭',
                              onPressed: () =>
                                  setState(() => dismissedError = errorText),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            SmoothSize(
              milliseconds: 180,
              alignment: Alignment.bottomCenter,
              child:
                  widget.controller.voice.active &&
                      !widget.controller.voice.open
                  ? framed(
                      Container(
                        margin: EdgeInsets.symmetric(
                          horizontal: foldable ? 0 : 12,
                        ),
                        padding: const EdgeInsets.only(left: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(Radii.sheet),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 7,
                              color: JarvisColors.success(context),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.controller.voice.owner ==
                                        widget.controller.current
                                    ? '语音通话中'
                                    : '后台语音 · ${widget.controller.voice.owner?.title ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: '展开语音界面',
                              onPressed: widget.controller.voice.expand,
                              icon: const Icon(Icons.expand_less, size: 20),
                            ),
                            HangupButton(
                              onPressed: widget.controller.voice.stop,
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            centerContent(
              FractionallySizedBox(
                widthFactor: unfolded ? contentFactor : 1,
                // The notice anchors to the composer itself, so it lines up with the (narrower) frame.
                child: SizedBox(
                  key: composerBounds,
                  child: Composer(
                    key: ValueKey('composer-${widget.controller.selectedId}'),
                    controller: widget.controller,
                    keyboardVisible: keyboardInset > 0,
                    keyboardInset: keyboardInset,
                    focusNode: composerFocus,
                    openSettings: widget.openSettings,
                    noticeContext: () =>
                        paneBounds.currentContext ?? (mounted ? context : null),
                    edgeGap: foldable ? DuoLayout.edgeGap : null,
                    leftGap: foldable ? gapLeft : null,
                    rightGap: foldable ? gapRight : null,
                    bottomGap: foldable ? composerGap : null,
                    maxFieldHeight: maxField,
                  ),
                ),
              ),
            ),
          ];

          // The header follows the column: on a foldable it starts at the same left edge as the composer frame, and
          // half-folded it keeps to the same side of the crease.
          final heading = foldable
              ? headingTitle(context, foldable: true)
              : headingTitle(context, foldable: false);
          final header = Row(
            children: [
              if (!rail)
                IconButton(
                  tooltip: docked ? '收起会话' : '展开会话',
                  icon: const Icon(Icons.menu, size: 20),
                  onPressed: toggleSidebar,
                ),
              Expanded(child: heading),
              if (!rail)
                IconButton(
                  key: const Key('start-new-chat'),
                  tooltip: '新建会话',
                  onPressed: newChat,
                  icon: const Icon(Icons.edit_square, size: 20),
                ),
              if (!rail)
                JarvisActionMenu(
                  tooltip: '更多操作',
                  actions: const [
                    JarvisMenuAction('settings', '设置', icon: Icons.tune),
                    JarvisMenuAction(
                      'status',
                      '模型状态',
                      icon: Icons.monitor_heart_outlined,
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'settings') {
                      settings();
                    } else {
                      openStatus();
                    }
                  },
                ),
            ],
          );

          return NoticeAnchor(
            pane: paneBounds,
            composer: composerBounds,
            composerInset: foldable ? gapLeft : 10,
            composerInsetRight: foldable ? gapRight : 10,
            child: Builder(
              key: paneBounds,
              builder: (context) => Padding(
                // Scaffold already consumes the IME. Reserve only the remaining
                // stable navigation inset, independent of late padding restoration.
                padding: EdgeInsets.only(
                  bottom: foldable
                      ? 0
                      : math.max(0, padding.bottom - keyboardInset),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Opacity(
                    key: const Key('fold-fade'),
                    opacity: foldFade,
                    // Invisible is not untouchable: nothing in the column answers while it fades.
                    child: IgnorePointer(
                      ignoring: foldFade < 1,
                      child: LayoutBuilder(
                        builder: (context, box) => Padding(
                          padding:
                              side?.insetFor(box.maxWidth) ?? EdgeInsets.zero,
                          child: Column(
                            children: [
                              _HeaderSlot(
                                shown: headerShown,
                                animation: headerCurve,
                                follow: headerFollow,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    top: foldable ? headerShift : 0,
                                  ),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: 56,
                                    ),
                                    // On the strip layouts the heading is all there is, so it takes the column's frame; the
                                    // outer display keeps its 28 pt clearance from the rounded corner.
                                    child: foldable && rail
                                        ? framed(
                                            heading,
                                            left: unfolded
                                                ? gapLeft
                                                : math.max(gapLeft, 28),
                                          )
                                        : header,
                                  ),
                                ),
                              ),
                              Expanded(child: Column(children: body)),
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
        },
      );
      return PopScope(
        canPop: !widget.controller.voice.open && !drawerOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            if (JarvisActionMenu.closeOpen()) return;
            if (drawerOpen) {
              scaffold.currentState?.closeDrawer();
            } else if (widget.controller.voice.open) {
              widget.controller.voice.minimize();
            }
          }
        },
        child: Stack(
          children: [
            TickerMode(
              enabled: !widget.controller.voice.open,
              child: ExcludeFocus(
                excluding: widget.controller.voice.open,
                child: ExcludeSemantics(
                  excluding: widget.controller.voice.open,
                  child: Scaffold(
                    key: scaffold,
                    onDrawerChanged: (open) {
                      if (open) FocusManager.instance.primaryFocus?.unfocus();
                      setState(() => drawerOpen = open);
                    },
                    resizeToAvoidBottomInset: true,
                    // Keep the drawer controller alive so its internal open
                    // state can be closed when switching to a docked layout.
                    drawerEnableOpenDragGesture: !layout.docked,
                    // While it slides shut it is a picture: a touch would make the drawer catch it again (reopening it, or
                    // tapping a row twice).
                    drawer: IgnorePointer(
                      ignoring: !drawerOpen,
                      child: Drawer(
                        // Outer display of a foldable: the conversation drawer is 21% wider (10% twice).
                        width: drawerWidth(
                          foldable && size.shortestSide < 600
                              ? layout.sidebarWidth * 1.21
                              : layout.sidebarWidth,
                          size.width - padding.horizontal,
                        ),
                        elevation: 0,
                        backgroundColor:
                            Theme.of(context).brightness == Brightness.dark
                            ? Theme.of(context).colorScheme.surfaceContainerLow
                            : Theme.of(context).colorScheme.surface,
                        surfaceTintColor: Colors.transparent,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.horizontal(
                            right: Radius.circular(Radii.sheet),
                          ),
                        ),
                        // The rows keep readable titles at the largest text sizes: the drawer widens (see [drawerWidth])
                        // and its text stops growing at 1.6x.
                        child: MediaQuery.withClampedTextScaling(
                          maxScaleFactor: 1.6,
                          child: sidebar(drawer: true),
                        ),
                      ),
                    ),
                    body: SafeArea(
                      top: false,
                      bottom: false,
                      child: layout.docked
                          ? dockedSidebar(
                              layout.sidebarWidth,
                              docked,
                              Duration(
                                milliseconds:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? 0
                                    : 200,
                              ),
                              content,
                            )
                          : content,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: CompletedWorksPresenter(
                controller: widget.controller,
                allowPresentation: !drawerOpen,
                onCancelTask: widget.onCancelTask,
                openSettings: widget.openSettings,
                child: VoiceOverlay(
                  controller: widget.controller,
                  open: widget.controller.voice.open,
                ),
              ),
            ),
            DuoRail(
              // One long-lived strip, above the call page: while the call is open it switches to the call's buttons
              // (the native view animates the change) instead of being replaced by the call page's own strip.
              top: widget.controller.voice.open
                  ? voiceCallRail(
                      context,
                      widget.controller,
                      onCancelTask: widget.onCancelTask,
                      openSettings: widget.openSettings,
                    ).top
                  : [
                      DuoRailAction(
                        id: 'sidebar',
                        icon: Icons.menu,
                        symbol: 'sidebar.leading',
                        label: docked || drawerOpen ? '收起会话' : '展开会话',
                        onPressed: toggleSidebar,
                      ),
                      DuoRailAction(
                        id: 'new-chat',
                        icon: Icons.edit_square,
                        symbol: 'square.and.pencil',
                        label: '新建会话',
                        onPressed: newChat,
                      ),
                    ],
              bottom: widget.controller.voice.open
                  ? voiceCallRail(
                      context,
                      widget.controller,
                      onCancelTask: widget.onCancelTask,
                      openSettings: widget.openSettings,
                    ).bottom
                  : [
                      DuoRailAction(
                        id: 'settings',
                        icon: Icons.settings_outlined,
                        symbol: 'gearshape',
                        label: '设置',
                        onPressed: settings,
                      ),
                    ],
            ),
          ],
        ),
      );
    },
  );
}

class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.controller,
    this.keyboardInset = 0,
    this.welcomeTopInset = 0,
    this.welcomeInsetLive = false,
    this.topInset = 0,
    this.horizontalInset,
    this.rightInset,
    this.foldEpoch = 0,
    this.composerFocus,
    this.onCancelTask,
    this.openSettings,
    this.onContinue,
    this.animateIn = false,
  });
  final JarvisController controller;

  /// Whether this page fades in as it is built (a conversation switch, a new chat) instead of being there at once.
  final bool animateIn;

  /// See [JarvisHome.onCancelTask], [JarvisHome.openSettings] and [JarvisHome.onContinue].
  final void Function(MediaTask task)? onCancelTask;
  final Future<void> Function()? openSettings;
  final VoidCallback? onContinue;
  final double keyboardInset;
  final double welcomeTopInset;

  /// [welcomeTopInset] already moves smoothly by itself (with the keyboard): the page takes it as it comes.
  final bool welcomeInsetLive;

  /// Space kept free above the welcome page: the half of the screen over a horizontal fold, so its cards stay off the
  /// crease.
  final double topInset;

  /// Changes whenever the column moves to the other side of a fold: the text re-wraps then, and the reading place is
  /// kept across it.
  final int foldEpoch;

  /// The composer's input focus: a tapped welcome card moves the caret there.
  final FocusNode? composerFocus;

  /// Left space around the messages; null keeps the default 18.
  final double? horizontalInset;

  /// Right space; null is the same as the left.
  final double? rightInset;
  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final scroll = FollowScrollController();

  /// Selectable text carries its own tiny scroller. Under the list's PageStorageKey it would restore the list's
  /// offset (tens of thousands of pixels) and spring back from it, so older replies slid in while scrolling up.
  /// This separate bucket keeps the list's offset away from them and still remembers the reasoning panels.
  final _contentStorage = PageStorageBucket();
  double? _welcomeHeight, _welcomeWidth;
  final _avatarKey = GlobalKey(debugLabel: 'welcome-avatar'),
      _stageKey = GlobalKey(debugLabel: 'welcome-stage');
  Offset? _avatarRest;
  String? _conversationId;
  int _userMessages = 0;

  /// Read once: whether this page fades in as it is built.
  late final bool _animateIn = widget.animateIn;

  /// Messages already on screen, and the ones that arrived a moment ago (these slide and fade in once).
  final _seen = <String>{}, _fresh = <String>{};
  String? _seenFor;
  Timer? _freshTimer;

  @override
  void didUpdateWidget(ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyboardInset != widget.keyboardInset) {
      scroll.keyboardChanged();
    }
    if (oldWidget.foldEpoch != widget.foldEpoch) scroll.keepReadingPlace();
  }

  @override
  void dispose() {
    _freshTimer?.cancel();
    scroll.dispose();
    super.dispose();
  }

  /// A welcome card fills the draft; the caret goes to its end so typing can continue straight away. Text the user has
  /// already written stays: the card's prompt goes on a new line after it.
  void useStarter(String prompt) {
    tapFeedback();
    final c = widget.controller.current;
    final written = c.draft.trimRight();
    c.draft = written.isEmpty ? prompt : '$written\n$prompt';
    widget.controller.notifyDraftSuggestion();
    widget.composerFocus?.requestFocus();
  }

  /// Foldable: horizontal padding of the message list. The composer frame sits [DuoLayout.edgeGap] inside the pane (or
  /// at [ChatPanel.horizontalInset]); the message column is that frame narrowed by [DuoLayout.replyWidthFactor],
  /// centred, so both sides stay symmetric with the composer.
  EdgeInsets messageInset(double paneWidth) {
    final left = widget.horizontalInset ?? DuoLayout.edgeGap;
    final right = widget.rightInset ?? left;
    final narrowing =
        math.max(0.0, paneWidth - left - right) *
        (1 - DuoLayout.replyWidthFactor) /
        2;
    return EdgeInsets.fromLTRB(left + narrowing, 0, right + narrowing, 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller.current;
    final userMessages = c.messages.where((m) => m.role == 'user').length;
    if (_conversationId == c.id && userMessages > _userMessages) {
      scroll.resumeFollowing();
    }
    _conversationId = c.id;
    _userMessages = userMessages;
    if (_seenFor != c.id) {
      // Opening a conversation shows its history as it is; only messages added afterwards animate in.
      _seenFor = c.id;
      _seen
        ..clear()
        ..addAll(c.messages.map((m) => m.id));
      _fresh.clear();
    } else {
      var arrived = false;
      for (final m in c.messages) {
        if (_seen.add(m.id)) {
          _fresh.add(m.id);
          arrived = true;
        }
      }
      // Re-armed only by a new message: streaming rebuilds must not keep extending the window.
      if (arrived) {
        // Once their entrance is over they are history: rebuilding or scrolling back never replays them.
        _freshTimer?.cancel();
        _freshTimer = Timer(const Duration(milliseconds: 600), _fresh.clear);
      }
    }
    // A short landscape window (a phone on its side, the outer display of a foldable on its side): the greeting on the
    // left, the four cards on the right. The layout follows the window alone, so nothing appears or disappears as the
    // header, the composer or the keyboard change the room. With the keyboard up the greeting and the cards fade out
    // and the avatar glides, shrinking, to the middle of what is left above the composer.
    Widget buildSidewaysWelcome(BoxConstraints bounds, double height) {
      final web = DuoLayoutScope.of(context).isFoldable;
      final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
      final edge = web ? DuoLayout.edgeGap : 16.0;
      final left = widget.horizontalInset ?? edge;
      final right = widget.rightInset ?? widget.horizontalInset ?? edge;
      final inner = math.max(0.0, bounds.maxWidth - left - right);
      final greetingWidth = (inner * .38).clamp(180.0, 280.0);
      const gutter = 24.0, gap = 10.0;
      final cardsWidth = math.max(
        2 * 120.0 + gap,
        math.min(inner - greetingWidth - gutter, 460.0),
      );
      final cardWidth = (cardsWidth - gap) / 2;
      final starters = widget.controller.starters;
      final lines = web
          ? starterDescriptionLines(context, starters, cardWidth, compact: true)
          : 1;
      final tile = (web ? 68 + (lines > 1 ? 18 : 0) : 48) * scale;
      final avatarBase = math.min(150.0, height * .5).clamp(88.0, 150.0);
      // A larger text size leaves the room too small for everything at its natural size: the avatar gives way first, then
      // the hint goes; the four cards always stay, and when their column is taller than the room the page scrolls (at 1x
      // nothing changes).
      final grown = scale > 1.001;
      final fitRoom = math.max(0.0, height - 16);
      final textTheme0 = Theme.of(context).textTheme;
      // The greeting stops growing at 1.6x, or it wraps onto a second line the page has no room for.
      final titleScaler = MediaQuery.textScalerOf(context)
          .clamp(maxScaleFactor: 1.6);
      final titleHeight = !grown
          ? 0.0
          : 8 +
                _measureText(
                  context,
                  web ? timeGreeting(DateTime.now()) : '想聊点什么？',
                  web
                      ? textTheme0.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        )
                      : textTheme0.titleLarge,
                  titleScaler,
                  greetingWidth,
                );
      final hintHeight = !grown
          ? 0.0
          : 4 +
                _measureText(
                  context,
                  web ? '有什么想聊的？\n输入问题，或点击麦克风直接说话。' : '写下想法，或直接开口。',
                  textTheme0.bodySmall,
                  MediaQuery.textScalerOf(context),
                  greetingWidth,
                  maxLines: 2,
                );
      final showHint = !grown || fitRoom >= 64 * .78 + titleHeight + hintHeight;
      // Only ever smaller as the text grows: once the hint has gone the avatar stays at its smallest.
      final avatar = !grown
          ? avatarBase.toDouble()
          : !showHint
          ? 64.0
          : math
                .min(
                  avatarBase.toDouble(),
                  (fitRoom - titleHeight - hintHeight) / .78,
                )
                .clamp(64.0, 150.0)
                .toDouble();
      final shownCards = starters.length;
      const icons = [
        Icons.tips_and_updates_outlined,
        Icons.auto_awesome_outlined,
        Icons.code,
        Icons.checklist,
      ];
      final textTheme = Theme.of(context).textTheme;
      final colors = Theme.of(context).colorScheme;
      // Where the avatar rests, found in the page's own coordinates after layout; the page does not move while the
      // keyboard is up, so this stays true then.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final avatarBox = _avatarKey.currentContext?.findRenderObject();
        final stageBox = _stageKey.currentContext?.findRenderObject();
        if (avatarBox is RenderBox &&
            stageBox is RenderBox &&
            avatarBox.attached &&
            stageBox.attached &&
            avatarBox.hasSize) {
          _avatarRest = stageBox.globalToLocal(
            avatarBox.localToGlobal(avatarBox.size.center(Offset.zero)),
          );
        }
      });
      // The room above the composer is read as it is, frame by frame: the keyboard's own motion is the only clock here, so
      // the avatar and the fading parts move exactly with the composer, up and down, and need no timer of their own.
      final room = bounds.maxHeight;
      return ClipRect(
        // The header folds away over the same 180 ms: the page glides to where the screen has it.
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: widget.welcomeTopInset),
          duration: motion(context, widget.welcomeInsetLive ? 0 : 180),
          curve: Curves.easeOutCubic,
          builder: (context, inset, _) {
            // How far the keyboard has taken the room above the composer, 0 to 1 once a third of it is gone, shaped so the
            // move starts and ends softly (no jolt where it begins or where it hands over to following the middle of
            // what is left).
            final taken = height - (room - inset);
            final up = Curves.easeInOut.transform(
              (taken / (height * .34)).clamp(0.0, 1.0),
            );
            // Where the avatar parks: the middle of the room that is left, a little smaller.
            final parked = (room - 24).clamp(56.0, 120.0);
            final parkedScale = math.min(1.0, parked / avatar);
            final parkedAt = Offset(left + inner / 2, room / 2 - inset);
            // The greeting and the cards give way, a little ahead of the avatar's move.
            final fading =
                1 -
                Curves.easeInOut.transform(
                  (taken / (height * .2)).clamp(0.0, 1.0),
                );
            Widget fade(Widget child) => IgnorePointer(
              ignoring: fading < .5,
              child: ExcludeSemantics(
                excluding: fading < .5,
                child: Opacity(opacity: fading, child: child),
              ),
            );
            final rest = _avatarRest;
            final glide = rest == null ? Offset.zero : parkedAt - rest;
            final shrink = rest == null ? 1.0 : 1 + (parkedScale - 1) * up;
            // The soft follow lags the keyboard by design, but never behind the composer: each frame the avatar is held
            // 4 pt above the top of the composer (the bottom of this room) and kept within the room's height.
            (Offset, double) keepClear(Offset shift, double scale) {
              if (rest == null) return (shift, scale);
              final fit = math.min(
                scale,
                math.max(.1, (room - 8) / (avatar * .78)),
              );
              final lowest =
                  room - inset - 4 - avatar * .78 / 2 * fit - rest.dy;
              return (Offset(shift.dx, math.min(shift.dy, lowest)), fit);
            }

            return Transform.translate(
              offset: Offset(0, inset),
              // The height the page had before the keyboard came up: it stays where it is.
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: height,
                maxHeight: height,
                child: SizedBox(
                  key: _stageKey,
                  height: height,
                  child: SingleChildScrollView(
                    physics: iosScrollPhysics,
                    keyboardDismissBehavior: iosKeyboardDismiss,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.fromLTRB(left, 8, right, 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: math.max(0.0, height - 16),
                      ),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          // Cards taller than the room (the largest text sizes): the page scrolls, and the greeting
                          // keeps to the top rather than being centred on the cards, below the fold.
                          crossAxisAlignment: 2 * tile + gap > fitRoom
                              ? CrossAxisAlignment.start
                              : CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: greetingWidth,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _SoftFollow(
                                    // Only ever up: where the avatar rests is a little above the middle of the room, and
                                    // the first frames must not pull it down towards that middle.
                                    target: Offset(
                                      glide.dx * up,
                                      math.min(0.0, glide.dy * up),
                                    ),
                                    scale: shrink,
                                    builder: (context, shift, scale) {
                                      final (at, size) = keepClear(
                                        shift,
                                        scale,
                                      );
                                      return Transform(
                                        key: _avatarKey,
                                        alignment: Alignment.center,
                                        transform: Matrix4.translationValues(
                                          at.dx,
                                          at.dy,
                                          0,
                                        )..scaleByDouble(size, size, 1.0, 1.0),
                                        child: CoreAvatar(
                                          key: ValueKey(
                                            'empty-reactor-${c.id}',
                                          ),
                                          startupIdentity: c.id,
                                          size: avatar,
                                        ),
                                      );
                                    },
                                  ),
                                  fade(
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(height: 8),
                                        Text(
                                          web
                                              ? timeGreeting(DateTime.now())
                                              : '想聊点什么？',
                                          textAlign: TextAlign.center,
                                          textScaler: grown
                                              ? titleScaler
                                              : null,
                                          style: web
                                              ? textTheme.headlineSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    )
                                              : textTheme.titleLarge,
                                        ),
                                        if (showHint) const SizedBox(height: 4),
                                        if (showHint)
                                          Text(
                                            web
                                                ? '有什么想聊的？\n输入问题，或点击麦克风直接说话。'
                                                : '写下想法，或直接开口。',
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.bodySmall
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: gutter),
                            SizedBox(
                              width: cardsWidth,
                              child: fade(
                                Wrap(
                                  spacing: gap,
                                  runSpacing: gap,
                                  children: [
                                    for (var i = 0; i < shownCards; i++)
                                      SizedBox(
                                        width: cardWidth,
                                        height: tile,
                                        child: web
                                            ? WebStarterCard(
                                                key: ValueKey('starter-$i'),
                                                starter: starters[i],
                                                compact: true,
                                                descriptionLines: lines,
                                                onPressed: () => useStarter(
                                                  starters[i].prompt,
                                                ),
                                              )
                                            : OutlinedButton(
                                                key: ValueKey('starter-$i'),
                                                style: OutlinedButton.styleFrom(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                      ),
                                                  textStyle: textTheme.bodySmall
                                                      ?.copyWith(fontSize: 13),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          Radii.medium,
                                                        ),
                                                  ),
                                                ),
                                                onPressed: () => useStarter(
                                                  starters[i].prompt,
                                                ),
                                                child: Row(
                                                  children: [
                                                    Icon(icons[i], size: 18),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        starters[i].title,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                      ),
                                  ],
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
            );
          },
        ),
      );
    }

    Widget buildWelcome() {
      return Padding(
        padding: EdgeInsets.only(top: widget.topInset),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final window = MediaQuery.sizeOf(context);
            final tall =
                window.width < 600 && window.height >= window.width * 1.9;
            if (widget.keyboardInset <= 0 ||
                _welcomeHeight == null ||
                _welcomeWidth != bounds.maxWidth) {
              _welcomeHeight =
                  bounds.maxHeight +
                  widget.keyboardInset -
                  widget.welcomeTopInset;
              _welcomeWidth = bounds.maxWidth;
            }
            final height = _welcomeHeight!;
            if (window.width > window.height && window.height < 520) {
              return buildSidewaysWelcome(bounds, height);
            }
            // Preserve the welcome composition; the IME only lifts the composer.
            return ClipRect(
              // The header folds away over the same 180 ms: the welcome page glides to where the screen has it.
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: widget.welcomeTopInset),
                duration: motion(context, widget.welcomeInsetLive ? 0 : 180),
                curve: Curves.easeOutCubic,
                builder: (context, inset, child) =>
                    Transform.translate(offset: Offset(0, inset), child: child),
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: height,
                  maxHeight: height,
                  child: SizedBox(
                    height: height,
                    child: Builder(
                      builder: (context) {
                        double range(double low, double high) =>
                            ((height - low) / (high - low)).clamp(0.0, 1.0);
                        final spacious = tall ? range(360, 540) : 0.0;
                        final expanded = math.min(
                          bounds.maxWidth - 32,
                          math.min(360.0, height * .60),
                        );
                        final avatarBase =
                            88 +
                            100 * range(150, 300) +
                            math.max(0.0, expanded - 188) * spacious;
                        // Each part is either there or not: the welcome height only changes with the window (the keyboard
                        // does not move it), and a half-revealed row of cards would be cropped and untappable at rest.
                        double fits(double room) => height >= room ? 1 : 0;
                        // Foldable iPhone: the web client's welcome screen (greeting, two-line cards).
                        final web = DuoLayoutScope.of(context).isFoldable;
                        // Narrow (outer display) cards are ~172pt wide: the description wraps to two lines, so they are taller.
                        final sideLeft = widget.horizontalInset ?? 16,
                            sideRight = widget.rightInset ?? sideLeft;
                        final narrowCards =
                            (widget.horizontalInset == null
                                ? bounds.maxWidth - 32
                                : bounds.maxWidth - sideLeft - sideRight) <
                            420;
                        // The cards' width: the column (at most 620) shared by two with the gap between.
                        final cardWidth =
                            (math.min(
                                  bounds.maxWidth -
                                      (widget.horizontalInset == null
                                          ? 2 * DuoLayout.edgeGap
                                          : sideLeft + sideRight),
                                  620,
                                ) -
                                10) /
                            2;
                        final descriptionLines = web
                            ? starterDescriptionLines(
                                context,
                                widget.controller.starters,
                                cardWidth,
                                compact: narrowCards,
                              )
                            : 1;
                        final tileHeight = web
                            ? ((narrowCards ? 68 : 78) +
                                      (descriptionLines > 1 ? 18 : 0)) *
                                  MediaQuery.textScalerOf(context).scale(13) /
                                  13
                            : (48 + 24 * spacious) *
                                  MediaQuery.textScalerOf(context)
                                      .scale(13 + 2 * spacious) /
                                  (13 + 2 * spacious);
                        // A larger text size makes every part taller than the thresholds above assume (they are the layout at
                        // 1x): the text is measured and the cards keep their place. The avatar gives way first (it shrinks,
                        // then the hint goes, then the avatar), and if the cards still do not fit the page scrolls, so no
                        // line is cut mid-glyph at the page's edge at rest.
                        final scaler = MediaQuery.textScalerOf(context);
                        final grown = scaler.scale(13) > 13.01;
                        final padLeft =
                                widget.horizontalInset ??
                                (web ? DuoLayout.edgeGap : 16),
                            padRight =
                                widget.rightInset ??
                                widget.horizontalInset ??
                                (web ? DuoLayout.edgeGap : 16);
                        final titleStyle = web
                            ? Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)
                            : Theme.of(context).textTheme.titleLarge;
                        final titleText = web
                            ? timeGreeting(DateTime.now())
                            : '想聊点什么？';
                        final hintText = web
                            ? '有什么想聊的？输入问题，或点击麦克风直接说话。'
                            : '写下想法，或直接开口。';
                        double measured(
                          String text,
                          TextStyle? style,
                          TextScaler textScaler,
                        ) {
                          return _measureText(
                            context,
                            text,
                            style,
                            textScaler,
                            bounds.maxWidth - padLeft - padRight,
                          );
                        }

                        final titleHeight = grown
                            ? measured(titleText, titleStyle, scaler)
                            : 28.0;
                        final hintHeight = grown
                            ? 8 + measured(hintText, null, scaler)
                            : 29.0;
                        // The room is planned for the tallest card any session can draw, so what is shown (and the avatar's
                        // size) does not depend on which four this one picked.
                        final tallestTile = web
                            ? ((narrowCards ? 68 : 78) +
                                      (starterDescriptionLines(
                                                context,
                                                allStarters,
                                                cardWidth,
                                                compact: narrowCards,
                                              ) >
                                              1
                                          ? 18
                                          : 0)) *
                                  scaler.scale(13) /
                                  13
                            : tileHeight;
                        final cardsHeight =
                            24 + tallestTile * 2 + 10 + 2 * spacious;
                        const minAvatar = 88 * .78 + 12;
                        // At 1x each part is either there or not by the window's height. Larger, in this order of priority:
                        // the cards, the avatar at its smallest, the hint, a larger avatar. The avatar only ever shrinks as
                        // the text grows: once the hint has gone it stays at its smallest rather than taking the hint's room.
                        final spare = height - 28 - titleHeight - cardsHeight;
                        final roomy = (spare - hintHeight - 12) / .78;
                        final avatarVisibility = grown
                            ? (spare >= minAvatar ? 1.0 : 0.0)
                            : fits(125);
                        final hintVisibility = grown
                            ? (roomy >= 88 ? 1.0 : 0.0)
                            : fits(122);
                        final starterVisibility = grown
                            ? 1.0
                            : fits(200) * hintVisibility;
                        final avatarSize = grown
                            ? math.max(88.0, math.min(avatarBase, roomy))
                            : avatarBase;
                        final naturalHeight =
                            32 +
                            (avatarSize * .78 + 12) * avatarVisibility +
                            titleHeight +
                            hintHeight * hintVisibility +
                            (24 + tileHeight * 2 + 10 + 2 * spacious) *
                                starterVisibility;
                        // Prefer the upper third; keep the welcome group together as the IME moves.
                        final topGap = math.max(
                          0.0,
                          (height - naturalHeight) * .22,
                        );
                        Widget reveal(double amount, Widget child) =>
                            ExcludeFocus(
                              excluding: amount < .85,
                              child: ExcludeSemantics(
                                excluding: amount < .5,
                                child: IgnorePointer(
                                  ignoring: amount < .85,
                                  child: ClipRect(
                                    child: Align(
                                      heightFactor: amount,
                                      child: Opacity(
                                        opacity: amount,
                                        child: child,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                        return SingleChildScrollView(
                          physics: iosScrollPhysics,
                          keyboardDismissBehavior: iosKeyboardDismiss,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: height),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                // Unfolded: the same column as the composer frame, so the cards line up with it.
                                widget.horizontalInset ??
                                    (web ? DuoLayout.edgeGap : 16),
                                12 + topGap,
                                widget.rightInset ??
                                    widget.horizontalInset ??
                                    (web ? DuoLayout.edgeGap : 16),
                                16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  reveal(
                                    avatarVisibility,
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CoreAvatar(
                                          key: ValueKey(
                                            'empty-reactor-${c.id}',
                                          ),
                                          startupIdentity: c.id,
                                          size: avatarSize,
                                        ),
                                        const SizedBox(height: 12),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    web
                                        ? timeGreeting(DateTime.now())
                                        : '想聊点什么？',
                                    style: web
                                        ? Theme.of(context)
                                              .textTheme
                                              .headlineSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              )
                                        : Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                  ),
                                  reveal(
                                    hintVisibility,
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(height: 8),
                                        Text(
                                          web
                                              ? '有什么想聊的？输入问题，或点击麦克风直接说话。'
                                              : '写下想法，或直接开口。',
                                          textAlign: TextAlign.center,
                                          style: web
                                              ? TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                  reveal(
                                    starterVisibility,
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(height: 24),
                                        LayoutBuilder(
                                          builder: (context, space) {
                                            // Random per app session, one from each of the four groups (same as the web client).
                                            final starters =
                                                widget.controller.starters;
                                            final gap = 10 + 2 * spacious;
                                            final width =
                                                (math.min(space.maxWidth, 620) -
                                                    gap) /
                                                2;
                                            const icons = [
                                              Icons.tips_and_updates_outlined,
                                              Icons.auto_awesome_outlined,
                                              Icons.code,
                                              Icons.checklist,
                                            ];
                                            return Wrap(
                                              spacing: gap,
                                              runSpacing: gap,
                                              alignment: WrapAlignment.center,
                                              children: [
                                                for (
                                                  var i = 0;
                                                  i < starters.length;
                                                  i++
                                                )
                                                  SizedBox(
                                                    width: width,
                                                    height: tileHeight,
                                                    child: web
                                                        ? WebStarterCard(
                                                            key: ValueKey(
                                                              'starter-$i',
                                                            ),
                                                            starter:
                                                                starters[i],
                                                            compact:
                                                                narrowCards,
                                                            descriptionLines:
                                                                descriptionLines,
                                                            onPressed: () =>
                                                                useStarter(
                                                                  starters[i]
                                                                      .prompt,
                                                                ),
                                                          )
                                                        : OutlinedButton(
                                                            key: ValueKey(
                                                              'starter-$i',
                                                            ),
                                                            style: OutlinedButton.styleFrom(
                                                              padding:
                                                                  EdgeInsets.symmetric(
                                                                    horizontal:
                                                                        10 +
                                                                        4 * spacious,
                                                                  ),
                                                              textStyle:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .bodySmall
                                                                      ?.copyWith(
                                                                        fontSize:
                                                                            13 +
                                                                            2 * spacious,
                                                                      ),
                                                              shape: RoundedRectangleBorder(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      Radii
                                                                          .medium,
                                                                    ),
                                                              ),
                                                            ),
                                                            onPressed: () =>
                                                                useStarter(
                                                                  starters[i]
                                                                      .prompt,
                                                                ),
                                                            child: Row(
                                                              children: [
                                                                Icon(
                                                                  icons[i],
                                                                  size:
                                                                      18 +
                                                                      2 * spacious,
                                                                ),
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                Expanded(
                                                                  child: Text(
                                                                    starters[i]
                                                                        .title,
                                                                    maxLines: 2,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                  ),
                                              ],
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    Widget buildList() {
      scroll.followLatest();
      final foldable = DuoLayoutScope.of(context).isFoldable;
      final generating = widget.controller.isGenerating(c.id);
      final fontSize = widget.controller.settings.messageFontSize;
      // Found once for the whole list: the last visible reply is the one that offers "regenerate".
      String? lastReply;
      for (var i = c.messages.length - 1; i >= 0 && lastReply == null; i--) {
        final m = c.messages[i];
        if (m.role == 'assistant' && !m.hidden) lastReply = m.id;
      }
      final fade = Theme.of(context).scaffoldBackgroundColor;
      // Content melts into the edges instead of being cut off by a hard line under the header and above the composer.
      Widget edge({required bool top}) => Positioned(
        top: top ? 0 : null,
        bottom: top ? null : 0,
        left: 0,
        right: 0,
        height: 18,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: [fade, fade.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
      );
      Widget messageList(EdgeInsets horizontal, double column) {
        // Your messages (and the media cards) take up to 88% of the message column, whatever the screen is.
        final userWidth = math.min(640.0, column * .88);
        return Stack(
          children: [
            Positioned.fill(
              child: scroll.wrap(
                ListView.builder(
                  key: PageStorageKey('messages-${c.id}'),
                  controller: scroll,
                  physics: iosScrollPhysics,
                  keyboardDismissBehavior: iosKeyboardDismiss,
                  // Foldable: the message column is centred like the composer (same edge gap on both sides) and narrowed by
                  // DuoLayout.replyWidthFactor, equally on both sides, for your messages and the model's alike.
                  padding: horizontal.copyWith(top: 16, bottom: 16),
                  itemCount: c.messages.length,
                  itemBuilder: (context, i) {
                    final m = c.messages[i];
                    return _Entrance(
                      key: ValueKey('enter-${m.id}'),
                      animate: _fresh.contains(m.id),
                      child: m.taskId != null && !m.hidden
                          ? _taskCard(c, m, userWidth)
                          : _Memo(
                              // Everything the row shows; while one reply streams, the finished ones stay as they are.
                              revision: (
                                m.text,
                                m.reasoning,
                                m.status,
                                m.error,
                                m.hidden,
                                m.attachments.length,
                                m.calls.length,
                                lastReply == m.id,
                                generating,
                                fontSize,
                                foldable,
                                userWidth,
                                widget.onContinue != null,
                              ),
                              // A long reply that is still streaming is laid out less often (see _Memo.throttle).
                              throttle: generating && m.status == 'generating'
                                  ? streamingInterval(m.text.length)
                                  : Duration.zero,
                              builder: (context) => _message(
                                context,
                                c,
                                m,
                                userWidth: userWidth,
                                lastReply: lastReply == m.id,
                                generating: generating,
                                foldable: foldable,
                              ),
                            ),
                    );
                  },
                ),
              ),
            ),
            edge(top: true),
            edge(top: false),
            Positioned(
              right: 12,
              bottom: 8,
              child: ListenableBuilder(
                listenable: Listenable.merge([scroll.away, scroll.far]),
                builder: (context, _) {
                  // While a reply is written, any step away from the tail offers the way back; at rest only a long way.
                  final visible = generating
                      ? scroll.away.value
                      : scroll.far.value;
                  void jump() {
                    tapFeedback();
                    unawaited(scroll.animateToTail(context));
                  }

                  return AnimatedSwitcher(
                    duration: motion(context, 180),
                    transitionBuilder: popTransition,
                    child: !visible
                        ? const SizedBox.shrink(key: ValueKey('no-jump'))
                        : Tooltip(
                            key: const ValueKey('jump'),
                            message: '回到底部',
                            child: Semantics(
                              button: true,
                              label: '回到底部',
                              excludeSemantics: true,
                              onTap: jump,
                              child: Material(
                                key: const Key('jump-to-latest'),
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHigh,
                                elevation: 3,
                                shape: CircleBorder(
                                  side: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant,
                                  ),
                                ),
                                child: InkResponse(
                                  onTap: jump,
                                  customBorder: const CircleBorder(),
                                  child: const SizedBox.square(
                                    dimension: 44,
                                    child: Icon(Icons.arrow_downward, size: 20),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
        );
      }

      return LayoutBuilder(
        builder: (context, bounds) {
          final horizontal = foldable
              ? messageInset(bounds.maxWidth)
              : EdgeInsets.fromLTRB(
                  widget.horizontalInset ?? 18,
                  0,
                  widget.rightInset ?? widget.horizontalInset ?? 18,
                  0,
                );
          return messageList(
            horizontal,
            math.max(0.0, bounds.maxWidth - horizontal.horizontal),
          );
        },
      );
    }

    final empty = c.messages.isEmpty;
    // The welcome page and the list trade places: the one leaving fades out in 120 ms (its last 60 % of the swap), the
    // welcome page arriving fades in; the list needs no fade of its own, each new message carries its entrance (a
    // second fade on top of it left the page blank for a moment). A page opened afresh (conversation switch, new chat)
    // fades in as a whole, which is all that can be done for it: it is a new state, there is no old panel left to fade.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: _animateIn ? 0 : 1, end: 1),
      duration: motion(context, 200),
      curve: Curves.easeOut,
      builder: (_, value, child) => Opacity(opacity: value, child: child),
      child: AnimatedSwitcher(
        duration: motion(context, 200),
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.expand, children: [...previous, ?current]),
        transitionBuilder: (child, animation) => AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final leaving = animation.status == AnimationStatus.reverse;
            final opacity = leaving
                ? ((animation.value - .4) / .6).clamp(0.0, 1.0)
                : child!.key == const ValueKey('chat-list')
                ? 1.0
                : animation.value;
            return IgnorePointer(
              ignoring: leaving,
              child: Opacity(opacity: opacity, child: child),
            );
          },
        ),
        child: KeyedSubtree(
          key: ValueKey(empty ? 'chat-welcome' : 'chat-list'),
          child: empty ? buildWelcome() : buildList(),
        ),
      ),
    );
  }

  /// An image or video task in the message list.
  Widget _taskCard(Conversation c, ChatMessage m, double maxWidth) {
    final task = c.tasks.where((t) => t.id == m.taskId).firstOrNull;
    return task == null
        ? const SizedBox.shrink()
        : Padding(
            key: ValueKey(task.id),
            padding: const EdgeInsets.only(bottom: 2),
            // Same width cap as your own messages, so image and video cards line up with them.
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: MediaCard(
                  key: ValueKey('card-${task.id}'),
                  task: task,
                  controller: widget.controller,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  onCancel: widget.onCancelTask == null
                      ? null
                      : () => widget.onCancelTask!(task),
                  openSettings: widget.openSettings,
                ),
              ),
            ),
          );
  }

  /// The reply's Markdown inside one [SelectionArea], so a selection can run across its paragraphs, lists and tables
  /// (selectable text per block cannot). Right-to-left replies lay out right to left.
  Widget _replyText(BuildContext context, ChatMessage m, double fontSize) {
    final body = SelectionArea(
      child: MarkdownBody(
        styleSheet: chatMarkdownStyle(context, fontSize),
        builders: chatMarkdownBuilders(fontSize),
        data: m.text,
        onTapLink: (text, href, title) {
          final uri = Uri.tryParse(href ?? '');
          if (uri != null && _linkSchemes.contains(uri.scheme)) {
            unawaited(openLink(context, uri));
          }
        },
        imageBuilder: (uri, title, alt) {
          final resolved = widget.controller.api.endpoint.resolveUri(uri);
          if (!['http', 'https'].contains(resolved.scheme) ||
              !resolved.hasAuthority ||
              resolved.host.isEmpty) {
            return const Text('图片地址不可用');
          }
          if (resolved.origin != widget.controller.api.endpoint.origin) {
            return TextButton(
              onPressed: () => unawaited(openLink(context, resolved)),
              child: Text(alt ?? '打开图片'),
            );
          }
          void open() => unawaited(
            openMediaPreview(
              context,
              controller: widget.controller,
              kind: 'image',
              url: resolved.toString(),
              prompt: alt ?? '',
            ),
          );
          return Semantics(
            button: true,
            onTap: open,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: AuthenticatedImage(
                controller: widget.controller,
                url: resolved.toString(),
                semanticLabel: alt,
              ),
            ),
          );
        },
      ),
    );
    return textDirectionOf(m.text) == TextDirection.rtl
        ? Directionality(
            textDirection: TextDirection.rtl,
            child: SizedBox(width: double.infinity, child: body),
          )
        : body;
  }

  Widget _message(
    BuildContext context,
    Conversation c,
    ChatMessage m, {
    required double userWidth,
    required bool lastReply,
    required bool generating,
    required bool foldable,
  }) {
    final user = m.role == 'user';
    final colors = Theme.of(context).colorScheme;
    final fontSize = widget.controller.settings.messageFontSize;
    if (m.hidden) return const SizedBox.shrink();
    if (m.role == 'assistant' &&
        m.text.isEmpty &&
        m.calls.isNotEmpty &&
        m.error == null) {
      // Level with the reply text above it: no indent, small and grey, with a spinner.
      return generating
          ? const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 20),
              child: _StatusLine('正在调用工具…'),
            )
          : const SizedBox.shrink();
    }
    return PageStorage(
      key: ValueKey('message-${c.id}-${m.id}'),
      bucket: _contentStorage,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Semantics(
            container: true,
            label: user ? '你' : 'JARVIS',
            child: Container(
              key: ValueKey('bubble-${c.id}-${m.id}'),
              constraints: BoxConstraints(maxWidth: user ? userWidth : 760),
              padding: user
                  ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
                  : const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: user ? colors.surfaceContainerHigh : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.large),
                // Increase Contrast: the bubble gets an edge instead of a faint tint.
                border: user && MediaQuery.highContrastOf(context)
                    ? Border.all(color: colors.outline)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (m.reasoning.isNotEmpty)
                    ExpansionTile(
                      key: PageStorageKey('reasoning-${c.id}-${m.id}'),
                      dense: true,
                      minTileHeight: 48,
                      tilePadding: EdgeInsets.zero,
                      // No rules above and below: the header sits in the reply like a line of its own.
                      shape: const Border(),
                      collapsedShape: const Border(),
                      // Opening it at the tail would otherwise follow the new bottom and scroll its start away.
                      onExpansionChanged: (open) {
                        if (open) scroll.stopFollowing();
                      },
                      title: m.status == 'generating' && m.text.isEmpty
                          ? const _StatusLine('思考中…')
                          : Text(
                              '思考过程',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                      children: [
                        // Set apart from the answer: smaller, muted and behind a rule.
                        Container(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.only(left: 12),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: colors.outlineVariant,
                                width: 2,
                              ),
                            ),
                          ),
                          child: SelectableText(
                            m.reasoning,
                            style: TextStyle(
                              fontSize: fontSize - 1.5,
                              height: 1.6,
                              color: colors.onSurfaceVariant,
                            ),
                            key: PageStorageKey(
                              'reasoning-text-${c.id}-${m.id}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (m.attachments.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final a in m.attachments)
                          AttachmentCard(
                            key: ValueKey(a.id),
                            controller: widget.controller,
                            item: a,
                            preview: true,
                          ),
                      ],
                    ),
                  if (user && m.text.isNotEmpty) ...[
                    // Attachments above the text: a little air between them.
                    if (m.attachments.isNotEmpty) const SizedBox(height: 8),
                    SelectableText(
                      m.text,
                      // Hebrew and Arabic run right to left; everything else (Chinese, Latin) as before.
                      textDirection: textDirectionOf(m.text),
                      style: TextStyle(fontSize: fontSize, height: 1.6),
                    ),
                  ] else if (!user)
                    m.text.isEmpty && m.status == 'generating'
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: _StatusLine('正在思考…'),
                          )
                        : _replyText(context, m, fontSize),
                  // The reply's status note (stopped, failed, cut at the length limit) comes right after its text,
                  // above the copy / regenerate row.
                  if (m.status == 'interrupted')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          // The user's own stop carries no error: a neutral note, not a failure.
                          Icon(
                            m.error == null
                                ? Icons.stop_circle_outlined
                                : Icons.error_outline,
                            size: 16,
                            color: m.error == null
                                ? colors.onSurfaceVariant
                                : colors.error,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              m.error ?? '已停止',
                              style: TextStyle(
                                fontSize: 12,
                                color: m.error == null
                                    ? colors.onSurfaceVariant
                                    : colors.error,
                              ),
                            ),
                          ),
                          if (lastReply && !generating)
                            TextButton(
                              onPressed: widget.controller.regenerate,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                              child: const Text('重试'),
                            ),
                        ],
                      ),
                    ),
                  if (m.status == 'length')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const Flexible(
                            child: Text(
                              '已达到输出长度上限',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          if (widget.onContinue != null &&
                              lastReply &&
                              !generating)
                            TextButton(
                              key: const Key('continue-reply'),
                              onPressed: widget.onContinue,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                              child: const Text('继续生成'),
                            ),
                        ],
                      ),
                    ),
                  // Copy and regenerate wait until the reply is written, then ease in (icons at the left of 44pt tap
                  // areas, close to the text and each other).
                  if (!user && m.text.isNotEmpty)
                    SmoothSize(
                      milliseconds: 180,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: motion(context, 180),
                        layoutBuilder: overlayOutgoing(),
                        child: m.status == 'generating'
                            ? const SizedBox(
                                key: ValueKey('reply-actions-hidden'),
                                width: double.infinity,
                              )
                            : Row(
                                key: const ValueKey('reply-actions'),
                                children: [
                                  CopyFeedback(
                                    text: m.text,
                                    builder: (context, copied, copy) =>
                                        HuggingIconButton(
                                          tooltip: copied ? '已复制' : '复制回复',
                                          icon: copied
                                              ? Icons.check_rounded
                                              : Icons.copy_outlined,
                                          onPressed: copy,
                                        ),
                                  ),
                                  // An interrupted reply already offers "重试" beside its note: one retry, not two.
                                  if (lastReply &&
                                      !generating &&
                                      m.status != 'interrupted')
                                    HuggingIconButton(
                                      tooltip: '重新生成',
                                      icon: Icons.refresh,
                                      iconSize: 18,
                                      onPressed: widget.controller.regenerate,
                                    ),
                                ],
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small grey line with a ring in front: "thinking", "calling a tool". Level with the reply text, no indent.
class _StatusLine extends StatelessWidget {
  const _StatusLine(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox.square(
        dimension: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5),
      ),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    ],
  );
}

/// How often a reply that is [length] characters long and still streaming is parsed and laid out again. Every delta
/// re-parses the whole reply, so the cost grows with its length: normal replies follow each delta (the controller already
/// batches those to ~30 per second), long ones about ten times a second, very long ones fewer.
@visibleForTesting
Duration streamingInterval(int length) => length > 12000
    ? const Duration(milliseconds: 200)
    : length > 4000
    ? const Duration(milliseconds: 100)
    : Duration.zero;

/// Rebuilds [builder] only when [revision] changes: finished messages sit still while the one that streams repaints.
/// What the row reads from its surroundings (theme, scale) still refreshes it through its own dependencies. With a
/// [throttle], a change arriving within that interval of the last rebuild waits for the interval to end (the latest
/// revision wins); one that arrives with no throttle (the reply has finished) is shown at once.
class _Memo extends StatefulWidget {
  const _Memo({
    required this.revision,
    required this.builder,
    this.throttle = Duration.zero,
  });
  final Object revision;
  final WidgetBuilder builder;
  final Duration throttle;
  @override
  State<_Memo> createState() => _MemoState();
}

class _MemoState extends State<_Memo> {
  Object? _revision;
  Widget? _child;
  Timer? _cooldown;

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_child == null || _revision != widget.revision) {
      // Too soon after the last layout: keep showing it; the cooldown's end builds again with the latest revision.
      if (_child != null &&
          _cooldown != null &&
          widget.throttle > Duration.zero) {
        return _child!;
      }
      _cooldown?.cancel();
      _cooldown = null;
      _revision = widget.revision;
      _child = Builder(builder: widget.builder);
      if (widget.throttle > Duration.zero) {
        _cooldown = Timer(widget.throttle, () {
          _cooldown = null;
          if (mounted) setState(() {});
        });
      }
    }
    return _child!;
  }
}

/// [child] with an accessibility [hint] merged into it (the reason a disabled button is disabled); as is without one.
class _Hinted extends StatelessWidget {
  const _Hinted({required this.hint, required this.child});
  final String? hint;
  final Widget child;
  @override
  Widget build(BuildContext context) => hint == null
      ? child
      : MergeSemantics(
          child: Semantics(hint: hint, child: child),
        );
}

/// A message that has just arrived slides up a few points while it fades in; history never animates.
class _Entrance extends StatefulWidget {
  const _Entrance({super.key, required this.animate, required this.child});
  final bool animate;
  final Widget child;
  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || !widget.animate) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      unawaited(_controller.forward());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: AnimatedBuilder(
      animation: _curve,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, 14 * (1 - _curve.value)),
        child: child,
      ),
      child: widget.child,
    ),
  );
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    this.keyboardVisible = false,
    this.keyboardInset = 0,
    this.edgeGap,
    this.leftGap,
    this.rightGap,
    this.bottomGap,
    this.maxFieldHeight,
    this.focusNode,
    this.openSettings,
    this.noticeContext,
  });
  final JarvisController controller;

  /// See [JarvisHome.openSettings]: the microphone's and the camera's "去设置".
  final Future<void> Function()? openSettings;

  /// A context that outlives this composer (it is keyed per conversation and unmounts on a switch) for a notice about
  /// an attachment that failed while the user was elsewhere; null when there is none.
  final BuildContext? Function()? noticeContext;
  final bool keyboardVisible;
  final double keyboardInset;
  final FocusNode? focusNode;

  /// Equal left/right/bottom spacing (foldable iPhone); null keeps the default.
  final double? edgeGap;

  /// Spacing at the left and right of the frame when it differs from [edgeGap] (half-folded: little on the crease side,
  /// more at the screen edge).
  final double? leftGap, rightGap;

  /// Spacing below the frame; the foldable default is [edgeGap]. Half-folded only the sides shrink, so the composer
  /// keeps the height it has unfolded. It follows the keyboard: tight above it, the home indicator's room below.
  final double? bottomGap;

  /// The tallest the text field may grow before it scrolls; null derives it from the window alone.
  final double? maxFieldHeight;
  @override
  State<Composer> createState() => _ComposerState();
}

const _effortNames = {'none': '关闭', 'low': '低', 'medium': '中', 'high': '高'};

/// What the user is told when there is a draft but sending is not possible, or null when it is (or nothing is written).
String? sendBlockedReason(JarvisController c, bool hasDraft) {
  if (!hasDraft || c.isGenerating(c.current.id)) return null;
  if (!c.authenticated || c.model.isEmpty) return '模型未连接，暂时无法发送';
  if (c.attachmentsLoading(c.current.id)) return '附件处理中，稍后即可发送';
  return null;
}

/// The message for an attachment that could not be added. The app's own rules and the native image bridge (a
/// [PlatformException], whose message names the real reason: too large, still over 3 MB after compressing) have
/// readable Chinese messages; anything else would show up as "Exception: ...".
String attachmentErrorText(Object error) {
  if (error is JarvisException) return error.message;
  if (error is PlatformException) {
    final message = error.message ?? '';
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(message)) return message;
    final code = error.code.toLowerCase();
    if (code.contains('large') || code.contains('size')) {
      return '图片尺寸过大，请换一张较小的图片';
    }
    if (code.contains('compress') || code.contains('3mb')) {
      return '图片压缩后仍超过 3MB，请换一张较小的图片';
    }
    if (code.contains('invalid') || code.contains('decode')) {
      return '图片无法读取';
    }
  }
  return '添加附件失败，请重试';
}

class _ComposerState extends State<Composer> {
  Future<void> attach(Future<void> Function(JarvisController) choose) async {
    final home = widget.noticeContext;
    try {
      await choose(widget.controller);
    } catch (e) {
      // Picking and compressing take a while: if the conversation was switched meanwhile this composer is gone, and the
      // notice goes through the page's own context instead of being dropped.
      final target = mounted ? context : home?.call();
      if (target == null || !target.mounted) return;
      // A refusal is final until the user changes it in Settings: offer the way there, and keep the notice long enough
      // to reach it (VoiceOver reads it first).
      final opener = widget.openSettings ?? defaultSettingsOpener;
      final denied =
          e is PlatformException &&
          (e.code == 'camera_denied' || e.code == 'photos_denied') &&
          opener != null;
      showNotice(
        target,
        attachmentErrorText(e),
        action: denied
            ? SnackBarAction(
                label: '去设置',
                onPressed: () => unawaited(opener.call().catchError((_) {})),
              )
            : null,
        duration: Duration(seconds: denied ? 7 : 3),
      );
    }
  }

  late final TextEditingController text = TextEditingController(
    text: widget.controller.current.draft,
  );
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(sync);
  }

  void sync() {
    final value = widget.controller.current.draft;
    if (value != text.text) {
      text.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(sync);
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Short landscape windows (a phone on its side, the outer display of a foldable): one row holds the buttons and the
    // field instead of a field with a row of buttons under it.
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width > screen.height && screen.height < 520;
    // The compact field's height with one line of text: its padding around a line that grows with the text size. The
    // buttons beside it take this height and centre in it, so they stay level with the first (or only) line at any size.
    var rowHeight = 48.0;
    if (compact) {
      final line = TextPainter(
        text: TextSpan(text: '发', style: Theme.of(context).textTheme.bodyLarge),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: TextDirection.ltr,
      )..layout();
      rowHeight = math.max(48, line.height + 24);
      line.dispose();
    }
    final Widget field = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            widget.maxFieldHeight ??
            math.max(
              48,
              math.min(
                160,
                MediaQuery.sizeOf(context).height -
                    widget.keyboardInset -
                    // Header and composer chrome; a foldable's are 28pt taller.
                    (widget.edgeGap == null ? 160 : 188),
              ),
            ),
      ),
      child: TextField(
        onTapUpOutside: dismissKeyboardOnTapUpOutside,
        key: const Key('chat-input'),
        controller: text,
        focusNode: widget.focusNode,
        minLines: 1,
        maxLines: 5,
        onChanged: widget.controller.setDraft,
        decoration: InputDecoration(
          hintText: '发送消息…',
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          // Foldable iPhone: the composer is 8pt taller than before (the field's minimum height 48 -> 56).
          constraints: compact
              ? const BoxConstraints(minHeight: 48)
              : widget.edgeGap == null
              ? null
              : const BoxConstraints(minHeight: 56),
          contentPadding: compact
              ? const EdgeInsets.fromLTRB(8, 12, 8, 12)
              : widget.edgeGap == null
              ? const EdgeInsets.fromLTRB(14, 10, 14, 6)
              : const EdgeInsets.fromLTRB(14, 16, 14, 12),
        ),
      ),
    );
    final Widget attachButton = attachesPhotos
        ? JarvisActionMenu(
            tooltip: '添加附件',
            // The trigger is a plain InkWell: this makes VoiceOver read a button.
            semanticLabel: '添加附件',
            actions: const [
              JarvisMenuAction(
                'photos',
                '照片',
                icon: Icons.photo_library_outlined,
              ),
              JarvisMenuAction(
                'camera',
                '拍照',
                icon: Icons.photo_camera_outlined,
              ),
              JarvisMenuAction('files', '文件', icon: Icons.folder_open_outlined),
            ],
            onSelected: (choice) => attach(switch (choice) {
              'photos' => choosePhotos,
              'camera' => takePhotoAttachment,
              _ => chooseAttachments,
            }),
            child: SizedBox(
              width: 48,
              height: rowHeight,
              child: const Icon(Icons.add, size: 22),
            ),
          )
        : _centredInRow(
            compact,
            rowHeight,
            IconButton(
              tooltip: '添加附件',
              icon: const Icon(Icons.add, size: 22),
              onPressed: () => attach(chooseAttachments),
            ),
          );
    final Widget effortMenu = JarvisActionMenu(
      tooltip: '选择思考深度',
      semanticLabel:
          '思考深度，当前${_effortNames[widget.controller.effort] ?? widget.controller.effort}',
      selectedValue: widget.controller.effort,
      onSelected: widget.controller.setEffort,
      actions: const [
        JarvisMenuAction('none', '关闭'),
        JarvisMenuAction('low', '低'),
        JarvisMenuAction('medium', '中'),
        JarvisMenuAction('high', '高'),
      ],
      child: ConstrainedBox(
        // 48 is the floor: the label grows with the text size. Beside the field it is as tall as the field's first line.
        constraints: BoxConstraints(minHeight: rowHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lightbulb_outline, size: 17),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '思考 · ${_effortNames[widget.controller.effort]}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Sharing a row with the field: the same type as its text, so both read on one line.
                  style: compact ? Theme.of(context).textTheme.bodyLarge : null,
                ),
              ),
              const Icon(Icons.expand_more, size: 15),
            ],
          ),
        ),
      ),
    );
    final Widget sendCluster = ValueListenableBuilder<TextEditingValue>(
      valueListenable: text,
      builder: (context, value, _) {
        final c = widget.controller;
        final generating = c.isGenerating(c.current.id);
        final hasDraft =
            value.text.trim().isNotEmpty ||
            c.current.pendingAttachments.isNotEmpty;
        final showSend = hasDraft || generating;
        final canSend =
            c.authenticated &&
            c.model.isNotEmpty &&
            !c.attachmentsLoading(c.current.id) &&
            hasDraft;
        final blocked = sendBlockedReason(c, hasDraft);
        Future<void> voice() async {
          tapFeedback();
          FocusScope.of(context).unfocus();
          if (c.voice.active) {
            c.voice.expand();
            return;
          }
          if (!await ensureAiNotice(context, c)) return;
          if (!context.mounted) return;
          await c.voice.start(c.current);
          if (context.mounted) {
            reportCallFailure(context, c, openSettings: widget.openSettings);
          }
        }

        // The two-row composer nudges its round buttons up-left, towards the frame's corner; the single row centres
        // them on the field's line like the + button.
        final lift = compact ? Offset.zero : const Offset(-2, -2);
        return SmoothSize(
          milliseconds: 180,
          alignment: Alignment.centerRight,
          // The side mic shrinks away whole as it fades, instead of being cut off from the left.
          clipBehavior: Clip.none,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The side mic button grows in when the send button appears, and shrinks away when it goes.
              AnimatedSwitcher(
                duration: motion(context, 180),
                transitionBuilder: popTransition,
                layoutBuilder: overlayOutgoing(Alignment.centerRight),
                child: !showSend
                    ? const SizedBox.shrink(key: ValueKey('no-mic'))
                    : Transform.translate(
                        key: const ValueKey('side-mic'),
                        offset: lift,
                        transformHitTests: false,
                        child: IconButton(
                          tooltip: '语音对话',
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                            shape: const CircleBorder(),
                            fixedSize: const Size(36, 36),
                            minimumSize: const Size(36, 36),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                          onPressed: voice,
                          icon: const Icon(Icons.mic_none_rounded, size: 20),
                        ),
                      ),
              ),
              TweenAnimationBuilder<Offset>(
                tween: Tween<Offset>(end: showSend ? Offset.zero : lift),
                duration: motion(context, 180),
                curve: Curves.easeOutCubic,
                builder: (context, offset, child) => Transform.translate(
                  offset: offset,
                  transformHitTests: false,
                  child: child,
                ),
                // Disabled for a reason that the visible note under the field also gives.
                child: _Hinted(
                  hint: blocked,
                  child: IconButton.filled(
                    // One 36pt circle (in a 48pt touch target) on every phone, the foldable and landscape, from the mic
                    // to the send button (and the mic beside it): the button must not jump when the first character is
                    // typed, nor fill the single-row composer.
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      fixedSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.padded,
                      backgroundColor: showSend
                          ? null
                          : Theme.of(context).colorScheme.surfaceContainerHigh,
                      shape: showSend ? null : const CircleBorder(),
                    ),
                    tooltip: showSend ? (generating ? '停止当前回复' : '发送') : '语音对话',
                    onPressed: !showSend
                        ? voice
                        : generating
                        ? () {
                            tapFeedback(strong: true);
                            c.cancel(c.current.id);
                          }
                        : canSend
                        ? () {
                            tapFeedback();
                            unawaited(
                              ensureAiNotice(
                                context,
                                c,
                              ).then((ok) => ok ? c.send() : null),
                            );
                          }
                        : null,
                    icon: AnimatedSwitcher(
                      duration: motion(context, 150),
                      transitionBuilder: popTransition,
                      child: KeyedSubtree(
                        key: ValueKey(
                          !showSend ? 'mic' : (generating ? 'stop' : 'send'),
                        ),
                        child: !showSend
                            ? Icon(
                                Icons.mic_none_rounded,
                                size: 20,
                                color: Theme.of(context).colorScheme.onSurface,
                              )
                            : Icon(
                                showSend
                                    ? (generating
                                          ? Icons.stop_rounded
                                          : Icons.arrow_upward)
                                    : Icons.graphic_eq,
                                size:
                                    !showSend &&
                                        MediaQuery.sizeOf(context).height >=
                                            MediaQuery.sizeOf(context).width *
                                                1.9
                                    ? 16
                                    : 20,
                                color: (!showSend || generating || canSend)
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(context).colorScheme.onSurface
                                          .withValues(
                                            alpha: Metrics.disabledOpacity,
                                          ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: widget.bottomGap ?? widget.edgeGap ?? 10),
      // A given gap already follows the keyboard by itself.
      duration: motion(context, widget.bottomGap == null ? 180 : 0),
      curve: Curves.easeOutCubic,
      builder: (context, bottom, child) => Padding(
        // Equal spacing from the usable pane edges, including above the IME.
        padding: widget.edgeGap == null
            ? const EdgeInsets.fromLTRB(10, 4, 10, 10)
            : EdgeInsets.fromLTRB(
                widget.leftGap ?? widget.edgeGap!,
                4,
                widget.rightGap ?? widget.edgeGap!,
                bottom,
              ),
        child: child,
      ),
      child: Container(
        key: const Key('composer-frame'),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border.all(
            // Increase Contrast: the full-strength edge.
            color: MediaQuery.highContrastOf(context)
                ? Theme.of(context).colorScheme.outline
                : Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(Radii.sheet),
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Attachments and the loading bar grow in and out instead of making the composer jump.
            SmoothSize(
              alignment: Alignment.topCenter,
              child: Column(
                children: [
                  if (widget.controller.current.pendingAttachments.isNotEmpty)
                    SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: iosScrollPhysics,
                        itemCount:
                            widget.controller.current.pendingAttachments.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (context, i) {
                          final a =
                              widget.controller.current.pendingAttachments[i];
                          return AttachmentCard(
                            key: ValueKey(a.id),
                            controller: widget.controller,
                            item: a,
                            removable: true,
                          );
                        },
                      ),
                    ),
                  if (widget.controller.attachmentsLoading(
                    widget.controller.current.id,
                  ))
                    const Padding(
                      padding: EdgeInsets.all(6),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
            if (!compact) field,
            // Why the send button is dead, once there is something to send.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: text,
              builder: (context, value, _) {
                final c = widget.controller;
                final reason = sendBlockedReason(
                  c,
                  value.text.trim().isNotEmpty ||
                      c.current.pendingAttachments.isNotEmpty,
                );
                return SmoothSize(
                  alignment: Alignment.topCenter,
                  child: reason == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              reason,
                              key: const Key('send-blocked'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ),
                );
              },
            ),
            // Taps on the buttons are part of the field: send, attach and the effort menu keep the keyboard up.
            TextFieldTapRegion(
              child: Row(
                // A growing field keeps the buttons on its last line.
                crossAxisAlignment: compact
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.center,
                children: [
                  attachButton,
                  if (compact) ...[
                    effortMenu,
                    const SizedBox(width: 6),
                    Expanded(child: field),
                  ] else
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: effortMenu,
                      ),
                    ),
                  _centredInRow(compact, rowHeight, sendCluster),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// [child] centred in a [height]-tall slot of the compact row; untouched elsewhere.
  Widget _centredInRow(bool compact, double height, Widget child) => compact
      ? SizedBox(
          height: height,
          child: Center(child: child),
        )
      : child;
}

/// A compact notice at the bottom of the conversation list (deleted + undo).
class _SidebarNotice extends StatelessWidget {
  const _SidebarNotice({
    super.key,
    required this.text,
    this.label = '撤销',
    this.onAction,
  });
  final String text;

  /// The button's text and what it does (undo a deletion, end a task); none without an action.
  final String label;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.only(left: 14, right: 4),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.medium),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(text, style: const TextStyle(fontSize: 14)),
                ),
              ),
              if (onAction != null)
                TextButton(onPressed: onAction, child: Text(label)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inner width of a [WebStarterCard] of [cardWidth], after its padding.
double starterTextWidth(double cardWidth, {required bool compact}) =>
    cardWidth - (compact ? 16 + 8 : 36);

/// Every starter a session can pick: the welcome page sizes its room for the tallest of them, so what fits does not
/// depend on the (random) cards this session drew.
final allStarters = [for (final group in starterGroups) ...group];

/// 1 when every description fits on one line in cards [cardWidth] wide, else 2: a narrow card (the half-folded
/// column, the outer display) gets a taller tile instead of an ellipsis.
int starterDescriptionLines(
  BuildContext context,
  List<Starter> starters,
  double cardWidth, {
  required bool compact,
}) {
  final width = starterTextWidth(cardWidth, compact: compact);
  for (final starter in starters) {
    final overflows = _layoutText(
      starter.description ?? '',
      TextStyle(fontSize: compact ? 12 : 13, letterSpacing: 0),
      Directionality.of(context),
      MediaQuery.textScalerOf(context),
      width,
      1,
    ).cut;
    if (overflows) return 2;
  }
  return 1;
}

/// A welcome card as on the web client: bold title with a short description underneath.
class WebStarterCard extends StatelessWidget {
  const WebStarterCard({
    super.key,
    required this.starter,
    required this.onPressed,
    this.compact = false,
    this.descriptionLines = 1,
  });
  final Starter starter;
  final VoidCallback onPressed;

  /// Narrow cards (outer display, ~172pt): smaller type so the title and description each stay on one line.
  final bool compact;

  /// How many lines the description may take (the tile is made tall enough for them by whoever sizes it).
  final int descriptionLines;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.large),
        // Increase Contrast: the full-strength edge.
        side: BorderSide(
          color: MediaQuery.highContrastOf(context)
              ? colors.outline
              : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          // Titles line up across a row even when one description wraps to two lines.
          padding: compact
              // Left-aligned but at ease: 16 on the left, 8 on the right.
              ? const EdgeInsets.fromLTRB(16, 15, 8, 10)
              : const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                starter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 14 : 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              LayoutBuilder(
                builder: (context, box) {
                  final text = starter.description ?? '';
                  final maxLines = math.max(descriptionLines, compact ? 1 : 2);
                  final style = TextStyle(
                    fontSize: compact ? 12 : 13,
                    letterSpacing: 0, // the inherited 0.25 would push a long description onto another line
                    color: colors.onSurfaceVariant,
                  );
                  // A wrapped description never leaves one character alone on its last line ("表达更清 / 楚"): the text
                  // is narrowed by a character at a time (measured), so the line above hands its last one down.
                  final merged = DefaultTextStyle.of(context).style
                      .merge(style);
                  final scaler = MediaQuery.textScalerOf(context);
                  var width = box.maxWidth;
                  for (var i = 0; i < 3 && width.isFinite; i++) {
                    final now = _layoutText(
                      text,
                      merged,
                      Directionality.of(context),
                      scaler,
                      width,
                      maxLines,
                    );
                    if (!now.alone) break;
                    final narrower =
                        width - scaler.scale(merged.fontSize ?? 14);
                    if (_layoutText(
                      text,
                      merged,
                      Directionality.of(context),
                      scaler,
                      narrower,
                      maxLines,
                    ).cut) {
                      break;
                    }
                    width = narrower;
                  }
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width),
                    child: Text(
                      text,
                      maxLines: maxLines,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'markdown_style.dart';
import 'completed_works.dart';
import 'scroll_affordance.dart';
import 'attachment_manager.dart';
import 'action_menu.dart';
import 'reply_action_button.dart';
import 'message_parts.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/attachments.dart';
import 'media_widgets.dart';
import 'login_art.dart';
import 'startup_scene.dart';
import 'call_controls.dart';
import 'settings_page.dart';
import 'status_page.dart';
import 'voice_page.dart';
import 'follow_scroll.dart';
import 'sidebar_split.dart';
import 'sidebar_list.dart';

import '../model/adaptive_layout.dart';
import '../model/device_kind.dart';
import '../model/fold_proportions.dart';
import '../model/fold_state.dart';
import '../model/conversation.dart';
import '../model/starters.dart';
import '../state/jarvis_controller.dart';

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
    final success = await widget.controller.login(username.text, password.text);
    if (success && mounted) {
      password.clear();
      TextInput.finishAutofillContext();
    }
  }

  Widget form(
    BuildContext context, {
    required bool compact,
    bool tight = false,
    bool preserveFieldSize = false,
    double? compactProgress,
  }) {
    final colors = Theme.of(context).colorScheme;
    InputDecoration field(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20),
      filled: true,
      fillColor: colors.brightness == Brightness.dark
          ? const Color(0xff18181b)
          : Colors.white.withValues(alpha: .86),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colors.primary.withValues(alpha: .12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colors.primary.withValues(alpha: .12)),
      ),
      isDense: tight && !preserveFieldSize,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 18,
        vertical: tight && !preserveFieldSize ? 12 : 16,
      ),
    );
    final progress = compactProgress ?? (tight ? 1.0 : 0.0);
    Widget collapse(Widget child) => compactProgress == null
        ? child
        : ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: 1 - progress,
              child: Opacity(opacity: 1 - progress, child: child),
            ),
          );
    return SizedBox(
      key: formKey,
      width: 400,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!tight || compactProgress != null)
              collapse(
                Text(
                  '登录',
                  style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                    fontSize: compact ? 26 : 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (!tight ||
                widget.controller.error != null ||
                compactProgress != null)
              widget.controller.error != null
                  ? Padding(
                      padding: EdgeInsets.only(top: 8 * (1 - progress)),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          widget.controller.error!,
                          key: const ValueKey('login-subtitle'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.error),
                        ),
                      ),
                    )
                  : collapse(
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '从这里，继续你的探索。',
                          key: const ValueKey('login-subtitle'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ),
            SizedBox(
              height: compactProgress == null
                  ? (tight
                        ? (widget.controller.error != null ? 8 : 0)
                        : compact
                        ? 18
                        : 26)
                  : (compact ? 18.0 : 26.0) * (1 - progress) +
                        (widget.controller.error != null ? 8 : 0) * progress,
            ),
            TextField(
              controller: username,
              enabled: !widget.controller.connecting,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              decoration: field('账户', Icons.person_outline),
            ),
            SizedBox(
              height: compactProgress == null
                  ? (tight ? 8 : 14)
                  : 14 - 6 * progress,
            ),
            TextField(
              controller: password,
              enabled: !widget.controller.connecting,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: obscure,
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
            SizedBox(
              height: compactProgress == null
                  ? (tight ? 12 : 20)
                  : 20 - 8 * progress,
            ),
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
                    minimumSize: Size(
                      48,
                      tight && !preserveFieldSize ? 48 : 54,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  child: widget.controller.connecting
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('正在登录…'),
                          ],
                        )
                      : const Text('登录'),
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
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: keyboardInset),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          builder: (context, inset, _) => Padding(
            padding: EdgeInsets.only(bottom: math.max(inset, stableBottom)),
            child: SafeArea(
              bottom: false,
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
                  final shortWindow =
                      bounds.maxWidth < 760 &&
                      (fullHeight < 660 || bounds.maxWidth >= 600);
                  final tight =
                      keyboardBlend > .5 &&
                      (shortWindow || bounds.maxHeight < 400);
                  final compact = shortWindow || fullHeight < 520;
                  final wide = bounds.maxWidth >= 760 && fullHeight >= 520;
                  final closedTopGap = (fullHeight * .05).clamp(12.0, 44.0);
                  final topGap = shortWindow
                      ? (tight ? 0.0 : 8.0)
                      : closedTopGap + (6 - closedTopGap) * keyboardBlend;
                  final closedHero = math.min(
                    (fullHeight * .43).clamp(72.0, 380.0),
                    (fullHeight - 372 - closedTopGap).clamp(56.0, 380.0),
                  );
                  final heroHeight = shortWindow
                      ? (tight
                            ? 0.0
                            : (fullHeight - 460).clamp(
                                48.0,
                                bounds.maxWidth < 600 ? 130.0 : 280.0,
                              ))
                      : math.min(
                          closedHero,
                          (bounds.maxHeight - 360).clamp(56.0, 380.0),
                        );
                  final bottomGap = shortWindow
                      ? (tight ? 0.0 : 8.0)
                      : 12.0 - 4 * keyboardBlend;
                  final topPadding = wide ? 20.0 : 12.0;
                  final foldCover =
                      bounds.maxWidth < 600 &&
                      fullHeight < bounds.maxWidth * 1.9;
                  // Keep the form close to the usable bottom, including above the IME.
                  final bottomPadding = foldCover
                      ? 24.0
                      : 20.0 - 8 * keyboardBlend;
                  // Expanded portrait is a single-column layout too. Anchor its
                  // form to the usable bottom rather than collapsing the hero
                  // and leaving the form at the top when the IME appears.
                  final foldPortrait =
                      bounds.maxWidth >= 600 && fullHeight > bounds.maxWidth;
                  if (foldCover || foldPortrait) {
                    final scale =
                        MediaQuery.textScalerOf(context).scale(16) / 16;
                    final openMinimum = widget.controller.error == null
                        ? 192.0
                        : 244.0;
                    final minimumHeight =
                        (340 + (openMinimum - 340) * keyboardBlend) * scale;
                    return SingleChildScrollView(
                      // Keep the submit action above the IME when error text or
                      // larger fonts need more height; earlier content can scroll.
                      reverse: true,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                      child: SizedBox(
                        height: math.max(minimumHeight, bounds.maxHeight - 36),
                        child: Column(
                          children: [
                            ClipRect(
                              child: Align(
                                alignment: Alignment.topCenter,
                                heightFactor: 1 - keyboardBlend,
                                child: Opacity(
                                  opacity: 1 - keyboardBlend,
                                  child: Row(
                                    key: const ValueKey('login-brand-row'),
                                    children: [
                                      const LoginBrandMark(),
                                      const SizedBox(width: 12),
                                      Text(
                                        'JARVIS',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              fontSize: 23,
                                              letterSpacing: .6,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, area) {
                                  return SizedBox(
                                    key: const ValueKey('login-reactor-size'),
                                    width: double.infinity,
                                    child: Opacity(
                                      opacity: (area.maxHeight / 64).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                      child: Transform.translate(
                                        offset: Offset(0, -6 * keyboardBlend),
                                        child: Transform.scale(
                                          scale: 1 + .1 * keyboardBlend,
                                          child: const FractionallySizedBox(
                                            widthFactor: .95,
                                            heightFactor: .95,
                                            child: StartupReactorLanding(),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            form(
                              context,
                              compact: compact,
                              tight: tight,
                              preserveFieldSize: true,
                              compactProgress: keyboardBlend,
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return SingleChildScrollView(
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
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: 960,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!tight)
                                Row(
                                  key: const ValueKey('login-brand-row'),
                                  children: [
                                    const LoginBrandMark(),
                                    const SizedBox(width: 12),
                                    Text(
                                      'JARVIS',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            fontSize: 23,
                                            letterSpacing: .6,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              if (wide) const SizedBox(height: 16),
                              if (wide)
                                Row(
                                  children: [
                                    Expanded(
                                      child: SizedBox(
                                        height: math.min(
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
                                    const SizedBox(width: 32),
                                    Flexible(
                                      child: form(
                                        context,
                                        compact: false,
                                        tight: tight,
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
                                form(
                                  context,
                                  compact: compact,
                                  tight: tight,
                                  preserveFieldSize: foldCover,
                                ),
                              ],
                            ],
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
    );
  }
}

class JarvisHome extends StatefulWidget {
  const JarvisHome({super.key, required this.controller});
  final JarvisController controller;
  @override
  State<JarvisHome> createState() => _JarvisHomeState();
}

class _JarvisHomeState extends State<JarvisHome> {
  ({String text, Conversation? undo})? sidebarNotice;
  Timer? sidebarNoticeTimer;
  bool? showDocked;
  bool drawerOpen = false;
  bool? lastDefault;
  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_frameTimings);
  }

  void _frameTimings(List<FrameTiming> frames) {
    for (final frame in frames) {
      widget.controller.reportStreamBuild(frame.buildDuration);
    }
  }

  final scaffold = GlobalKey<ScaffoldState>();
  final paneBounds = GlobalKey(), composerBounds = GlobalKey();

  /// The call page keeps its state when the hinge bends or flattens (it then
  /// moves under or out from a sub-screen).
  final voiceKey = GlobalKey();

  /// Closes the list when it is a drawer; safe to ask twice (a second tap in
  /// the closing animation must not pop the home page).
  void closeList() {
    final state = scaffold.currentState;
    if (state != null && state.isDrawerOpen) state.closeDrawer();
  }

  void settings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsPage(controller: widget.controller),
    ),
  );
  Future<void> call() async {
    FocusScope.of(context).unfocus();
    final c = widget.controller;
    if (c.voice.active) {
      c.voice.expand();
      return;
    }
    await c.voice.start(c.current);
    if (mounted && c.voice.error != null && !c.voice.active) {
      showNotice(context, c.voice.error!);
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
        final window = MediaQuery.sizeOf(context);
        final innerPortrait =
            window.width >= 600 && window.height > window.width;
        final big = window.width < 600;
        final colors = Theme.of(context).colorScheme;
        // As the iOS rename card: a large rounded card, a 22 title, a roomy
        // rounded field with its count, and two buttons of equal width.
        final dark = colors.brightness == Brightness.dark;
        return AlertDialog(
          key: const Key('rename-dialog'),
          backgroundColor: dark ? const Color(0xff121214) : Colors.white,
          // It scrolls where there is no room for all of it (a short window with
          // the keyboard up).
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(34),
          ),
          insetPadding: big
              ? const EdgeInsets.symmetric(horizontal: 22, vertical: 24)
              : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          constraints: big
              ? const BoxConstraints(minWidth: 280, maxWidth: 560)
              : innerPortrait
              ? const BoxConstraints(minWidth: 360, maxWidth: 420)
              : null,
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          title: Text(
            '重命名会话',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              key: const Key('rename-field'),
              controller: field,
              autofocus: true,
              maxLength: 80,
              style: const TextStyle(fontSize: 18),
              decoration: InputDecoration(
                filled: true,
                fillColor: colors.onSurface.withValues(alpha: dark ? .10 : .06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 22,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (s) {
                if (s.trim().isNotEmpty) Navigator.pop(context, s.trim());
              },
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          actions: [
            SizedBox(
              width: double.infinity,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        shape: const StadiumBorder(),
                        backgroundColor: colors.onSurface.withValues(
                          alpha: dark ? .10 : .06,
                        ),
                        foregroundColor: colors.onSurface,
                        textStyle: const TextStyle(fontSize: 16),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: field,
                      builder: (context, _) => FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          shape: const StadiumBorder(),
                          backgroundColor: colors.onSurface,
                          foregroundColor: colors.surface,
                          disabledBackgroundColor: colors.onSurface.withValues(
                            alpha: .38,
                          ),
                          disabledForegroundColor: colors.surface,
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: field.text.trim().isEmpty
                            ? null
                            : () => Navigator.pop(context, field.text.trim()),
                        child: const Text('保存'),
                      ),
                    ),
                  ),
                ],
              ),
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

  void showSidebarNotice(String text, {Conversation? undo}) {
    sidebarNoticeTimer?.cancel();
    setState(() => sidebarNotice = (text: text, undo: undo));
    sidebarNoticeTimer = Timer(
      Duration(milliseconds: undo == null ? 3000 : 2500),
      () {
        if (mounted) setState(() => sidebarNotice = null);
      },
    );
  }

  @override
  void dispose() {
    sidebarNoticeTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_frameTimings);
    super.dispose();
  }

  void deleteConversation(String id) {
    final removed = widget.controller.deleteConversation(id);
    showSidebarNotice(
      removed == null ? '请先结束此会话的任务或通话，再删除会话' : '会话已删除',
      undo: removed,
    );
  }

  /// The list of conversations: a drawer, docked beside the chat, or a page of
  /// its own (see [ConversationSidebar]).
  Widget sidebar({
    required bool drawer,
    double rightGap = 0,
    bool fullPage = false,
    bool canClose = true,
  }) => ConversationSidebar(
    controller: widget.controller,
    mode: fullPage
        ? SidebarMode.page
        : drawer
        ? SidebarMode.drawer
        : SidebarMode.docked,
    rightGap: rightGap,
    notice: sidebarNotice == null
        ? null
        : _SidebarNotice(
            key: const Key('sidebar-notice'),
            text: sidebarNotice!.text,
            onUndo: sidebarNotice!.undo == null
                ? null
                : () {
                    sidebarNoticeTimer?.cancel();
                    widget.controller.restoreConversation(sidebarNotice!.undo!);
                    setState(() => sidebarNotice = null);
                  },
          ),
    onChoose: () {
      if (drawer) closeList();
    },
    onNew: () {
      widget.controller.newConversation();
      if (drawer) closeList();
    },
    onSettings: () {
      if (drawer) closeList();
      settings();
    },
    onRename: renameConversation,
    onDelete: deleteConversation,
    onClose: fullPage
        ? closeList
        : (!drawer && canClose)
        ? () => setState(() => showDocked = false)
        : null,
  );

  Widget dockedSidebar(
    double width,
    bool visible,
    Duration duration,
    Widget content, {
    double foldGap = 0,
    bool split = false,
  }) => SidebarWidthTransition(
    width: width,
    split: split,
    builder: (context, width) => SidebarSplit(
      width: width,
      visible: visible,
      duration: duration,
      // Half-folded the list has its screen: no grip to fold it away.
      grip: !split,
      onChanged: (value) => setState(() => showDocked = value),
      content: content,
      // The room beside the crease is kept clear of the list's rows.
      child: sidebar(drawer: false, rightGap: foldGap, canClose: !split),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final size = MediaQuery.sizeOf(context),
          padding = MediaQuery.viewPaddingOf(context);
      final fold = FoldState.fromFeatures(
        MediaQuery.displayFeaturesOf(context),
      );
      final layout = AdaptiveLayout.forWindow(
        size.width,
        size.height,
        horizontalInsets: padding.horizontal,
        verticalInsets: padding.vertical,
        fold: fold,
        leftInset: padding.left,
      );
      if (lastDefault != layout.docked) {
        // Keep the person's last choice across rotation and folding. A first
        // landscape still opens by default; portrait remains a closed drawer.
        lastDefault = layout.docked;
        if (layout.docked) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && lastDefault == true) {
              scaffold.currentState?.closeDrawer();
            }
          });
        }
      }
      // Half-folded, the list always has its screen; the person's own choice
      // (showDocked) is kept untouched for when the hinge opens again.
      final docked = layout.docked && (layout.split || (showDocked ?? true));
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      final foldWindow = FoldProportions.isFold(size.width, size.height);
      // Laid out from the columns (a straight phone has its own rules there).
      final columnWindow = FoldProportions.usesColumns(size.width, size.height);
      final paneWidth = math.max(
        0.0,
        size.width - padding.horizontal - (docked ? layout.sidebarWidth : 0),
      );
      final columns = FoldProportions.columns(
        windowWidth: size.width,
        windowHeight: size.height,
        paneWidth: paneWidth,
        dockedMode: layout.docked,
        sidebarOpen: docked,
        keyboardUp: keyboardInset > 0,
      );
      final tallWindow =
          DeviceKind.foldable == null &&
          !foldWindow &&
          size.height >= size.width * 1.9;
      final composerGap = tallWindow
          ? AdaptiveLayout.tallComposerGap(padding.bottom)
          : 10.0;
      // All folding shapes share one pane; the IME never changes its widths.
      Widget centerContent(Widget child) => child;
      final contentEdgeGap = columnWindow ? columns.composerInset : composerGap;
      final navigationInset = math.max(0.0, padding.bottom - keyboardInset);
      final reservedBottom = tallWindow
          ? math.min(composerGap, navigationInset)
          : navigationInset;
      final naturalSidebarWidth = layout.split
          ? AdaptiveLayout.forWindow(
              size.width,
              size.height,
              horizontalInsets: padding.horizontal,
              verticalInsets: padding.vertical,
            ).sidebarWidth
          : layout.sidebarWidth;
      final content = LayoutBuilder(
        builder: (context, actualBounds) {
          final columns = FoldProportions.columns(
            windowWidth: size.width,
            windowHeight: size.height,
            paneWidth: actualBounds.maxWidth,
            dockedMode: layout.docked,
            sidebarOpen: docked,
            keyboardUp: keyboardInset > 0,
            // How far out the list is, against the width it has when the
            // hinge is not bent: while it moves to or from its half-screen
            // width the proportions stay where they are, not jump.
            sidebarProgress: layout.docked
                ? ((size.width - padding.horizontal - actualBounds.maxWidth) /
                          naturalSidebarWidth)
                      .clamp(0.0, 1.0)
                : null,
          );
          final contentEdgeGap = columnWindow
              ? columns.composerInset
              : composerGap;
          final inputBottomGap = tallWindow
              ? composerGap -
                    reservedBottom +
                    7 * (1 - (keyboardInset / 40).clamp(0.0, 1.0))
              : 4 + (composerGap - 4) * (keyboardInset / 40).clamp(0.0, 1.0);
          return NoticeAnchor(
            pane: paneBounds,
            composer: composerBounds,
            composerInset: contentEdgeGap,
            child: Builder(
              key: paneBounds,
              builder: (context) => Padding(
                // Scaffold already consumes the IME. Reserve only the remaining
                // stable navigation inset, independent of late padding restoration.
                padding: EdgeInsets.only(bottom: reservedBottom),
                child: SafeArea(
                  bottom: false,
                  child: LayoutBuilder(
                    builder: (context, bodyBounds) {
                      final extra =
                          (widget.controller.voice.active &&
                                  !widget.controller.voice.open
                              ? 48.0
                              : 0.0) +
                          (widget.controller.error != null ||
                                  widget.controller.storageError != null
                              ? 100 *
                                    MediaQuery.textScalerOf(context).scale(14) /
                                    14
                              : 0.0);
                      final headerHeight =
                          size.height - keyboardInset - padding.vertical >= 200
                          ? 56.0
                          : 0.0;
                      final compactInput = FoldProportions.compactInput(
                        size.height,
                        keyboardInset,
                      );
                      final attachmentSpace =
                          !compactInput &&
                              widget
                                  .controller
                                  .current
                                  .pendingAttachments
                                  .isNotEmpty
                          ? 48.0
                          : 0.0;
                      final loadingSpace =
                          !compactInput &&
                              widget.controller.attachmentsLoading(
                                widget.controller.current.id,
                              )
                          ? 24.0
                          : 0.0;
                      final minimumInput = compactInput
                          ? 56.0
                          : 110 +
                                inputBottomGap +
                                attachmentSpace +
                                loadingSpace;
                      final extent = math.max(
                        bodyBounds.maxHeight,
                        minimumInput + headerHeight + extra,
                      );
                      return SingleChildScrollView(
                        key: const Key('short-window-scroll'),
                        reverse: true,
                        physics: extent > bodyBounds.maxHeight
                            ? const ClampingScrollPhysics()
                            : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          height: extent,
                          child: Column(
                            children: [
                              if (size.height -
                                      keyboardInset -
                                      padding.vertical >=
                                  200)
                                SizedBox(
                                  height: 56,
                                  child: Row(
                                    key: const ValueKey('chat-header-row'),
                                    children: [
                                      if (layout.split)
                                        // Half-folded the list cannot be folded away.
                                        const SizedBox(width: 12)
                                      else
                                        IconButton(
                                          tooltip: docked ? '收起会话' : '展开会话',
                                          icon: const ListGlyph(),
                                          onPressed: () {
                                            if (layout.docked) {
                                              setState(
                                                () => showDocked = !docked,
                                              );
                                            } else {
                                              FocusManager.instance.primaryFocus
                                                  ?.unfocus();
                                              scaffold.currentState
                                                  ?.openDrawer();
                                            }
                                          },
                                        ),
                                      const Spacer(),
                                      IconButton(
                                        key: const Key('start-new-chat'),
                                        tooltip: '新建会话',
                                        onPressed: () {
                                          FocusManager.instance.primaryFocus
                                              ?.unfocus();
                                          widget.controller.newConversation();
                                        },
                                        style: IconButton.styleFrom(
                                          foregroundColor: Theme.of(context)
                                              .colorScheme
                                              .onSurface,
                                        ),
                                        icon: const Icon(
                                          Icons.edit_square,
                                          size: 21,
                                        ),
                                      ),
                                      JarvisActionMenu(
                                        tooltip: '更多操作',
                                        actions: const [
                                          JarvisMenuAction(
                                            'settings',
                                            '设置',
                                            icon: Icons.tune,
                                          ),
                                          JarvisMenuAction(
                                            'works',
                                            '作品',
                                            icon: Icons.photo_library_outlined,
                                          ),
                                          JarvisMenuAction(
                                            'status',
                                            '模型状态',
                                            icon: Icons.monitor_heart_outlined,
                                          ),
                                        ],
                                        onSelected: (value) {
                                          if (value == 'settings') {
                                            settings();
                                          } else if (value == 'works') {
                                            unawaited(
                                              showGeneratedWorks(
                                                context,
                                                widget.controller,
                                                conversationId: widget
                                                    .controller
                                                    .current
                                                    .id,
                                              ),
                                            );
                                          } else {
                                            Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) => StatusPage(
                                                  controller: widget.controller,
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: centerContent(
                                  ChatPanel(
                                    key: ValueKey(widget.controller.selectedId),
                                    controller: widget.controller,
                                    keyboardInset: keyboardInset,
                                    welcomeInset: contentEdgeGap,
                                    messageInset: columnWindow
                                        ? columns.messageInset
                                        : 18,
                                    bubbleWidth: columnWindow
                                        ? math.min(
                                            640,
                                            columns.messages *
                                                FoldProportions.userBubble,
                                          )
                                        : null,
                                    welcomeTopInset:
                                        keyboardInset > 0 &&
                                            size.height - padding.vertical >=
                                                200 &&
                                            size.height -
                                                    keyboardInset -
                                                    padding.vertical <
                                                200
                                        ? 56
                                        : 0,
                                  ),
                                ),
                              ),
                              if (widget.controller.error != null ||
                                  widget.controller.storageError != null)
                                centerContent(
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: contentEdgeGap,
                                      vertical: 6,
                                    ),
                                    child: Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        widget.controller.error ??
                                            widget.controller.storageError!,
                                        maxLines: 3,
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
                              if (widget.controller.voice.active &&
                                  !widget.controller.voice.open)
                                centerContent(
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: contentEdgeGap,
                                    ),
                                    child: Container(
                                      key: const Key('call-banner-frame'),
                                      padding: const EdgeInsets.only(left: 12),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainer,
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.circle,
                                            size: 7,
                                            color: Color(0xff2d9f80),
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
                                            onPressed:
                                                widget.controller.voice.expand,
                                            icon: const Icon(
                                              Icons.expand_less,
                                              size: 20,
                                            ),
                                          ),
                                          HangupButton(
                                            onPressed:
                                                widget.controller.voice.stop,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              centerContent(
                                SizedBox(
                                  key: composerBounds,
                                  child: Composer(
                                    key: ValueKey(
                                      'composer-${widget.controller.selectedId}',
                                    ),
                                    controller: widget.controller,
                                    keyboardVisible: keyboardInset > 0,
                                    keyboardInset: keyboardInset,
                                    heightBudget: extent - headerHeight - extra,
                                    edgeGap: contentEdgeGap,
                                    bottomGap: inputBottomGap,
                                  ),
                                ),
                              ),
                            ],
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
                      setState(() {
                        drawerOpen = open;
                        // Automatic closure on entering landscape is not a
                        // new preference. Explicit portrait interactions are.
                        if (!layout.docked) showDocked = open;
                      });
                    },
                    resizeToAvoidBottomInset: true,
                    // Keep the drawer controller alive so its internal open
                    // state can be closed when switching to a docked layout.
                    drawerEnableOpenDragGesture: !layout.docked,
                    // The page behind a drawer goes a little dark; behind a list that
                    // covers the window there is nothing to darken.
                    drawerScrimColor: layout.fullPageList
                        ? Colors.transparent
                        : Colors.black.withValues(alpha: .45),
                    drawer: Drawer(
                      width: layout.sidebarWidth,
                      // The card colour, square at the edge, with a soft shadow where
                      // it is a drawer (as on iOS).
                      elevation: layout.fullPageList ? 0 : 12,
                      shadowColor: Colors.black.withValues(alpha: .35),
                      backgroundColor:
                          Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.surfaceContainerLow
                          : Colors.white,
                      surfaceTintColor: Colors.transparent,
                      shape: const RoundedRectangleBorder(),
                      child: sidebar(
                        drawer: true,
                        fullPage: layout.fullPageList,
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
                              foldGap: layout.foldGap,
                              split: layout.split,
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
                composerAnchor: composerBounds,
                allowPresentation: !drawerOpen,
                noticeInset: padding.right + math.max(16, contentEdgeGap),
                // Half-folded the call page stands on the right screen, as the
                // chat does: it is laid out for that screen's own size and
                // nothing of it crosses the crease.
                child: layout.split
                    ? DisplayFeatureSubScreen(
                        anchorPoint: Offset(size.width, 0),
                        child: VoiceOverlay(
                          key: voiceKey,
                          controller: widget.controller,
                          open: widget.controller.voice.open,
                        ),
                      )
                    : VoiceOverlay(
                        key: voiceKey,
                        controller: widget.controller,
                        open: widget.controller.voice.open,
                      ),
              ),
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
    this.welcomeInset,
    this.messageInset = 18,
    this.bubbleWidth,
  });
  final double? bubbleWidth;
  final double messageInset;
  final double? welcomeInset;
  final JarvisController controller;
  final double keyboardInset;
  final double welcomeTopInset;
  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  late final scroll = FollowScrollController(
    onFollowingChanged: (following) {
      widget.controller.readingHistoryId = following
          ? null
          : widget.controller.current.id;
    },
  );
  String _tailText = '', _tailReasoning = '';
  bool _newReply = false;
  double? _welcomeHeight, _welcomeWidth;
  String? _conversationId;
  int _userMessages = 0;

  @override
  void didUpdateWidget(ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyboardInset != widget.keyboardInset) {
      scroll.keyboardChanged();
    }
  }

  @override
  void dispose() {
    if (widget.controller.readingHistoryId == _conversationId) {
      widget.controller.readingHistoryId = null;
    }
    scroll.dispose();
    super.dispose();
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
    if (c.messages.isEmpty) {
      return LayoutBuilder(
        builder: (context, bounds) {
          final window = MediaQuery.sizeOf(context);
          final tall =
              window.width < 600 &&
              window.height >= window.width * 1.9 &&
              !FoldProportions.isFold(window.width, window.height);
          final welcomeInset =
              widget.welcomeInset ??
              AdaptiveLayout.tallComposerGap(
                MediaQuery.viewPaddingOf(context).bottom,
              );
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
          // Keep the original composition height inside a genuinely resized scroll
          // viewport: when the keyboard appears, every card remains reachable.
          if (!tall) {
            return Padding(
              padding: EdgeInsets.only(top: widget.welcomeTopInset),
              child: _AdaptiveWelcome(
                controller: widget.controller,
                horizontalInset: welcomeInset,
                height: height,
              ),
            );
          }
          // Preserve the welcome composition; the IME only lifts the composer.
          return ClipRect(
            child: Transform.translate(
              offset: Offset(0, widget.welcomeTopInset),
              child: SizedBox(
                height: math.max(
                  0.0,
                  bounds.maxHeight - widget.welcomeTopInset,
                ),
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
                      final avatarSize =
                          88 +
                          100 * range(150, 300) +
                          math.max(0.0, expanded - 188) * spacious;
                      final avatarVisibility = range(90, 160),
                          hintVisibility = range(85, 160),
                          starterVisibility = range(180, 320);
                      final tileHeight =
                          (76 + 8 * spacious) *
                          MediaQuery.textScalerOf(context)
                              .scale(13 + 2 * spacious) /
                          (13 + 2 * spacious);
                      final naturalHeight =
                          32 +
                          (avatarSize * .78 + 12) * avatarVisibility +
                          28 +
                          29 * hintVisibility +
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
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: height),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              welcomeInset,
                              12 + topGap,
                              welcomeInset,
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
                                        key: ValueKey('empty-reactor-${c.id}'),
                                        startupIdentity: c.id,
                                        size: avatarSize,
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                  ),
                                ),
                                Text(
                                  '想聊点什么？',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        fontSize: 21,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                reveal(
                                  hintVisibility,
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(height: 8),
                                      Text(
                                        '写下想法，或直接开口。',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
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
                                          final starters =
                                              widget.controller.starters;
                                          final gap = 10 + 2 * spacious;
                                          final width =
                                              (math.min(space.maxWidth, 620) -
                                                  gap) /
                                              2;
                                          final descriptionLines =
                                              _starterDescriptionLines(
                                                context,
                                                starters,
                                                width - 36,
                                                11 + spacious,
                                              );
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
                                                  child: _StarterCard(
                                                    key: ValueKey('starter-$i'),
                                                    starter: starters[i],
                                                    titleSize: 14 + spacious,
                                                    descriptionSize:
                                                        11 + spacious,
                                                    descriptionLines:
                                                        descriptionLines,
                                                    onPressed: () =>
                                                        _pickStarter(
                                                          widget.controller,
                                                          starters[i].prompt,
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
      );
    }
    final lastReply = c.messages
        .where((m) => m.role == 'assistant' && !m.hidden)
        .lastOrNull;
    if (!scroll.isFollowing &&
        lastReply != null &&
        (lastReply.text != _tailText ||
            lastReply.reasoning != _tailReasoning)) {
      _newReply = true;
    }
    _tailText = lastReply?.text ?? '';
    _tailReasoning = lastReply?.reasoning ?? '';
    if (scroll.isFollowing) _newReply = false;
    scroll.followLatest();
    final messages = scroll.wrap(
      ListView.builder(
        key: PageStorageKey('messages-${c.id}'),
        controller: scroll,
        padding: EdgeInsets.symmetric(
          horizontal: widget.messageInset,
          vertical: 16,
        ),
        itemCount: c.messages.length,
        itemBuilder: (context, i) {
          final m = c.messages[i], user = m.role == 'user';
          if (m.hidden) return const SizedBox.shrink();
          if (m.taskId != null) {
            final task = c.tasks.where((t) => t.id == m.taskId).firstOrNull;
            return task == null
                ? const SizedBox.shrink()
                : MediaCard(
                    key: ValueKey(task.id),
                    task: task,
                    controller: widget.controller,
                  );
          }
          if (m.role == 'assistant' &&
              m.text.isEmpty &&
              m.calls.isNotEmpty &&
              m.error == null) {
            return widget.controller.isGenerating(c.id)
                ? const MessageStatusRow('正在调用工具…')
                : const SizedBox.shrink();
          }
          // A row with nothing to show (no words, thinking, attachment or call,
          // no error, and not being written) is not drawn.
          if (m.role == 'assistant' &&
              m.text.isEmpty &&
              m.reasoning.isEmpty &&
              m.attachments.isEmpty &&
              m.calls.isEmpty &&
              m.error == null &&
              m.status != 'generating' &&
              m.status != 'interrupted' &&
              m.status != 'length') {
            return const SizedBox.shrink();
          }
          return Padding(
            key: ValueKey('message-${c.id}-${m.id}'),
            padding: const EdgeInsets.only(bottom: 20),
            child: Align(
              alignment: user ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: user
                      ? widget.bubbleWidth ??
                            math.min(
                              640,
                              MediaQuery.sizeOf(context).width * .84,
                            )
                      : double.infinity,
                ),
                padding: user
                    ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
                    : const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: user
                      ? Theme.of(context).colorScheme.surfaceContainerHigh
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (m.reasoning.isNotEmpty)
                      ReasoningBlock(
                        key: PageStorageKey('reasoning-${c.id}-${m.id}'),
                        text: m.reasoning,
                        size: widget.controller.settings.messageFontSize + 1,
                        thinking: m.status == 'generating' && m.text.isEmpty,
                        onOpened: scroll.pauseFollowing,
                      ),
                    if (m.attachments.isNotEmpty) ...[
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final a in m.attachments)
                            AttachmentCard(
                              key: ValueKey(a.id),
                              controller: widget.controller,
                              item: a,
                              inMessage: true,
                            ),
                        ],
                      ),
                      if (m.text.isNotEmpty) const SizedBox(height: 8),
                    ],
                    if (user && m.text.isNotEmpty)
                      SelectableText(
                        m.text,
                        style: TextStyle(
                          fontSize:
                              widget.controller.settings.messageFontSize + 1,
                          height: 1.6,
                        ),
                      )
                    else if (!user &&
                        m.text.isEmpty &&
                        m.status == 'generating')
                      const MessageStatusRow('正在思考…')
                    else if (!user)
                      MarkdownBody(
                        styleSheet: chatMarkdownStyle(
                          context,
                          widget.controller.settings.messageFontSize + 1,
                        ),
                        builders: chatMarkdownBuilders(
                          widget.controller.settings.messageFontSize + 1,
                        ),
                        data: m.text,
                        selectable: true,
                        onTapLink: (text, href, title) {
                          final uri = Uri.tryParse(href ?? '');
                          if (uri != null &&
                              ['https', 'http'].contains(uri.scheme)) {
                            launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                        imageBuilder: (uri, title, alt) {
                          final resolved = widget.controller.api.endpoint
                              .resolveUri(uri);
                          if (!['http', 'https'].contains(resolved.scheme) ||
                              !resolved.hasAuthority ||
                              resolved.host.isEmpty) {
                            return const Text('图片地址不可用');
                          }
                          if (resolved.origin !=
                              widget.controller.api.endpoint.origin) {
                            return TextButton(
                              onPressed: () => launchUrl(
                                resolved,
                                mode: LaunchMode.externalApplication,
                              ),
                              child: Text(alt ?? '打开图片'),
                            );
                          }
                          // At most 480 wide, whatever the column is, rounded, with a
                          // retry on failure (the picture's own rules).
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: AuthenticatedImage(
                              controller: widget.controller,
                              url: resolved.toString(),
                              alt: alt ?? '',
                            ),
                          );
                        },
                      ),
                    if (!user && m.text.isNotEmpty && m.status != 'generating')
                      Row(
                        children: [
                          CopyReplyButton(text: m.text),
                          if (m ==
                                  c.messages
                                      .where(
                                        (m) =>
                                            m.role == 'assistant' && !m.hidden,
                                      )
                                      .lastOrNull &&
                              !widget.controller.isGenerating(c.id) &&
                              !widget.controller.voice.active)
                            ReplyActionButton(
                              tooltip: '重新生成',
                              onPressed: widget.controller.regenerate,
                              icon: Icons.refresh,
                            ),
                        ],
                      ),
                    if (m.status == 'interrupted')
                      _ReplyNote(
                        icon: m.error == null
                            ? Icons.stop_circle_outlined
                            : Icons.error_outline,
                        text: m.error ?? '已停止',
                        failed: m.error != null,
                      ),
                    if (m.status == 'length')
                      const _ReplyNote(
                        icon: Icons.info_outline,
                        text: '已达到输出长度上限',
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: messages),
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: scroll.following,
              builder: (context, following, _) => following
                  ? const SizedBox.shrink()
                  : _JumpToLatest(
                      key: const Key('return-to-latest'),
                      label: _newReply ? '有新回复，回到底部' : '回到底部',
                      onPressed: () {
                        _newReply = false;
                        unawaited(scroll.animateToLatest());
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    this.keyboardVisible = false,
    this.keyboardInset = 0,
    this.edgeGap = 10,
    this.bottomGap = 10,
    this.heightBudget = double.infinity,
  });
  final double heightBudget;
  final double edgeGap, bottomGap;
  final JarvisController controller;
  final bool keyboardVisible;
  final double keyboardInset;
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
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

  bool _pickingAttachments = false;
  bool _attachmentManagerOpen = false;

  Future<void> pickAttachments() async {
    if (_pickingAttachments) return;
    _pickingAttachments = true;
    try {
      await chooseAttachments(widget.controller);
    } finally {
      _pickingAttachments = false;
    }
  }

  void attachmentError(Object error) {
    if (mounted) showNotice(context, attachmentErrorMessage(error));
  }

  Future<void> addAttachments() async {
    try {
      await pickAttachments();
    } catch (e) {
      attachmentError(e);
    }
  }

  Future<void> manageAttachments() async {
    if (_attachmentManagerOpen) return;
    _attachmentManagerOpen = true;
    final ownerId = widget.controller.current.id;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => AttachmentManager(
          controller: widget.controller,
          ownerId: ownerId,
          onAdd: pickAttachments,
          onDetachedError: attachmentError,
        ),
      );
    } finally {
      _attachmentManagerOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final effortLabel =
        const {
          'none': '关闭',
          'low': '低',
          'medium': '中',
          'high': '高',
        }[widget.controller.effort] ??
        '高';
    final compact = FoldProportions.compactInput(
      MediaQuery.sizeOf(context).height,
      widget.keyboardInset,
    );
    final attachmentSpace =
        !compact && widget.controller.current.pendingAttachments.isNotEmpty
        ? 48.0
        : 0.0;
    final loadingSpace =
        !compact &&
            widget.controller.attachmentsLoading(widget.controller.current.id)
        ? 24.0
        : 0.0;
    // The line that says why it cannot be sent yet takes room too, and is
    // drawn only where the field keeps its minimum above it.
    final roomWithoutHint =
        widget.heightBudget -
        (62 + widget.bottomGap + attachmentSpace + loadingSpace);
    final hintScale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(13) / 13,
    );
    final hintRoom = 26.0 * hintScale;
    final showHint = !compact && roomWithoutHint >= 48 + hintRoom;
    final blockedSpace =
        showHint &&
            (widget.controller.current.draft.trim().isNotEmpty ||
                widget.controller.current.pendingAttachments.isNotEmpty) &&
            (!widget.controller.authenticated ||
                widget.controller.model.isEmpty ||
                widget.controller.attachmentsLoading(
                  widget.controller.current.id,
                ))
        ? hintRoom
        : 0.0;
    final fieldBudget = compact
        ? 48.0
        : math.max(
            48.0,
            widget.heightBudget -
                (62 +
                    widget.bottomGap +
                    attachmentSpace +
                    loadingSpace +
                    blockedSpace),
          );
    return Padding(
      // Equal spacing from the usable pane edges, including above the IME.
      padding: EdgeInsets.fromLTRB(
        widget.edgeGap,
        compact ? 0 : 4,
        widget.edgeGap,
        compact ? 2 : widget.bottomGap,
      ),
      // The box of the home page: lifted off the page (a blurred card colour,
      // more of it on light), with the controls in it one step lighter again.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            key: const Key('composer-frame'),
            decoration: BoxDecoration(
              color: _composerFill(context),
              border: Border.all(color: _composerEdge(context)),
              borderRadius: BorderRadius.circular(28),
            ),
            padding: EdgeInsets.all(compact ? 2 : 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact &&
                    widget.controller.current.pendingAttachments.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final a
                            in widget.controller.current.pendingAttachments)
                          AttachmentCard(
                            key: ValueKey(a.id),
                            controller: widget.controller,
                            item: a,
                            removable: true,
                          ),
                      ],
                    ),
                  ),
                if (!compact &&
                    widget.controller.attachmentsLoading(
                      widget.controller.current.id,
                    ))
                  const Padding(
                    padding: EdgeInsets.all(6),
                    child: LinearProgressIndicator(),
                  ),
                Flex(
                  direction: compact ? Axis.horizontal : Axis.vertical,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: compact
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      flex: compact ? 1 : 0,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.min(
                            fieldBudget,
                            math.max(
                              48.0,
                              math.min(
                                160.0,
                                MediaQuery.sizeOf(context).height -
                                    widget.keyboardInset -
                                    160,
                              ),
                            ),
                          ),
                        ),
                        child: TextField(
                          key: const Key('chat-input'),
                          controller: text,
                          minLines: 1,
                          maxLines: 5,
                          onChanged: widget.controller.setDraft,
                          style: const TextStyle(fontSize: 17),
                          cursorColor: _accent(context),
                          decoration: InputDecoration(
                            hintText: '发送消息…',
                            hintStyle: TextStyle(
                              fontSize: 17,
                              // A straight phone's hint is a step stronger.
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(
                                    alpha:
                                        FoldProportions.isFold(
                                          MediaQuery.sizeOf(context).width,
                                          MediaQuery.sizeOf(context).height,
                                        )
                                        ? .7
                                        : .85,
                                  ),
                            ),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.fromLTRB(
                              14,
                              16,
                              14,
                              8,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Why it cannot be sent yet, when there is something to send.
                    if (showHint)
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: text,
                        builder: (context, value, _) {
                          final c = widget.controller;
                          final hasDraft =
                              value.text.trim().isNotEmpty ||
                              c.current.pendingAttachments.isNotEmpty;
                          final blocked = !hasDraft
                              ? null
                              : (!c.authenticated || c.model.isEmpty)
                              ? '模型未连接，暂时无法发送'
                              : c.attachmentsLoading(c.current.id)
                              ? '附件处理中，稍后即可发送'
                              : null;
                          return blocked == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    0,
                                    14,
                                    4,
                                  ),
                                  child: Text(
                                    blocked,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                );
                        },
                      ),
                    Flexible(
                      flex: compact ? 1 : 0,
                      child: Row(
                        children: [
                          IconButton(
                            style: compact
                                ? null
                                : IconButton.styleFrom(
                                    backgroundColor: _composerControl(context),
                                    shape: const CircleBorder(),
                                    fixedSize: const Size(36, 36),
                                    minimumSize: const Size(36, 36),
                                    tapTargetSize: MaterialTapTargetSize.padded,
                                  ),
                            tooltip:
                                compact &&
                                    widget
                                        .controller
                                        .current
                                        .pendingAttachments
                                        .isNotEmpty
                                ? '管理已选附件'
                                : '添加附件',
                            icon: Badge(
                              isLabelVisible:
                                  compact &&
                                  widget
                                      .controller
                                      .current
                                      .pendingAttachments
                                      .isNotEmpty,
                              label: Text(
                                '${widget.controller.current.pendingAttachments.length}',
                              ),
                              child:
                                  widget.controller.attachmentsLoading(
                                        widget.controller.current.id,
                                      ) &&
                                      compact
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.add, size: 22),
                            ),
                            onPressed:
                                compact &&
                                    widget
                                        .controller
                                        .current
                                        .pendingAttachments
                                        .isNotEmpty
                                ? manageAttachments
                                : addAttachments,
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: JarvisActionMenu(
                                tooltip: '选择思考深度',
                                selectedValue: widget.controller.effort,
                                onSelected: widget.controller.setEffort,
                                actions: const [
                                  JarvisMenuAction('none', '关闭'),
                                  JarvisMenuAction('low', '低'),
                                  JarvisMenuAction('medium', '中'),
                                  JarvisMenuAction('high', '高'),
                                ],
                                child: !compact
                                    ? Container(
                                        height: 36,
                                        margin: const EdgeInsets.only(left: 4),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: _composerControl(context),
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                        ),
                                        child: Text.rich(
                                          TextSpan(
                                            style: const TextStyle(
                                              fontSize: 15.5,
                                            ),
                                            children: [
                                              TextSpan(
                                                text: '思考 ',
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface,
                                                ),
                                              ),
                                              TextSpan(
                                                text: effortLabel,
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      )
                                    : SizedBox(
                                        height: 48,
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: compact ? 2 : 4,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.lightbulb_outline,
                                                size: compact ? 15 : 17,
                                              ),
                                              SizedBox(width: compact ? 2 : 4),
                                              Flexible(
                                                child: Text(
                                                  compact
                                                      ? effortLabel
                                                      : '思考 · $effortLabel',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Icon(
                                                Icons.expand_more,
                                                size: compact ? 12 : 15,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          InlineWorkNotice(
                            controller: widget.controller,
                            keyboardVisible: widget.keyboardVisible,
                          ),
                          ValueListenableBuilder<TextEditingValue>(
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
                              Future<void> voice() async {
                                FocusScope.of(context).unfocus();
                                if (c.voice.active) {
                                  c.voice.expand();
                                  return;
                                }
                                await c.voice.start(c.current);
                                if (context.mounted &&
                                    c.voice.error != null &&
                                    !c.voice.active) {
                                  showNotice(context, c.voice.error!);
                                }
                              }

                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (showSend)
                                    Transform.translate(
                                      offset: const Offset(-2, -2),
                                      transformHitTests: false,
                                      child: IconButton(
                                        tooltip: '语音对话',
                                        style: IconButton.styleFrom(
                                          backgroundColor: _composerControl(
                                            context,
                                          ),
                                          foregroundColor: Theme.of(context)
                                              .colorScheme
                                              .onSurface,
                                          shape: const CircleBorder(),
                                          fixedSize: const Size(36, 36),
                                          minimumSize: const Size(36, 36),
                                          tapTargetSize:
                                              MaterialTapTargetSize.padded,
                                        ),
                                        onPressed: voice,
                                        icon: const Icon(
                                          Icons.mic_none_rounded,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  Transform.translate(
                                    offset: const Offset(-2, -2),
                                    transformHitTests: false,
                                    child: IconButton.filled(
                                      style: IconButton.styleFrom(
                                        minimumSize: const Size(36, 36),
                                        fixedSize: const Size(36, 36),
                                        padding: EdgeInsets.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.padded,
                                        shape: const CircleBorder(),
                                        // The bright round button: voice at rest (the quiet
                                        // one on a straight phone, so that the bright one is
                                        // send), send or stop once there is something to send.
                                        backgroundColor:
                                            !showSend &&
                                                !FoldProportions.isFold(
                                                  MediaQuery.sizeOf(context)
                                                      .width,
                                                  MediaQuery.sizeOf(context)
                                                      .height,
                                                )
                                            ? _composerControl(context)
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                        foregroundColor: Theme.of(context)
                                            .colorScheme
                                            .surface,
                                        disabledBackgroundColor:
                                            Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: .38),
                                        disabledForegroundColor: Theme.of(
                                          context,
                                        ).colorScheme.surface,
                                      ),
                                      tooltip: showSend
                                          ? (generating ? '停止当前回复' : '发送')
                                          : '语音对话',
                                      onPressed: !showSend
                                          ? voice
                                          : generating
                                          ? () => c.cancel(c.current.id)
                                          : canSend
                                          ? () => unawaited(c.send())
                                          : null,
                                      icon: !showSend
                                          ? Icon(
                                              Icons.mic_rounded,
                                              size: 21,
                                              color:
                                                  !FoldProportions.isFold(
                                                    MediaQuery.sizeOf(context)
                                                        .width,
                                                    MediaQuery.sizeOf(context)
                                                        .height,
                                                  )
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .surface,
                                            )
                                          : Icon(
                                              showSend
                                                  ? (generating
                                                        ? Icons.stop_rounded
                                                        : Icons.arrow_upward)
                                                  : Icons.graphic_eq,
                                              size:
                                                  !showSend &&
                                                      MediaQuery.sizeOf(context)
                                                              .height >=
                                                          MediaQuery.sizeOf(
                                                                context,
                                                              ).width *
                                                              1.9
                                                  ? 16
                                                  : 20,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surface,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact notice at the bottom of the conversation list (deleted + undo).
class _SidebarNotice extends StatelessWidget {
  const _SidebarNotice({super.key, required this.text, this.onUndo});
  final String text;
  final VoidCallback? onUndo;

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
            borderRadius: BorderRadius.circular(16),
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
              if (onUndo != null)
                TextButton(onPressed: onUndo, child: const Text('撤销')),
            ],
          ),
        ),
      ),
    );
  }
}

// A conversation owns its live identity even when rotation reparents the slot.
class _WelcomeIdentityKey extends GlobalObjectKey {
  const _WelcomeIdentityKey(super.value);
}

/// Foldable welcome: identity and greeting occupy the upper available space;
/// suggestions share the composer width and sit near its lower edge.
class _FoldWelcome extends StatelessWidget {
  const _FoldWelcome({
    required this.controller,
    required this.height,
    required this.horizontalInset,
  });
  final JarvisController controller;
  final double height, horizontalInset;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final width = math.max(1.0, bounds.maxWidth - 2 * horizontalInset);
      final window = MediaQuery.sizeOf(context);
      final landscape = window.width > window.height;
      final coverLandscape =
          landscape && math.min(window.width, window.height) < 600;
      final innerLandscape = landscape && !coverLandscape;
      final safe = MediaQuery.viewPaddingOf(context).horizontal;
      final layout = AdaptiveLayout.forWindow(
        window.width,
        window.height,
        horizontalInsets: safe,
      );
      // Pin typography and text wrapping to the narrower docked pane. Width
      // may animate, but a card never changes height halfway through a drag.
      final typeWidth = innerLandscape && layout.docked
          ? FoldProportions.columns(
              windowWidth: window.width,
              windowHeight: window.height,
              paneWidth: window.width - safe - layout.sidebarWidth,
              dockedMode: true,
              sidebarOpen: true,
            ).composer
          : width;
      final narrow = typeWidth < 420;
      final scaler = MediaQuery.textScalerOf(context);
      final titleSize = narrow ? 14.0 : 15.0;
      final detailSize = narrow ? 12.0 : 13.0;
      final detailLines = _starterDescriptionLines(
        context,
        controller.starters,
        (typeWidth - 10) / 2 - 36,
        detailSize,
      );
      final tile = math.max(
        (narrow ? 78.0 : 88.0) * (innerLandscape ? .8 : 1),
        scaler.scale(titleSize) * 1.35 +
            4 +
            scaler.scale(detailSize) * 1.4 * detailLines +
            (innerLandscape ? 16 : 24),
      );
      final cardsHeight = tile * 2 + 10;
      final titleStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
        fontSize: FoldProportions.welcomeTitle,
        fontWeight: FontWeight.bold,
        height: 1.25,
      );
      final hintStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontSize: FoldProportions.welcomeHint,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
      final greeting = timeGreeting(DateTime.now());
      const hint = '有什么想聊的？输入问题，或点击麦克风直接说话。';
      final showCards = !coverLandscape;
      final floorGap = math.max(
        12.0,
        MediaQuery.viewPaddingOf(context).bottom - 4,
      );
      final identityGap = innerLandscape ? 12.0 : 18.0;
      final cardGap = innerLandscape ? 12.0 : 20.0;
      var figure = landscape
          ? (coverLandscape ? 120.0 : 128.0)
          : (150 + 70 * ((height - cardsHeight - 220) / 170).clamp(0.0, 1.0));
      // Identity and both lines stay visible. Suggestions yield first on the
      // cover landscape; other compact windows can scroll naturally.
      final textWidth = coverLandscape
          ? math.max(1.0, width - figure - 20)
          : width;
      double textHeight(String text, TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: textWidth);
        final result = painter.height;
        painter.dispose();
        return result;
      }

      final wordsHeight =
          textHeight(greeting, titleStyle) + 8 + textHeight(hint, hintStyle);
      if (!coverLandscape) {
        figure = math.min(
          figure,
          math.max(
            100.0,
            (height -
                    cardsHeight -
                    floorGap -
                    cardGap -
                    16 -
                    identityGap -
                    wordsHeight) /
                .9,
          ),
        );
      }
      final groupHeight = coverLandscape
          ? math.max(figure * .9, wordsHeight)
          : figure * .9 + identityGap + wordsHeight;
      final extent = math.max(
        height,
        groupHeight + (showCards ? cardsHeight + cardGap : 0) + floorGap + 16,
      );
      final space = extent - (showCards ? cardsHeight + cardGap : 0) - floorGap;
      final top = math.max(
        8.0,
        (space - groupHeight) * (coverLandscape ? .5 : .4),
      );
      Widget identity() => KeyedSubtree(
        key: _WelcomeIdentityKey(controller.current),
        child: SizedBox(
          key: const Key('welcome-identity'),
          width: figure,
          height: figure * .9,
          child: CoreAvatar(
            key: ValueKey('empty-reactor-${controller.current.id}'),
            startupIdentity: controller.current.id,
            size: figure,
          ),
        ),
      );
      Widget words() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: coverLandscape
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Text(
            greeting,
            key: const Key('welcome-greeting'),
            style: titleStyle,
            textAlign: coverLandscape ? TextAlign.start : TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            key: const Key('welcome-hint'),
            style: hintStyle,
            textAlign: coverLandscape ? TextAlign.start : TextAlign.center,
          ),
        ],
      );
      return ScrollAffordance(
        enabled:
            MediaQuery.viewInsetsOf(context).bottom == 0 &&
            extent > bounds.maxHeight + 1,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: extent,
            child: Stack(
              children: [
                Positioned(
                  left: horizontalInset,
                  right: horizontalInset,
                  top: top,
                  child: coverLandscape
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            identity(),
                            const SizedBox(width: 20),
                            Flexible(child: words()),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            identity(),
                            SizedBox(height: identityGap),
                            words(),
                          ],
                        ),
                ),
                if (showCards)
                  Positioned(
                    left: horizontalInset,
                    right: horizontalInset,
                    bottom: floorGap,
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < controller.starters.length; i++)
                          SizedBox(
                            width: (width - 10) / 2,
                            height: tile,
                            child: _StarterCard(
                              key: ValueKey('starter-$i'),
                              starter: controller.starters[i],
                              titleSize: titleSize,
                              descriptionSize: detailSize,
                              descriptionLines: detailLines,
                              onPressed: () => _pickStarter(
                                controller,
                                controller.starters[i].prompt,
                              ),
                            ),
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
  );
}

/// Fits the empty-state composition to the actual content pane, after system bars,
/// header and composer have taken their space. Large accessibility text may scroll.
class _AdaptiveWelcome extends StatelessWidget {
  const _AdaptiveWelcome({
    required this.controller,
    required this.height,
    this.horizontalInset = 10,
  });
  final JarvisController controller;
  final double height, horizontalInset;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final window = MediaQuery.sizeOf(context);
    if (FoldProportions.isFold(window.width, window.height)) {
      return _FoldWelcome(
        controller: controller,
        height: height,
        horizontalInset: horizontalInset,
      );
    }
    final expandedPortrait =
        window.width >= 600 && window.height > window.width;
    final baseTileHeight = 68.0 * scaler.scale(13) / 13;
    final tileHeight = baseTileHeight * (expandedPortrait ? 1.1025 : 1.0);
    // Grow downwards while retaining the portrait avatar and greeting anchor.
    final topPadding =
        4.0 + (expandedPortrait ? 2 * (tileHeight - baseTileHeight) : 0.0);
    const greeting = '想聊点什么？';
    final titleStyle = theme.textTheme.titleLarge!.copyWith(
      fontSize: 21,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    final hintStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 15,
      height: 1.4,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = math.min(
          620.0,
          math.max(0.0, bounds.maxWidth - 2 * horizontalInset),
        );
        double measure(String text, TextStyle style) {
          final p = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout(maxWidth: width);
          final result = p.height;
          p.dispose();
          return result;
        }

        const hint = '写下想法，或直接开口。';
        final fixedHeight =
            topPadding +
            12 +
            measure(greeting, titleStyle) +
            6 +
            measure(hint, hintStyle) +
            14 +
            tileHeight * 2 +
            10;
        final room = height - fixedHeight;
        final avatarSize = math.min(
          bounds.maxWidth < 500 ? 200.0 : 280.0,
          math.max(64.0, (room - 8) / .78),
        );
        final canFit = room >= 58;
        Widget avatar() => Center(
          child: CoreAvatar(
            key: ValueKey('empty-reactor-${controller.current.id}'),
            startupIdentity: controller.current.id,
            size: avatarSize,
          ),
        );
        final descriptionLines = _starterDescriptionLines(
          context,
          controller.starters,
          (width - 10) / 2 - 36,
          11,
        );
        final cards = SizedBox(
          width: width,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < controller.starters.length; i++)
                SizedBox(
                  width: (width - 10) / 2,
                  height: tileHeight,
                  child: _StarterCard(
                    key: ValueKey('starter-$i'),
                    starter: controller.starters[i],
                    descriptionLines: descriptionLines,
                    onPressed: () =>
                        _pickStarter(controller, controller.starters[i].prompt),
                  ),
                ),
            ],
          ),
        );
        // Lift only within existing spare space so short windows and large text remain scrollable.
        final lift = expandedPortrait && canFit
            ? math.min(
                16.0,
                math.max(
                  0.0,
                  (height - fixedHeight - avatarSize * .78) / 2 - 4,
                ),
              )
            : 0.0;
        final content = Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalInset,
            topPadding,
            horizontalInset,
            12,
          ),
          child: Column(
            mainAxisSize: canFit ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: canFit ? avatarSize * .78 : 58, child: avatar()),
              const SizedBox(height: 8),
              Text(greeting, style: titleStyle, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(hint, style: hintStyle, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              cards,
            ],
          ),
        );
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: math.max(height, fixedHeight + 72),
            child: Transform.translate(
              offset: Offset(0, -lift),
              child: content,
            ),
          ),
        );
      },
    );
  }
}

/// Text-only suggestions share only the description lines actually needed by the group.
class _StarterCard extends StatelessWidget {
  const _StarterCard({
    super.key,
    required this.starter,
    required this.onPressed,
    this.titleSize = 14,
    this.descriptionSize = 11,
    this.descriptionLines = 1,
  });
  final Starter starter;
  final VoidCallback onPressed;
  final double titleSize, descriptionSize;
  final int descriptionLines;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final descriptionHeight =
        MediaQuery.textScalerOf(context).scale(descriptionSize) *
        1.4 *
        descriptionLines;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.centerLeft,
        backgroundColor: colors.brightness == Brightness.dark
            ? colors.surfaceContainerLow
            : Colors.white,
        side: BorderSide(color: colors.outlineVariant),
        overlayColor: colors.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              starter.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: titleSize,
                height: 1.35,
                letterSpacing: 0,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: descriptionHeight,
              child: Text(
                starter.description ?? '',
                maxLines: descriptionLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: descriptionSize,
                  height: 1.4,
                  letterSpacing: 0,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

int _starterDescriptionLines(
  BuildContext context,
  List<Starter> starters,
  double width,
  double fontSize,
) {
  var lines = 1;
  for (final starter in starters) {
    final painter = TextPainter(
      text: TextSpan(
        text: starter.description ?? '',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(fontSize: fontSize, height: 1.4, letterSpacing: 0),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
    )..layout(maxWidth: math.max(1, width));
    lines = math.max(lines, painter.computeLineMetrics().length);
    painter.dispose();
  }
  return lines.clamp(1, 2);
}

/// The way back to the newest words: a round glass button with a down arrow.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({
    super.key,
    required this.onPressed,
    required this.label,
  });
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Material(
            color: colors.onSurface.withValues(alpha: dark ? .14 : .08),
            shape: CircleBorder(
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .6),
                width: .5,
              ),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox.square(
                dimension: 44,
                child: Icon(
                  Icons.arrow_downward,
                  size: 20,
                  color: colors.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The box of the home page, lifted off the page: the card colour (a little of
/// the page showing through), its hairline, and the controls in it one step
/// lighter again. (iOS Palette.composer / composerEdge / composerControl.)
Color _composerFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff222226).withValues(alpha: .6)
    : Colors.white.withValues(alpha: .6);
Color _composerEdge(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff3a3a40)
    : const Color(0xffdce3e1);
Color _composerControl(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff38383e)
    : const Color(0xffedf0ef);

/// The cyan for text-like uses (iOS Palette.accent).
Color _accent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff8fdceb)
    : const Color(0xff137589);

/// A starter card is picked: its prompt is added to what is written, with a
/// light tap.
void _pickStarter(JarvisController controller, String prompt) {
  HapticFeedback.lightImpact().catchError((Object _) {});
  controller.addStarterPrompt(prompt);
}

/// A line under a reply that stopped or ran out: a small icon and a quiet line
/// (in the error colour when it failed).
class _ReplyNote extends StatelessWidget {
  const _ReplyNote({
    required this.icon,
    required this.text,
    this.failed = false,
  });
  final IconData icon;
  final String text;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = failed ? colors.error : colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tone),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 12, color: tone)),
          ),
        ],
      ),
    );
  }
}

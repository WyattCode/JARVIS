import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../model/media.dart';
import '../state/jarvis_controller.dart';
import 'design_tokens.dart';
import 'duo_layout.dart';
import 'media_widgets.dart';
import 'motion.dart';
import 'call_controls.dart';
import 'action_menu.dart';

final _worksOpen = Expando<bool>('generated-works-open');
final _worksHighlights = Expando<Set<String>>('generated-works-highlights');

Future<void> showGeneratedWorks(
  BuildContext context,
  JarvisController controller, {
  Set<String> highlightIds = const {},
  void Function(MediaTask task)? onCancelTask,
  Future<void> Function()? openSettings,
}) async {
  if (_worksOpen[controller] == true) return;
  _worksOpen[controller] = true;
  _worksHighlights[controller] = {...highlightIds};
  try {
    await showModalBottomSheet<void>(
      context: context,
      routeSettings: const RouteSettings(name: voiceWorksRouteName),
      isScrollControlled: true,
      // The sheet draws its own surface and reads the call layout when it builds, so it keeps off the iPhone Duo's
      // crease and follows a fold change while it is open (same as the voice picker).
      backgroundColor: Colors.transparent,
      elevation: 0,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      builder: (context) => _WorksSheet(
        controller: controller,
        onCancelTask: onCancelTask,
        openSettings: openSettings,
      ),
    );
  } finally {
    _worksOpen[controller] = false;
    _worksHighlights[controller] = null;
  }
}

/// The works as a bottom sheet: centred (up to 640 wide) in the part of the window the content may use, as high as its
/// content up to 80%, and when half-folded in portrait no taller than the half below the crease.
class _WorksSheet extends StatelessWidget {
  const _WorksSheet({
    required this.controller,
    this.onCancelTask,
    this.openSettings,
  });
  final JarvisController controller;
  final void Function(MediaTask task)? onCancelTask;
  final Future<void> Function()? openSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duo = DuoLayoutScope.of(context);
    final size = MediaQuery.sizeOf(context),
        pad = MediaQuery.paddingOf(context);
    final pane = duo.sheetPane(size, pad);
    final width = math.min(640.0, pane.width);
    final left = pane.left + (pane.width - width) / 2;
    return Padding(
      padding: EdgeInsets.only(left: left, right: size.width - left - width),
      child: Material(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
          side: BorderSide(color: colors.outlineVariant, width: .5),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: duo.sheetMaxHeight(size, .8)),
          // The window's side insets belong to the pane above, not to the content. The home-indicator inset is the
          // list's bottom padding instead: the cards scroll on under the indicator rather than being cut at its line.
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: false,
            // Works arriving or leaving grow and shrink the sheet instead of jumping.
            child: SmoothSize(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The grabber is drawn in 24 pt but answers a 44 pt tall touch: its strip overlays the top of the title
                  // row (only the middle 64 pt, where there is no control), so the layout does not move.
                  Stack(
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 24),
                          // The title and the way out stay put while the works scroll.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              Metrics.pageMargin,
                              0,
                              8,
                              4,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      '生成作品',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  key: const Key('works-done'),
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(44, 44),
                                  ),
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('完成'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 44,
                        child: Center(
                          child: SizedBox(
                            width: 64,
                            child: Semantics(
                              label: '关闭生成作品',
                              button: true,
                              onTap: () => Navigator.of(context).pop(),
                              child: GestureDetector(
                                key: const Key('works-grabber'),
                                behavior: HitTestBehavior.opaque,
                                excludeFromSemantics: true,
                                onTap: () => Navigator.of(context).pop(),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: Container(
                                      width: 32,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: colors.onSurfaceVariant
                                            .withValues(alpha: .4),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
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
                  Flexible(
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) {
                        final works = _orderedWorks(controller);
                        // Built as they scroll into view: the sheet is never taller than its maximum, so the
                        // shrink-wrapping viewport lays out only what fits (plus its cache) however many works there are.
                        return ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.fromLTRB(
                            Metrics.pageMargin,
                            4,
                            Metrics.pageMargin,
                            20 + pad.bottom,
                          ),
                          itemCount: works.length,
                          findChildIndexCallback: (key) {
                            final id = (key as ValueKey<String>).value;
                            final i = works.indexWhere((w) => w.id == id);
                            return i < 0 ? null : i;
                          },
                          itemBuilder: (context, i) => MediaCard(
                            key: ValueKey(works[i].id),
                            task: works[i],
                            controller: controller,
                            // The cards' edges line up with the title and 完成 above (the theme's 4 pt card margin
                            // would inset them).
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            onCancel: onCancelTask == null
                                ? null
                                : () => onCancelTask!(works[i]),
                            openSettings: openSettings,
                          ),
                        );
                      },
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

List<MediaTask> _orderedWorks(JarvisController controller) {
  // Newest first: conversations are listed newest first already, but each one appends its tasks, so only those flip.
  final tasks = [for (final c in controller.conversations) ...c.tasks.reversed];
  final highlight = _worksHighlights[controller] ?? <String>{};
  return [
    ...tasks.where((t) => highlight.contains(t.id)),
    ...tasks.where((t) => !highlight.contains(t.id)),
  ];
}

/// Watches task transitions, never replays historical results on app startup.
class CompletedWorksPresenter extends StatefulWidget {
  const CompletedWorksPresenter({
    super.key,
    required this.controller,
    required this.child,
    this.allowPresentation = true,
    this.onCancelTask,
    this.openSettings,
  });
  final bool allowPresentation;
  final JarvisController controller;
  final Widget child;

  /// Handed to the cards in the sheet, see [MediaCard.onCancel] / [MediaCard.openSettings].
  final void Function(MediaTask task)? onCancelTask;
  final Future<void> Function()? openSettings;
  @override
  State<CompletedWorksPresenter> createState() =>
      _CompletedWorksPresenterState();
}

class _CompletedWorksPresenterState extends State<CompletedWorksPresenter> {
  /// Tasks seen not yet completed in this session: only these may turn into a presentation. Works that were already
  /// finished when the page opened, or that arrive finished (a backup import), are history, never news.
  final _watching = <String>{};
  final _pending = <String>{};
  Timer? _timer;

  /// A finger has been on the screen within the last [_idleAfter]: the user is reading or scrolling.
  bool _touching = false;
  Timer? _idleTimer;
  static const _idleAfter = Duration(seconds: 5);

  void _touched(PointerEvent event) {
    _touching = true;
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleAfter, () => _touching = false);
  }

  Iterable<MediaTask> get _tasks => widget.controller.conversations.expand(
    (conversation) => conversation.tasks,
  );
  Iterable<MediaTask> get _completed => _tasks.where(
    (task) => task.status == 'completed' && task.urls.isNotEmpty,
  );
  void _watchUnfinished() {
    for (final task in _tasks) {
      if (task.status != 'completed') _watching.add(task.id);
    }
  }

  void _bind() {
    _watchUnfinished();
    widget.controller.addListener(_sync);
  }

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_touched);
    _bind();
  }

  @override
  void didUpdateWidget(CompletedWorksPresenter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_sync);
    _timer?.cancel();
    _timer = null;
    _watching.clear();
    _pending.clear();
    _bind();
  }

  void _sync() {
    _watchUnfinished();
    _watching.retainAll(_tasks.map((task) => task.id));
    for (final task in _completed) {
      if (_watching.remove(task.id)) {
        _pending.add(task.id);
        _worksHighlights[widget.controller]?.add(task.id);
      }
    }
    _pending.retainAll(_completed.map((task) => task.id));
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 120), _present);
  }

  /// A text field has the focus (the keyboard is up or about to be): a sheet sliding over it would cut the sentence off.
  bool get _typing =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  void _present() {
    _timer = null;
    if (!mounted) return;
    _pending.retainAll(_completed.map((task) => task.id));
    if (_pending.isEmpty) return;
    if (_worksOpen[widget.controller] == true) {
      _pending.clear();
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!widget.allowPresentation ||
        _typing ||
        JarvisActionMenu.isOpen ||
        ModalRoute.of(context)?.isCurrent == false ||
        widget.controller.voice.held ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      _timer = Timer(const Duration(milliseconds: 350), _present);
      return;
    }
    final highlight = {..._pending};
    _pending.clear();
    void open() => unawaited(
      showGeneratedWorks(
        context,
        widget.controller,
        highlightIds: highlight,
        onCancelTask: widget.onCancelTask,
        openSettings: widget.openSettings,
      ),
    );
    // A sheet that slides up by itself at 80% height interrupts reading and takes VoiceOver's focus. While the user is
    // active (or uses VoiceOver) the finished card in the chat is announced by a notice instead, with a way to the sheet.
    if (_touching || MediaQuery.accessibleNavigationOf(context)) {
      showNotice(
        context,
        highlight.length > 1 ? '${highlight.length} 个作品已生成' : '作品已生成',
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            if (mounted) open();
          },
        ),
      );
      return;
    }
    open();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_touched);
    _idleTimer?.cancel();
    _timer?.cancel();
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

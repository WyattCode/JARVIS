import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/media.dart';
import '../model/conversation.dart';
import '../state/jarvis_controller.dart';
import 'media_widgets.dart';
import 'call_controls.dart';
import 'action_menu.dart';

final _worksOpen = Expando<bool>('generated-works-open');
final _worksOwner = Expando<String>('generated-works-owner');
final _worksHighlights = Expando<Set<String>>('generated-works-highlights');

Future<void> showGeneratedWorks(
  BuildContext context,
  JarvisController controller, {
  Set<String> highlightIds = const {},
  String? conversationId,
}) async {
  if (_worksOpen[controller] == true) return;
  final ownerId =
      conversationId ??
      (controller.voice.open ? controller.voice.conversationId : null) ??
      controller.current.id;
  _worksOpen[controller] = true;
  _worksOwner[controller] = ownerId;
  _worksHighlights[controller] = {...highlightIds};
  try {
    await showModalBottomSheet<void>(
      context: context,
      routeSettings: const RouteSettings(name: voiceWorksRouteName),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                  child: Text(
                    '生成作品',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (!controller.conversations.any(
                  (c) => c.id == ownerId && c.tasks.isNotEmpty,
                ))
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('此会话暂无作品'),
                  ),
                for (final task in _orderedWorks(controller, ownerId))
                  MediaCard(
                    key: ValueKey(task.id),
                    task: task,
                    controller: controller,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  } finally {
    _worksOpen[controller] = false;
    _worksOwner[controller] = null;
    _worksHighlights[controller] = null;
  }
}

List<MediaTask> _orderedWorks(JarvisController controller, String ownerId) {
  final tasks = controller.conversations
      .where((c) => c.id == ownerId)
      .expand((c) => c.tasks)
      .toList()
      .reversed
      .toList();
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
    this.noticeInset = 16,
    this.composerAnchor,
  });
  final GlobalKey? composerAnchor;
  final double noticeInset;
  final bool allowPresentation;
  final JarvisController controller;
  final Widget child;
  @override
  State<CompletedWorksPresenter> createState() =>
      _CompletedWorksPresenterState();
}

class _CompletedWorksPresenterState extends State<CompletedWorksPresenter> {
  final _seen = <String>{};
  final _pending = <String>{};
  Timer? _timer;
  bool _notice = false;
  Rect? _anchorRect;
  bool _samplingAnchor = false;
  void _sampleAnchor() {
    if (_samplingAnchor) return;
    _samplingAnchor = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _samplingAnchor = false;
      if (!mounted) return;
      final box = widget.composerAnchor?.currentContext?.findRenderObject();
      final host = context.findRenderObject();
      final next =
          box is RenderBox &&
              host is RenderBox &&
              box.attached &&
              host.attached &&
              box.hasSize &&
              host.hasSize
          ? host.globalToLocal(box.localToGlobal(Offset.zero)) & box.size
          : null;
      if (next != _anchorRect) setState(() => _anchorRect = next);
    });
  }

  Conversation? _owner(String taskId) => widget.controller.conversations
      .where((c) => c.tasks.any((t) => t.id == taskId))
      .firstOrNull;
  String get _foreground => widget.controller.voice.open
      ? widget.controller.voice.conversationId ?? widget.controller.current.id
      : widget.controller.current.id;
  void _setNotice(bool value) {
    if (_notice != value && mounted) setState(() => _notice = value);
  }

  void _openPending(String ownerId) {
    final ids = _pending.where((id) => _owner(id)?.id == ownerId).toSet();
    if (!mounted || ids.isEmpty) return;
    widget.controller.updatePendingWorkNotice(null, clearSource: this);
    setState(() {
      _pending.removeAll(ids);
      _notice = _pending.isNotEmpty;
    });
    unawaited(
      showGeneratedWorks(
        context,
        widget.controller,
        conversationId: ownerId,
        highlightIds: ids,
      ),
    );
  }

  Iterable<MediaTask> get _completed => widget.controller.conversations
      .expand((conversation) => conversation.tasks)
      .where((task) => task.status == 'completed' && task.urls.isNotEmpty);
  void _bind() {
    _seen.addAll(_completed.map((task) => task.id));
    widget.controller.addListener(_sync);
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(CompletedWorksPresenter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_sync);
    final oldController = oldWidget.controller;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => oldController.updatePendingWorkNotice(null, clearSource: this),
    );
    _timer?.cancel();
    _timer = null;
    _seen.clear();
    _pending.clear();
    _notice = false;
    _bind();
  }

  void _sync() {
    for (final task in _completed) {
      if (_seen.add(task.id)) {
        _pending.add(task.id);
        _worksHighlights[widget.controller]?.add(task.id);
      }
    }
    _pending.retainAll(_completed.map((task) => task.id));
    if (_notice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _notice = _pending.isNotEmpty);
      });
    }
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 120), _present);
  }

  void _present() {
    _timer = null;
    if (!mounted) return;
    _pending.retainAll(_completed.map((task) => task.id));
    if (_pending.isEmpty) {
      _setNotice(false);
      return;
    }
    if (_worksOpen[widget.controller] == true) {
      final ownerId = _worksOwner[widget.controller];
      _pending.removeWhere((id) => _owner(id)?.id == ownerId);
      _setNotice(_pending.isNotEmpty);
      if (_pending.isNotEmpty) {
        _timer = Timer(const Duration(milliseconds: 350), _present);
      }
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    // Recheck immediately before presenting: focus may return while a result
    // is waiting behind a menu, route transition or an earlier timer.
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editing =
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final reading =
        !widget.controller.voice.open &&
        widget.controller.readingHistoryId == _foreground;
    final foregroundReady = _pending.any((id) => _owner(id)?.id == _foreground);
    if (editing ||
        reading ||
        !foregroundReady ||
        keyboardVisible ||
        !widget.allowPresentation ||
        JarvisActionMenu.isOpen ||
        ModalRoute.of(context)?.isCurrent == false ||
        widget.controller.voice.held ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      _setNotice(true);
      _timer = Timer(const Duration(milliseconds: 350), _present);
      return;
    }
    _openPending(_foreground);
    if (_pending.isNotEmpty) {
      _timer = Timer(const Duration(milliseconds: 350), _present);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_sync);
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller.updatePendingWorkNotice(null, clearSource: this),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = _pending.isEmpty ? null : _owner(_pending.first);
    final visible =
        _notice &&
        owner != null &&
        widget.allowPresentation &&
        ModalRoute.of(context)?.isCurrent != false;
    _sampleAnchor();
    final media = MediaQuery.of(context);
    final shortInput =
        media.viewInsets.bottom > 0 &&
        (media.size.height - media.viewInsets.bottom < 300 ||
            (_anchorRect != null &&
                _anchorRect!.top - media.padding.top <
                    (widget.controller.readingHistoryId ==
                            widget.controller.current.id
                        ? 112
                        : 56)));
    final inline = visible && shortInput && !widget.controller.voice.open;
    final wasInline = widget.controller.pendingWorkNotice.value?.source == this;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.updatePendingWorkNotice(
        inline
            ? (
                source: this,
                ownerId: owner.id,
                title: owner.title,
                open: () {
                  if (!mounted) return;
                  FocusManager.instance.primaryFocus?.unfocus();
                  _openPending(owner.id);
                },
              )
            : null,
      );
      if (!inline && wasInline && mounted) setState(() {});
    });
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (visible && !inline && !wasInline)
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _WorkNoticeLayout(
                inset: widget.noticeInset,
                safeTop: media.padding.top,
                floor: media.viewInsets.bottom + media.padding.bottom,
                reading:
                    widget.controller.readingHistoryId ==
                    widget.controller.current.id,
                voice: widget.controller.voice.open,
                anchor: _anchorRect,
              ),
              child: Material(
                elevation: 4,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: TextButton.icon(
                          key: const Key('completed-work-notice'),
                          onPressed: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            _openPending(owner.id);
                          },
                          icon: const Icon(
                            Icons.check_circle_outline,
                            size: 18,
                          ),
                          label: Text(
                            '作品已完成 · ${owner.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '忽略此次完成提醒',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          setState(() {
                            _pending.removeWhere(
                              (id) => _owner(id)?.id == owner.id,
                            );
                            _notice = _pending.isNotEmpty;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkNoticeLayout extends SingleChildLayoutDelegate {
  _WorkNoticeLayout({
    required this.inset,
    required this.safeTop,
    required this.floor,
    required this.reading,
    required this.voice,
    required this.anchor,
  });
  final double inset, safeTop, floor;
  final bool reading, voice;
  final Rect? anchor;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(360, math.max(0, constraints.maxWidth - 2 * inset)),
        maxHeight: math.max(0, constraints.maxHeight - floor - safeTop),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final input = voice ? null : anchor;
    final desired = input != null
        ? input.top - childSize.height - 8 - (reading ? 56 : 0)
        : size.height -
              floor -
              (voice
                  ? 132
                  : reading
                  ? 176
                  : 116) -
              childSize.height;
    final ceiling = safeTop + 4;
    final lastTop = math.max(
      ceiling,
      size.height - floor - childSize.height - 4,
    );
    return Offset(
      math.max(0, size.width - inset - childSize.width),
      desired.clamp(ceiling, lastTop),
    );
  }

  @override
  bool shouldRelayout(covariant _WorkNoticeLayout oldDelegate) => true;
}

/// Small-window completion entry reserves its own place in the composer row.
class InlineWorkNotice extends StatelessWidget {
  const InlineWorkNotice({
    super.key,
    required this.controller,
    required this.keyboardVisible,
  });
  final JarvisController controller;
  final bool keyboardVisible;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<PendingWorkNotice?>(
        valueListenable: controller.pendingWorkNotice,
        builder: (context, notice, _) {
          if (notice == null || !keyboardVisible || controller.voice.open) {
            return const SizedBox.shrink();
          }
          return Semantics(
            liveRegion: true,
            child: IconButton(
              key: const Key('completed-work-notice'),
              tooltip: '作品已完成 · ${notice.title}',
              onPressed: notice.open,
              icon: Badge(
                backgroundColor: Theme.of(context).colorScheme.primary,
                smallSize: 6,
                child: const Icon(Icons.check_circle_outline, size: 20),
              ),
            ),
          );
        },
      );
}

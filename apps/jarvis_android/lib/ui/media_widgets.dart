import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../model/media.dart';
import 'call_controls.dart';
import 'markdown_palette.dart';
import 'motion.dart';
import '../state/attachments.dart';
import '../state/jarvis_controller.dart';

/// Places chat feedback above the composer and within the current chat pane.
class NoticeAnchor extends InheritedWidget {
  const NoticeAnchor({
    super.key,
    required this.pane,
    required this.composer,
    this.composerInset = 10,
    required super.child,
  });
  final GlobalKey pane, composer;
  final double composerInset;

  static EdgeInsets? margins(BuildContext context, {double? compactWidth}) {
    final anchor = context.dependOnInheritedWidgetOfExactType<NoticeAnchor>();
    final pane = anchor?.pane.currentContext?.findRenderObject() as RenderBox?;
    final composer =
        anchor?.composer.currentContext?.findRenderObject() as RenderBox?;
    if (pane == null ||
        composer == null ||
        !pane.hasSize ||
        !composer.hasSize) {
      return null;
    }
    final screen = MediaQuery.sizeOf(context);
    final paneAt = pane.localToGlobal(Offset.zero);
    final composerAt = composer.localToGlobal(Offset.zero);
    final above = composerAt.dy - paneAt.dy;
    if (above < 52) return null;
    final gap = above < 80 ? 4.0 : 16.0;
    final bottom = pane.size.height - above + gap;
    if (compactWidth != null) {
      final left = composerAt.dx + anchor!.composerInset;
      final width = math.min(
        compactWidth,
        math.max(0.0, composer.size.width - 2 * anchor.composerInset),
      );
      return EdgeInsets.fromLTRB(
        left,
        0,
        math.max(0.0, screen.width - left - width),
        bottom,
      );
    }
    return EdgeInsets.fromLTRB(
      paneAt.dx + 16,
      0,
      (screen.width - paneAt.dx - pane.size.width + 16).clamp(0, screen.width),
      bottom,
    );
  }

  @override
  bool updateShouldNotify(NoticeAnchor oldWidget) =>
      pane != oldWidget.pane ||
      composer != oldWidget.composer ||
      composerInset != oldWidget.composerInset;
}

void showNotice(
  BuildContext context,
  String text, {
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 3),
  double verticalOffset = 0,
  bool compact = false,
}) {
  double measure(String value) {
    final style =
        Theme.of(context).snackBarTheme.contentTextStyle ??
        Theme.of(context).textTheme.bodyMedium!;
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final width = compact
      ? measure(text) + measure(action?.label ?? '') + 92
      : null;
  final anchor = NoticeAnchor.margins(context, compactWidth: width);
  final margin = anchor?.copyWith(
    bottom: (anchor.bottom - verticalOffset).clamp(0.0, double.infinity),
  );
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      duration: duration,
      persist: false,
      action: action,
      padding: compact ? const EdgeInsets.symmetric(horizontal: 12) : null,
      actionOverflowThreshold: compact ? 1 : .25,
      behavior: SnackBarBehavior.floating,
      margin: margin,
    ),
  );
}

({String extension, String mime}) _mediaType(Uint8List bytes, String kind) {
  if (kind == 'video') return (extension: 'mp4', mime: 'video/mp4');
  if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71) {
    return (extension: 'png', mime: 'image/png');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return (extension: 'jpg', mime: 'image/jpeg');
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return (extension: 'webp', mime: 'image/webp');
  }
  if (bytes.length >= 6 && String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF') {
    return (extension: 'gif', mime: 'image/gif');
  }
  return (extension: 'bin', mime: 'application/octet-stream');
}

/// The video player behind a card's cover frame; tests swap it out.
@visibleForTesting
VideoPlayerController Function(Uri uri, Map<String, String> headers)
videoCoverPlayer = (uri, headers) =>
    VideoPlayerController.networkUrl(uri, httpHeaders: headers);

/// How a card in the chat shows a generated picture or video, and what its buttons say (MessageCells.swift TaskCell).
class MediaCard extends StatefulWidget {
  const MediaCard({super.key, required this.task, required this.controller});
  final MediaTask task;
  final JarvisController controller;
  static const maxWidth = 560.0;
  @override
  State<MediaCard> createState() => _MediaCardState();
}

enum _SaveNote { idle, busy, saved, failed }

class _MediaCardState extends State<MediaCard> {
  _SaveNote note = _SaveNote.idle;
  bool copied = false;
  Timer? copyTimer, noteTimer;

  @override
  void dispose() {
    copyTimer?.cancel();
    noteTimer?.cancel();
    super.dispose();
  }

  void open(String url) {
    final task = widget.task;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaPreview(
          controller: widget.controller,
          kind: task.kind,
          url: url,
          prompt: task.prompt,
        ),
      ),
    );
  }

  Future<void> copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.task.prompt));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    HapticFeedback.selectionClick();
    copyTimer?.cancel();
    setState(() => copied = true);
    copyTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => copied = false);
    });
  }

  /// Saves every result (a card with several pictures keeps all of them), one save dialog after the other, and says how
  /// it went on the button itself.
  Future<void> save() async {
    if (note == _SaveNote.busy) return;
    final task = widget.task, urls = List<String>.of(task.urls);
    if (urls.isEmpty) return;
    noteTimer?.cancel();
    setState(() => note = _SaveNote.busy);
    var result = _SaveNote.saved;
    try {
      for (var i = 0; i < urls.length; i++) {
        final data = await widget.controller.api.download(urls[i]);
        if (!mounted) return;
        final type = _mediaType(data, task.kind);
        final name = urls.length > 1
            ? 'jarvis-${task.id}-${i + 1}.${type.extension}'
            : 'jarvis-${task.id}.${type.extension}';
        final saved = await NativeFiles.save(data, name, type.mime);
        if (!mounted) return;
        if (!saved) {
          // The person closed the save dialog: nothing to report.
          result = _SaveNote.idle;
          break;
        }
      }
    } catch (_) {
      result = _SaveNote.failed;
    }
    if (!mounted) return;
    setState(() => note = result);
    if (result == _SaveNote.idle) return;
    noteTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => note = _SaveNote.idle);
    });
  }

  Widget action(
    ChatPalette palette, {
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: palette.onSurfaceVariant,
      minimumSize: const Size(0, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: const TextStyle(fontSize: 13),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 6),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final task = widget.task, palette = ChatPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    final video = task.kind == 'video';
    final done = task.status == 'completed' && task.urls.isNotEmpty;
    final many = task.urls.length > 1;
    final saveLabel = switch (note) {
      _SaveNote.busy => '保存中',
      _SaveNote.saved => '已保存',
      _SaveNote.failed => '保存失败，点按重试',
      _SaveNote.idle => many ? '全部保存' : '下载',
    };
    final saveIcon = switch (note) {
      _SaveNote.busy => Icons.hourglass_empty,
      _SaveNote.saved => Icons.check_circle_outline,
      _SaveNote.failed => Icons.error_outline,
      _SaveNote.idle => Icons.download_outlined,
    };
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: MediaCard.maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(16),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (done)
                  for (var i = 0; i < task.urls.length; i++) ...[
                    if (i > 0) const SizedBox(height: 4),
                    InkWell(
                      onTap: () => open(task.urls[i]),
                      child: video
                          ? VideoTile(
                              key: ValueKey('tile-${task.urls[i]}'),
                              controller: widget.controller,
                              url: task.urls[i],
                              seed: task.id,
                              label: task.prompt.isEmpty
                                  ? '播放视频'
                                  : '播放视频：${task.prompt}',
                            )
                          : AuthenticatedImage(
                              controller: widget.controller,
                              url: task.urls[i],
                              alt: task.prompt,
                              maxWidth: MediaCard.maxWidth,
                              // The card opens the viewer for a picture that did not load as well, which asks for it again.
                              retryable: false,
                              opensViewer: false,
                            ),
                    ),
                  ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.prompt.isEmpty
                            ? (video ? '视频任务' : '图片任务')
                            : task.prompt,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16),
                      ),
                      if (task.pending) ...[
                        const SizedBox(height: 8),
                        // Never an endless sweep: a sliver of the bar until the first figure comes.
                        LinearProgressIndicator(
                          value: task.progress > 0
                              ? (task.progress / 100).clamp(0.0, 1.0)
                              : .05,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '后台生成中${task.progress > 0 ? ' · ${task.progress.round()}%' : ''}，可以继续对话',
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (task.error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          task.error!,
                          style: TextStyle(fontSize: 14, color: colors.error),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Wrap(
                    children: [
                      if (task.prompt.isNotEmpty)
                        action(
                          palette,
                          icon: copied
                              ? Icons.check_rounded
                              : Icons.copy_outlined,
                          label: copied ? '已复制' : '复制提示词',
                          onPressed: copy,
                        ),
                      if (done)
                        action(
                          palette,
                          icon: saveIcon,
                          label: saveLabel,
                          onPressed: note == _SaveNote.busy ? null : save,
                        ),
                      // The controller has no way to stop a running job, so there is no cancel button here.
                      if (!task.pending && task.status != 'completed')
                        action(
                          palette,
                          icon: Icons.refresh,
                          label: '重试',
                          onPressed: () =>
                              unawaited(widget.controller.retryMedia(task)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A finished video in a card: a 16:9 tile of two dark colours taken from the task (so that cards differ), the first frame
/// of the video over it when that could be had, and a white play button.
class VideoTile extends StatefulWidget {
  const VideoTile({
    super.key,
    required this.controller,
    required this.url,
    required this.seed,
    this.label = '播放视频',
  });
  final JarvisController controller;
  final String url, seed, label;

  /// Frames are taken by a player kept for the tile; only a few at once.
  static const maxCovers = 2;
  static int _covers = 0;

  /// The two colours of the tile's gradient (iOS: hue from a hash of the task id, 0.45 / 0.5 saturation, 0.4 / 0.2 value).
  static List<Color> gradientFor(String seed) {
    var hash = 0;
    for (final unit in seed.runes) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final hue = (hash % 360) / 360;
    return [
      HSVColor.fromAHSV(1, hue * 360, .45, .4).toColor(),
      HSVColor.fromAHSV(1, ((hue + .11) % 1) * 360, .5, .2).toColor(),
    ];
  }

  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> {
  VideoPlayerController? player;
  bool ready = false, counted = false;

  @override
  void initState() {
    super.initState();
    unawaited(loadCover());
  }

  Future<void> loadCover() async {
    if (VideoTile._covers >= VideoTile.maxCovers) return;
    VideoTile._covers++;
    counted = true;
    try {
      final api = widget.controller.api, uri = api.mediaUri(widget.url);
      final p = videoCoverPlayer(
        uri,
        uri.origin == api.endpoint.origin ? api.mediaHeaders : {},
      );
      player = p;
      await p.initialize();
      if (!mounted) return;
      await p.setVolume(0);
      // A little way in, so that a fade-in from black is not the cover; a very short clip gives its first frame.
      if (p.value.duration > const Duration(milliseconds: 1500)) {
        await p.seekTo(const Duration(milliseconds: 500));
      }
      if (mounted) setState(() => ready = true);
    } catch (_) {
      // No frame: the tile stays a plain gradient, and the player (and its place among the few) is given back.
      if (!mounted) return;
      final failed = player;
      player = null;
      if (counted) VideoTile._covers--;
      counted = false;
      unawaited(failed?.dispose());
      setState(() => ready = false);
    }
  }

  @override
  void dispose() {
    if (counted) VideoTile._covers--;
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = player, colors = VideoTile.gradientFor(widget.seed);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
              ),
            ),
            if (ready && p != null && p.value.isInitialized)
              ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: p.value.size.width,
                    height: p.value.size.height,
                    child: VideoPlayer(p),
                  ),
                ),
              ),
            Center(
              child: Icon(
                Icons.play_circle_filled,
                size: 44,
                color: Colors.white.withValues(alpha: .9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef ImageProviderFactory = ImageProvider Function(
  Uri uri,
  Map<String, String>? headers,
);

/// A picture of the person's server (with the sign-in it needs), as the chat shows it: at most [maxWidth] wide, its shape
/// kept between 0.25 and 1.6 high for each wide, rounded corners, a quarter of a second of fade when it arrives, a place
/// 120 high while it loads, and a line to touch to try again when it did not (MessageBlocks.swift PictureBlockView).
///
/// With [framed] off it is the bare picture, filling what it is given (the full-screen viewer).
class AuthenticatedImage extends StatefulWidget {
  const AuthenticatedImage({
    super.key,
    required this.controller,
    required this.url,
    this.fit = BoxFit.contain,
    this.thumbnail = true,
    this.alt = '',
    this.maxWidth = 480,
    this.framed = true,
    this.retryable = true,
    this.opensViewer = true,
    this.providerFactory,
  });
  final JarvisController controller;
  final String url;
  final BoxFit fit;
  final bool thumbnail;

  /// What the picture is of, for screen readers ("图片" when empty).
  final String alt;
  final double maxWidth;
  final bool framed;

  /// A touch on the failure line loads the picture again.
  final bool retryable;

  /// A touch on a loaded picture opens it full screen.
  final bool opensViewer;
  @visibleForTesting
  final ImageProviderFactory? providerFactory;
  @override
  State<AuthenticatedImage> createState() => _AuthenticatedImageState();
}

class _AuthenticatedImageState extends State<AuthenticatedImage> {
  ImageProvider? provider;
  ImageStream? stream;
  ImageStreamListener? listener;
  double? ratio;
  bool failed = false, invalid = false, resolving = false;

  @override
  void initState() {
    super.initState();
    resolve();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.thumbnail != widget.thumbnail ||
        !identical(old.controller, widget.controller)) {
      resolve();
    }
  }

  @override
  void dispose() {
    release();
    super.dispose();
  }

  void release() {
    if (listener != null) stream?.removeListener(listener!);
    stream = null;
    listener = null;
  }

  void resolve() {
    release();
    ratio = null;
    failed = invalid = false;
    final Uri uri;
    try {
      uri = widget.controller.api.mediaUri(widget.url);
    } catch (_) {
      invalid = true;
      return;
    }
    final headers = uri.origin == widget.controller.api.endpoint.origin
        ? widget.controller.api.mediaHeaders
        : null;
    final base =
        widget.providerFactory?.call(uri, headers) ??
        NetworkImage(uri.toString(), headers: headers);
    provider = widget.thumbnail
        ? ResizeImage(
            base,
            width: 1024,
            height: 1024,
            policy: ResizeImagePolicy.fit,
          )
        : base;
    void settle(VoidCallback change) {
      if (resolving) {
        change();
      } else if (mounted) {
        setState(change);
      }
    }

    resolving = true;
    final next = ImageStreamListener(
      (info, _) => settle(
        () => ratio = info.image.height / math.max(1, info.image.width),
      ),
      onError: (_, _) => settle(() => failed = true),
    );
    stream = provider!.resolve(ImageConfiguration.empty)..addListener(next);
    listener = next;
    resolving = false;
  }

  void retry() {
    final old = provider;
    if (old != null) unawaited(old.evict());
    setState(resolve);
  }

  void openViewer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaPreview(
          controller: widget.controller,
          kind: 'image',
          url: widget.url,
          prompt: widget.alt,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    if (invalid) {
      return const SizedBox(height: 80, child: Center(child: Text('图片地址不可用')));
    }
    final label = widget.alt.isEmpty ? '图片' : widget.alt;
    final loaded = ratio != null && !failed;
    Widget body;
    if (failed && !widget.framed) {
      // The viewer says so and leaves the touch to its own gestures (it is closed and opened again to ask once more).
      body = const Center(
        child: Text(
          '图片无法载入',
          style: TextStyle(fontSize: 15, color: Colors.white70),
        ),
      );
    } else if (failed) {
      body = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.retryable ? retry : null,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '图片暂时无法加载，点按重试',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: palette.onSurfaceVariant),
            ),
          ),
        ),
      );
    } else if (loaded) {
      body = TweenAnimationBuilder<double>(
        key: ValueKey(provider),
        tween: Tween(begin: 0, end: 1),
        duration: motion(context, 250),
        builder: (context, value, child) =>
            Opacity(opacity: value, child: child),
        child: Image(
          image: provider!,
          fit: widget.fit,
          width: double.infinity,
          height: double.infinity,
          semanticLabel: label,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
      if (widget.framed && widget.opensViewer) {
        body = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: openViewer,
          child: body,
        );
      }
    } else {
      body = const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (!widget.framed) return SizedBox.expand(child: body);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.maxWidth;
        final width = math.min(widget.maxWidth, room);
        final height = loaded ? width * ratio!.clamp(.25, 1.6) : 120.0;
        return Semantics(
          image: true,
          label: label,
          button: loaded && widget.opensViewer,
          excludeSemantics: loaded,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: body,
            ),
          ),
        );
      },
    );
  }
}

/// The full-screen viewer (NativeWorks.swift PictureViewer): on black, with the buttons floating over it; a tap hides and
/// shows them, a double tap zooms in and out, pinching zooms from 1 to 6, and a drag down at rest takes the picture away.
/// A video plays at once.
class MediaPreview extends StatefulWidget {
  const MediaPreview({
    super.key,
    required this.controller,
    required this.kind,
    required this.url,
    required this.prompt,
  });
  final JarvisController controller;
  final String kind, url, prompt;
  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? player;
  String? error;
  bool saving = false, chrome = true;
  final zoom = TransformationController();
  late final AnimationController settle = AnimationController(vsync: this);
  VoidCallback? tick;
  Offset drag = Offset.zero, dragged = Offset.zero, doubleTapAt = Offset.zero;
  bool pinching = false;

  @override
  void initState() {
    super.initState();
    if (widget.kind == 'video') unawaited(load());
  }

  Future<void> load() async {
    try {
      final uri = widget.controller.api.mediaUri(widget.url);
      final p = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: uri.origin == widget.controller.api.endpoint.origin
            ? widget.controller.api.mediaHeaders
            : {},
      );
      player = p;
      await p.initialize();
      if (!mounted) {
        await p.dispose();
        return;
      }
      setState(() {});
      await p.play();
    } catch (_) {
      if (mounted) setState(() => error = '视频暂时无法播放，请检查连接后重试');
    }
  }

  @override
  void dispose() {
    settle.dispose();
    zoom.dispose();
    player?.dispose();
    super.dispose();
  }

  Future<void> save(bool share) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final bytes = await widget.controller.api.download(widget.url);
      if (!mounted) return;
      final type = _mediaType(bytes, widget.kind);
      final name =
              'jarvis-${DateTime.now().millisecondsSinceEpoch}.${type.extension}',
          mime = type.mime;
      if (share) {
        await NativeFiles.share(bytes, name, mime);
      } else {
        await NativeFiles.save(bytes, name, mime);
      }
    } catch (_) {
      if (mounted) showNotice(context, '文件未能保存，请检查网络后重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Runs [apply] from 0 to 1 over a quarter of a second (a new run replaces one that is under way).
  void animate(void Function(double t) apply) {
    if (tick != null) settle.removeListener(tick!);
    tick = () => apply(Curves.easeOutCubic.transform(settle.value));
    settle.addListener(tick!);
    settle.duration = motion(context, 250);
    settle.forward(from: 0);
  }

  /// Zoomed in: back to the whole picture; at rest: in on the place that was touched.
  void toggleZoom() {
    final from = zoom.value.clone();
    final Matrix4 to;
    if (from.getMaxScaleOnAxis() > 1.01) {
      to = Matrix4.identity();
    } else {
      const scale = 2.5;
      final p = doubleTapAt;
      to = Matrix4.identity()
        ..translateByDouble(-p.dx * (scale - 1), -p.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    final tween = Matrix4Tween(begin: from, end: to);
    animate((t) => zoom.value = tween.transform(t));
  }

  void interactionStart(ScaleStartDetails details) {
    if (tick != null) settle.stop();
    pinching = details.pointerCount > 1;
    dragged = Offset.zero;
  }

  void interactionUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) pinching = true;
    if (pinching || zoom.value.getMaxScaleOnAxis() > 1.01) return;
    dragged += details.focalPointDelta;
    // Only a mostly vertical drag takes the picture away.
    if (drag != Offset.zero || dragged.dy.abs() > dragged.dx.abs() * 1.2) {
      setState(() => drag = Offset(0, dragged.dy));
    }
  }

  void interactionEnd(ScaleEndDetails details) {
    pinching = false;
    if (drag == Offset.zero) return;
    final speed = details.velocity.pixelsPerSecond.dy;
    if (drag.dy.abs() > 120 || speed.abs() > 900) {
      Navigator.of(context).maybePop();
      return;
    }
    final from = drag;
    animate((t) => setState(() => drag = Offset.lerp(from, Offset.zero, t)!));
  }

  Widget fading(Widget child) => IgnorePointer(
    ignoring: !chrome,
    child: AnimatedOpacity(
      opacity: chrome ? 1 : 0,
      duration: motion(context, 200),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    // Always dark, as the iOS viewer is, whatever the theme of the app.
    final dark = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        onSurface: const Color(0xffededf1),
        onSurfaceVariant: const Color(0xffa1a1aa),
      ),
    );
    final video = widget.kind == 'video';
    final ready = player?.value.isInitialized == true;
    return Theme(
      data: dark,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: fading(
              AppBar(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                foregroundColor: Colors.white,
                elevation: 0,
                scrolledUnderElevation: 0,
                leading: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
                actions: [
                  IconButton(
                    tooltip: '复制提示词',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: widget.prompt)),
                    icon: const Icon(Icons.copy_outlined),
                  ),
                  IconButton(
                    tooltip: '分享',
                    onPressed: saving ? null : () => save(true),
                    icon: const Icon(Icons.share_outlined),
                  ),
                  IconButton(
                    tooltip: '下载',
                    onPressed: saving ? null : () => save(false),
                    icon: const Icon(Icons.download_outlined),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final voice = widget.controller.voice;
              if (!voice.active) return const SizedBox.shrink();
              return SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(color: Color(0xffededf1)),
                    child: IconTheme.merge(
                      data: const IconThemeData(color: Color(0xffa1a1aa)),
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
                              voice.ready ? '语音通话中' : voice.status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: '打断回复',
                            color: const Color(0xffa1a1aa),
                            onPressed: () => voice.interrupt(
                              source: 'reply_interrupt_button',
                            ),
                            icon: const Icon(
                              Icons.stop_circle_outlined,
                              size: 20,
                            ),
                          ),
                          IconButton(
                            tooltip: '返回语音界面',
                            color: const Color(0xffa1a1aa),
                            onPressed: () {
                              final previewRoute = ModalRoute.of(context);
                              Navigator.of(context).popUntil(
                                (route) =>
                                    route.isFirst ||
                                    (route != previewRoute &&
                                        route.settings.name !=
                                            voiceWorksRouteName),
                              );
                              voice.expand();
                            },
                            icon: const Icon(Icons.open_in_full, size: 18),
                          ),
                          HangupButton(onPressed: voice.stop),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                )
              else if (!video)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => chrome = !chrome),
                  onDoubleTapDown: (d) => doubleTapAt = d.localPosition,
                  onDoubleTap: toggleZoom,
                  child: Transform.translate(
                    offset: drag,
                    child: InteractiveViewer(
                      transformationController: zoom,
                      minScale: 1,
                      maxScale: 6,
                      onInteractionStart: interactionStart,
                      onInteractionUpdate: interactionUpdate,
                      onInteractionEnd: interactionEnd,
                      child: AuthenticatedImage(
                        controller: widget.controller,
                        url: widget.url,
                        thumbnail: false,
                        framed: false,
                        alt: widget.prompt,
                      ),
                    ),
                  ),
                )
              else if (ready)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => chrome = !chrome),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: player!.value.aspectRatio,
                      child: VideoPlayer(player!),
                    ),
                  ),
                )
              else
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              if (video && ready)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: fading(
                    SafeArea(
                      top: false,
                      child: ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: player!,
                        builder: (context, value, _) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            VideoProgressIndicator(
                              player!,
                              allowScrubbing: true,
                              colors: const VideoProgressColors(
                                playedColor: Colors.white,
                                bufferedColor: Colors.white30,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: value.isPlaying ? '暂停' : '播放',
                                  color: Colors.white,
                                  onPressed: () => value.isPlaying
                                      ? player!.pause()
                                      : player!.play(),
                                  icon: Icon(
                                    value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                ),
                                Text(
                                  '${value.position.inSeconds} / ${value.duration.inSeconds} 秒',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line of text kept to one line by cutting out the middle ("report-fi…2024.pdf"), so that the end of a file name (its
/// kind) stays readable.
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  /// [text] cut in the middle until it is no wider than [maxWidth] under [style].
  static String fit(
    String text,
    TextStyle? style,
    double maxWidth,
    TextDirection direction,
    TextScaler scaler,
  ) {
    double measure(String value) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    if (measure(text) <= maxWidth) return text;
    final chars = text.characters.toList();
    String cut(int kept) {
      final head = (kept + 1) ~/ 2, tail = kept ~/ 2;
      return '${chars.take(head).join()}…${chars.skip(chars.length - tail).join()}';
    }

    var low = 0, high = chars.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (measure(cut(mid)) <= maxWidth) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return cut(low);
  }

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => Text(
        constraints.maxWidth.isFinite
            ? fit(text, effective, constraints.maxWidth, direction, scaler)
            : text,
        style: style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}

class AttachmentCard extends StatefulWidget {
  const AttachmentCard({
    super.key,
    required this.controller,
    required this.item,
    this.removable = false,
    this.expanded = false,
    this.onError,
    this.inMessage,
  });
  final JarvisController controller;
  final Attachment item;
  final bool removable, expanded;
  final ValueChanged<String>? onError;

  /// Drawn as a sent message shows it: a 96 point thumbnail, or a pill with the file's name. By default what is neither
  /// removable (the composer's chip) nor expanded (the list of selected files).
  final bool? inMessage;
  @override
  State<AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<AttachmentCard> {
  late final Future<Uint8List> bytes = widget.controller.blobs.get(
    widget.item.id,
  );
  Future<void> preview() async {
    if (widget.item.kind == 'document') {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(
            widget.item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: SingleChildScrollView(
            child: SelectableText(widget.item.text ?? '没有可预览文字'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    try {
      final data = await bytes;
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(title: Text(widget.item.name)),
            body: Center(child: InteractiveViewer(child: Image.memory(data))),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        if (widget.onError != null) {
          widget.onError!('附件无法读取，请重试');
        } else {
          showNotice(context, '附件无法读取，请重试');
        }
      }
    }
  }

  bool get inMessage =>
      widget.inMessage ?? (!widget.expanded && !widget.removable);

  @override
  Widget build(BuildContext context) {
    if (inMessage) return messageCard(context);
    if (!widget.expanded) return compactCard(context);
    final size = widget.item.size;
    final sizeLabel = size < 1024
        ? '$size B'
        : size < 1024 * 1024
        ? '${(size / 1024).toStringAsFixed(1)} KB'
        : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: preview,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                  child: Row(
                    children: [
                      Icon(
                        widget.item.kind == 'image'
                            ? Icons.image_outlined
                            : Icons.description_outlined,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${widget.item.mime} · $sizeLabel',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.removable)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton(
                  tooltip: '移除 ${widget.item.name}',
                  onPressed: () =>
                      widget.controller.removeAttachment(widget.item.id),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A sent attachment (MessageCells.swift AttachmentView): a picture is a 96 point thumbnail that opens full screen; a
  /// document is a pill of the tinted colour with its name cut in the middle, and nothing behind it.
  Widget messageCard(BuildContext context) {
    final palette = ChatPalette.of(context), item = widget.item;
    if (item.kind == 'image') {
      return Semantics(
        button: true,
        label: item.name,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: preview,
          child: SizedBox(
            width: 96,
            height: 96,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: palette.card,
                child: FutureBuilder<Uint8List>(
                  future: bytes,
                  builder: (context, snapshot) => snapshot.hasData
                      ? Image.memory(
                          snapshot.data!,
                          fit: BoxFit.cover,
                          width: 96,
                          height: 96,
                          cacheWidth: 288,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      label: item.name,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: ShapeDecoration(
            color: palette.containerHigh,
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                size: 14,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: MiddleEllipsisText(
                  item.name,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget compactCard(BuildContext context) => InputChip(
    deleteButtonTooltipMessage: '移除 ${widget.item.name}',
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 170),
      child: Text(
        widget.item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    avatar: Icon(
      widget.item.kind == 'image'
          ? Icons.image_outlined
          : Icons.description_outlined,
      size: 18,
    ),
    onDeleted: widget.removable
        ? () => widget.controller.removeAttachment(widget.item.id)
        : null,
    onPressed: preview,
  );
}

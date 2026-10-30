import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../model/media.dart';
import 'call_controls.dart';
import 'duo_layout.dart';
import 'duo_rail.dart';
import 'video_source.dart';
import '../state/attachments.dart';
import '../state/jarvis_controller.dart';
import 'motion.dart';
import 'design_tokens.dart';
import 'settings_widgets.dart' show showFoldDialog;

/// Places chat feedback above the composer and within the current chat pane.
class NoticeAnchor extends InheritedWidget {
  const NoticeAnchor({
    super.key,
    required this.pane,
    required this.composer,
    this.composerInset = 10,
    this.composerInsetRight,
    required super.child,
  });
  final GlobalKey pane, composer;

  /// The composer's own padding, so a compact notice lines up with the composer frame (10 by default). Half-folded the
  /// two sides differ: [composerInsetRight] is the right one (null: same as the left).
  final double composerInset;
  final double? composerInsetRight;

  @override
  InheritedElement createElement() => _NoticeAnchorElement(this);

  /// The anchor for [context]: its own, or else the chat's anchor on the same page. A notice raised from beside the chat
  /// column rather than inside it (the finished-works notice comes from an overlay over the whole page) still sits above
  /// the composer instead of falling back to the bottom edge, over the composer.
  static NoticeAnchor? _of(BuildContext context) {
    final own = context.dependOnInheritedWidgetOfExactType<NoticeAnchor>();
    if (own != null) return own;
    final route = ModalRoute.of(context);
    for (final element in _NoticeAnchorElement.live.reversed) {
      if (ModalRoute.of(element) == route) {
        return element.widget as NoticeAnchor;
      }
    }
    return null;
  }

  static EdgeInsets? margins(BuildContext context, {double? compactWidth}) {
    final anchor = _of(context);
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
    // A floating SnackBar wraps itself in a SafeArea, which takes the system side insets (the iPhone Duo vertical-bar
    // strip is 84pt) off a second time, squeezing the notice to a sliver. Leave that room out of the margins.
    // iOS only: Android's notice geometry is unchanged.
    final view = View.of(context);
    final side = Theme.of(context).platform == TargetPlatform.iOS
        ? EdgeInsets.fromViewPadding(view.padding, view.devicePixelRatio)
        : EdgeInsets.zero;
    EdgeInsets spaced(double left, double right, double bottom) =>
        EdgeInsets.fromLTRB(
          math.max(0.0, left - side.left),
          0,
          math.max(0.0, right - side.right),
          bottom,
        );
    final paneAt = pane.localToGlobal(Offset.zero);
    final composerAt = composer.localToGlobal(Offset.zero);
    final above = composerAt.dy - paneAt.dy;
    if (above < 52) return null;
    final gap = above < 80 ? 4.0 : 16.0;
    final bottom = pane.size.height - above + gap;
    if (compactWidth != null) {
      final inset = anchor!.composerInset;
      final left = composerAt.dx + inset;
      final width = math.min(
        compactWidth,
        math.max(
          0.0,
          composer.size.width - inset - (anchor.composerInsetRight ?? inset),
        ),
      );
      return spaced(left, math.max(0.0, screen.width - left - width), bottom);
    }
    // Half-folded the column keeps to one side of the crease and the notice with it, not the whole pane.
    final fold = DuoLayoutScope.of(context).verticalFold;
    if (fold != null &&
        fold.right > paneAt.dx &&
        fold.left < paneAt.dx + pane.size.width &&
        (fold.right <= composerAt.dx ||
            fold.left >= composerAt.dx + composer.size.width)) {
      final left = composerAt.dx + anchor!.composerInset;
      final right =
          screen.width -
          composerAt.dx -
          composer.size.width +
          (anchor.composerInsetRight ?? anchor.composerInset);
      return spaced(left, right.clamp(0, screen.width), bottom);
    }
    return spaced(
      paneAt.dx + 16,
      (screen.width - paneAt.dx - pane.size.width + 16).clamp(0, screen.width),
      bottom,
    );
  }

  @override
  bool updateShouldNotify(NoticeAnchor oldWidget) =>
      pane != oldWidget.pane ||
      composer != oldWidget.composer ||
      composerInset != oldWidget.composerInset ||
      composerInsetRight != oldWidget.composerInsetRight;
}

/// Keeps track of the anchors on screen, for [NoticeAnchor._of].
class _NoticeAnchorElement extends InheritedElement {
  _NoticeAnchorElement(NoticeAnchor super.widget);
  static final live = <_NoticeAnchorElement>[];

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    live.add(this);
  }

  @override
  void unmount() {
    live.remove(this);
    super.unmount();
  }
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

enum SaveResult { saved, denied, failed, other }

/// Opens the app's page in the system Settings, where iOS can: its 'app-settings:' scheme. Elsewhere null: the caller
/// injects a native opener or offers no button.
Future<void> Function()? get defaultSettingsOpener =>
    defaultTargetPlatform == TargetPlatform.iOS ? _openIosSettings : null;

Future<void> _openIosSettings() async {
  await launchUrl(Uri.parse('app-settings:'));
}

/// Download: on iOS a picture or video goes straight into the Photos album; elsewhere the usual save-to-file flow.
Future<SaveResult> downloadMedia(
  Uint8List bytes,
  String name,
  String mime,
) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) {
    await NativeFiles.save(bytes, name, mime);
    return SaveResult.other;
  }
  try {
    await NativeFiles.saveToPhotos(bytes, name, mime);
    return SaveResult.saved;
  } on PlatformException catch (e) {
    return e.code == 'photos_denied' ? SaveResult.denied : SaveResult.failed;
  }
}

/// The download button reports its own outcome in place (spinner, then a check) instead of a banner over the page.
class SaveAction extends StatefulWidget {
  const SaveAction({
    super.key,
    required this.save,
    this.compact = false,
    this.label = '下载',
    this.openSettings,
  });
  final Future<SaveResult> Function() save;

  /// Icon-only, for the preview's app bar.
  final bool compact;

  /// What the idle button says ("全部保存" for a task with several pictures).
  final String label;

  /// Opens the app's Settings page; the button turns into this once the photo library has been refused (the system
  /// never asks twice). Null falls back to [defaultSettingsOpener].
  final Future<void> Function()? openSettings;
  @override
  State<SaveAction> createState() => _SaveActionState();
}

class _SaveActionState extends State<SaveAction> {
  bool busy = false;
  SaveResult? shown;
  Timer? timer;

  Future<void> run() async {
    if (busy) return;
    timer?.cancel();
    if (shown == SaveResult.denied) {
      // The refusal is final until the user changes it in Settings: go there instead of asking again.
      final opener = widget.openSettings ?? defaultSettingsOpener;
      if (opener != null) {
        setState(() => shown = null);
        try {
          await opener();
        } catch (_) {
          // Settings stay one tap away in the system; nothing more to do here.
        }
        return;
      }
    }
    setState(() {
      busy = true;
      shown = null;
    });
    SaveResult result;
    try {
      result = await widget.save();
    } catch (_) {
      result = SaveResult.failed;
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      shown = result == SaveResult.other ? null : result;
    });
    // A refusal stays long enough to read and act on.
    timer = Timer(
      Duration(milliseconds: result == SaveResult.denied ? 9000 : 2200),
      () {
        if (mounted) setState(() => shown = null);
      },
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label, Color? color) = busy
        ? (Icons.hourglass_empty, '保存中', null)
        : switch (shown) {
            SaveResult.saved => (
              Icons.check_circle_outline,
              '已保存到相册',
              scheme.primary,
            ),
            SaveResult.denied => (
              Icons.settings_outlined,
              (widget.openSettings ?? defaultSettingsOpener) != null
                  ? '去设置开启相册权限'
                  : '需要相册权限',
              scheme.error,
            ),
            SaveResult.failed => (Icons.error_outline, '保存失败', scheme.error),
            _ => (Icons.download_outlined, widget.label, null),
          };
    final glyph = busy
        ? const JarvisSpinner.button()
        : Icon(icon, size: widget.compact ? 24 : 18, color: color);
    Widget fade(Widget child) => AnimatedSwitcher(
      duration: motion(context, 180),
      child: KeyedSubtree(key: ValueKey('$busy-$shown'), child: child),
    );
    if (widget.compact) {
      return IconButton(
        tooltip: label,
        onPressed: busy ? null : run,
        icon: fade(glyph),
      );
    }
    return TextButton(
      onPressed: busy ? null : run,
      style: _cardActionStyle(context, color),
      child: fade(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            glyph,
            const SizedBox(width: 8),
            // The label grows with the text size ("去设置开启相册权限"): it wraps instead of overflowing the row.
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: color == null ? null : TextStyle(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Copies [text] and confirms in place, like the code block's copy button: [builder] gets `copied` (true for a moment)
/// and the callback that copies.
class CopyFeedback extends StatefulWidget {
  const CopyFeedback({super.key, required this.text, required this.builder});
  final String text;
  final Widget Function(BuildContext context, bool copied, VoidCallback copy)
  builder;
  @override
  State<CopyFeedback> createState() => _CopyFeedbackState();
}

class _CopyFeedbackState extends State<CopyFeedback> {
  bool copied = false;
  Timer? timer;

  void copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
    unawaited(HapticFeedback.selectionClick());
    setState(() => copied = true);
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => copied = false);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, copied, copy);
}

ButtonStyle _cardActionStyle(BuildContext context, [Color? color]) =>
    TextButton.styleFrom(
      foregroundColor: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: Theme.of(context).textTheme.labelLarge,
    );

/// Saves every result of [task]: a picture task can have several. Stops at the first refusal or failure.
Future<SaveResult> _saveResults(
  JarvisController controller,
  MediaTask task,
) async {
  var result = SaveResult.other;
  for (var i = 0; i < task.urls.length; i++) {
    final data = await controller.api.download(task.urls[i]);
    final type = _mediaType(data, task.kind);
    final suffix = task.urls.length > 1 ? '-${i + 1}' : '';
    result = await downloadMedia(
      data,
      'jarvis-${task.id}$suffix.${type.extension}',
      type.mime,
    );
    if (result == SaveResult.denied || result == SaveResult.failed) break;
  }
  return result;
}

class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.task,
    required this.controller,
    this.margin,
    this.onCancel,
    this.openSettings,
    this.heroes = true,
  });
  final MediaTask task;

  /// Whether a picture flies into the preview when opened (needs a tag no other card on the same page shares; a card
  /// shown twice at once, e.g. in a sheet over the page that carries it, turns this off).
  final bool heroes;
  final JarvisController controller;
  final EdgeInsetsGeometry? margin;

  /// Stops a pending task; the card offers "取消" only while one runs and this is given.
  final VoidCallback? onCancel;

  /// Opens the app's Settings page when the photo library was refused; see [SaveAction.openSettings].
  final Future<void> Function()? openSettings;
  @override
  Widget build(BuildContext context) => Card(
    margin: margin,
    clipBehavior: Clip.antiAlias,
    // A pending card grows into a finished one (pictures, buttons) without a jump.
    child: SmoothSize(
      milliseconds: 250,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (task.status == 'completed' && task.urls.isNotEmpty)
            for (var i = 0; i < task.urls.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              _result(context, task.urls[i], i),
            ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.prompt.isEmpty
                      ? (task.kind == 'video' ? '视频任务' : '图片任务')
                      : task.prompt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (task.pending) ...[
                  const SizedBox(height: 8),
                  // Each report moves the bar on rather than jumping.
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: task.progress / 100),
                    duration: motion(context, 400),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: task.progress > 0 ? value : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '后台生成中${task.progress > 0 ? ' · ${task.progress.round()}%' : ''}，可以继续对话',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (task.error != null)
                  Text(
                    task.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          // The buttons' own 12 pt padding puts the first icon on the 16 pt text column above.
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Wrap(
              spacing: 4,
              children: [
                CopyFeedback(
                  text: task.prompt,
                  builder: (context, copied, copy) => _CardAction(
                    icon: copied ? Icons.check_rounded : Icons.copy_outlined,
                    label: copied ? '已复制' : '复制提示词',
                    onPressed: task.prompt.isEmpty ? null : copy,
                  ),
                ),
                if (task.status == 'completed' && task.urls.isNotEmpty)
                  SaveAction(
                    label: task.urls.length > 1 ? '全部保存' : '下载',
                    openSettings: openSettings,
                    save: () => _saveResults(controller, task),
                  ),
                if (task.pending && onCancel != null)
                  _CardAction(
                    icon: Icons.close,
                    label: '取消',
                    onPressed: onCancel,
                  ),
                if (!task.pending && task.status != 'completed')
                  _CardAction(
                    icon: Icons.refresh,
                    label: '重试',
                    onPressed: () => controller.retryMedia(task),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// One finished picture or video: a button that opens the full preview.
  Widget _result(BuildContext context, String url, int index) {
    final video = task.kind == 'video';
    final label = task.prompt.isEmpty
        ? (video ? '播放视频' : '查看图片')
        : (video ? '播放视频：${task.prompt}' : task.prompt);
    final tag = heroes && !video ? 'media-${task.id}-$index' : null;
    void open() => unawaited(
      openMediaPreview(
        context,
        controller: controller,
        kind: task.kind,
        url: url,
        prompt: task.prompt,
        heroTag: tag,
      ),
    );
    return Semantics(
      button: true,
      label: label,
      onTap: open,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('open-$url'),
        onTap: open,
        child: video
            ? VideoCover(
                key: ValueKey('cover-$url'),
                prompt: task.prompt,
                seed: task.id,
              )
            : tag == null
            ? AuthenticatedImage(
                controller: controller,
                url: url,
                fit: BoxFit.contain,
              )
            : Hero(
                tag: tag,
                // Both ends fly as the (already decoded) thumbnail.
                flightShuttleBuilder: (_, _, _, _, _) =>
                    AuthenticatedImage(controller: controller, url: url),
                child: AuthenticatedImage(
                  controller: controller,
                  url: url,
                  fit: BoxFit.contain,
                ),
              ),
      ),
    );
  }
}

/// Opens the full-screen preview of a picture or video with a short fade (the picture flies in when [heroTag] is the
/// tag of the [Hero] it came from).
Future<void> openMediaPreview(
  BuildContext context, {
  required JarvisController controller,
  required String kind,
  required String url,
  required String prompt,
  String? heroTag,
}) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    settings: const RouteSettings(name: 'media-preview'),
    transitionDuration: motion(context, 200),
    reverseTransitionDuration: motion(context, 200),
    pageBuilder: (_, _, _) => MediaPreview(
      controller: controller,
      kind: kind,
      url: url,
      prompt: prompt,
      heroTag: heroTag,
    ),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class AuthenticatedImage extends StatefulWidget {
  const AuthenticatedImage({
    super.key,
    required this.controller,
    required this.url,
    this.fit = BoxFit.contain,
    this.thumbnail = true,
    this.semanticLabel,
    this.animateSize = true,
    this.thumbnailUnderlay = false,
  });
  final JarvisController controller;
  final String url;
  final BoxFit fit;
  final bool thumbnail;

  /// Whether the box eases from the loading placeholder to the picture's size (a list needs it; a full-screen viewer
  /// does not).
  final bool animateSize;

  /// For the full picture ([thumbnail] false): the thumbnail the cards already decoded is shown at once and the
  /// picture fades in over it.
  final bool thumbnailUnderlay;

  /// What the picture shows, for screen readers (the markdown alt text).
  final String? semanticLabel;
  @override
  State<AuthenticatedImage> createState() => _AuthenticatedImageState();
}

class _AuthenticatedImageState extends State<AuthenticatedImage> {
  /// Bumped by a tap on the failure message: a fresh [Image] asks for the picture again.
  int attempt = 0;

  ImageProvider? provider({bool? thumbnail}) {
    final api = widget.controller.api;
    Uri uri;
    try {
      uri = api.mediaUri(widget.url);
    } catch (_) {
      return null;
    }
    final network = NetworkImage(
      uri.toString(),
      headers: uri.origin == api.endpoint.origin ? api.mediaHeaders : null,
    );
    return (thumbnail ?? widget.thumbnail)
        ? ResizeImage(
            network,
            width: 1024,
            height: 1024,
            policy: ResizeImagePolicy.fit,
          )
        : network;
  }

  void retry(ImageProvider image) {
    unawaited(image.evict());
    setState(() => attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final image = provider();
    if (image == null) {
      return const SizedBox(height: 80, child: Center(child: Text('图片地址不可用')));
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final underlay = widget.thumbnailUnderlay && !widget.thumbnail;
    Widget picture = Image(
      key: ValueKey(attempt),
      image: image,
      fit: widget.fit,
      semanticLabel: widget.semanticLabel,
      loadingBuilder: (context, child, loading) => loading == null
          ? child
          // Over a thumbnail the picture simply is not there yet; otherwise a ring holds the place.
          : underlay
          ? const SizedBox.shrink()
          : const SizedBox(
              height: 120,
              child: Center(child: JarvisSpinner.page()),
            ),
      frameBuilder: (context, child, frame, synchronous) => synchronous
          ? child
          : AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: motion(context, 250),
              curve: Curves.easeOut,
              child: child,
            ),
      errorBuilder: (context, _, _) => Semantics(
        button: true,
        label: '图片暂时无法加载，点按重试',
        excludeSemantics: true,
        onTap: () => retry(image),
        child: InkWell(
          key: const Key('image-retry'),
          onTap: () => retry(image),
          // At least a thumb's height; the message may take two lines at a large text size.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 96),
            child: Padding(
              padding: const EdgeInsets.all(12),
              // heightFactor: the button is as tall as its message even in a page-sized box (the preview).
              child: Center(
                heightFactor: 1,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined, size: 28, color: muted),
                    const SizedBox(height: 6),
                    Text(
                      '图片暂时无法加载，点按重试',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (underlay) {
      final thumb = provider(thumbnail: true);
      if (thumb != null) {
        picture = Stack(
          alignment: Alignment.center,
          children: [
            Image(
              image: thumb,
              fit: widget.fit,
              excludeFromSemantics: true,
              loadingBuilder: (context, child, loading) => loading == null
                  ? child
                  : const SizedBox(
                      height: 120,
                      child: Center(child: JarvisSpinner.page()),
                    ),
              errorBuilder: (context, _, _) => const SizedBox.shrink(),
            ),
            picture,
          ],
        );
      }
    }
    return widget.animateSize
        ? SmoothSize(
            milliseconds: 250,
            alignment: Alignment.topCenter,
            child: picture,
          )
        : picture;
  }
}

class MediaPreview extends StatefulWidget {
  const MediaPreview({
    super.key,
    required this.controller,
    required this.kind,
    required this.url,
    required this.prompt,
    this.heroTag,
  });
  final JarvisController controller;
  final String kind, url, prompt;

  /// The tag of the card's [Hero] this picture flies out of; null: no flight.
  final String? heroTag;
  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? player;
  String? error;
  bool saving = false;

  /// The bars over the picture; a tap on it hides or shows them. A playing video hides them by itself after
  /// [_controlsTimeout].
  bool controls = true;
  Timer? hideTimer;
  bool wasPlaying = false;
  static const _controlsTimeout = Duration(seconds: 3);
  final zoom = TransformationController();

  /// Drives the double tap's zoom (220 ms).
  late final AnimationController zoomMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final Animation<double> zoomCurve = CurvedAnimation(
    parent: zoomMotion,
    curve: Curves.easeOutCubic,
  );
  Matrix4Tween? zoomTween;

  /// The picture's viewer is as big as the picture and centred in the page, so the double tap (a position on the whole
  /// page) is turned into the viewer's own coordinates through this key.
  final viewerKey = GlobalKey(debugLabel: 'preview-viewer');

  /// Where the last double tap landed, on screen.
  Offset? doubleTapAt;
  @override
  void initState() {
    super.initState();
    zoomMotion.addListener(() {
      final tween = zoomTween;
      if (tween != null) zoom.value = tween.evaluate(zoomCurve);
    });
    if (widget.kind == 'video') unawaited(load());
  }

  Future<void> load() async {
    try {
      final p = await openVideo(widget.controller, widget.url);
      if (!mounted) {
        await p.dispose();
        return;
      }
      player = p;
      await p.initialize();
      if (!mounted) {
        await p.dispose();
        return;
      }
      p.addListener(playingChanged);
      setState(() {});
      await p.play();
    } catch (_) {
      if (mounted) setState(() => error = '视频暂时无法播放，请检查连接后重试');
    }
  }

  /// Playing starts the countdown to hiding the bars; pausing (or the end) brings them back and keeps them.
  void playingChanged() {
    final playing = player?.value.isPlaying == true;
    if (playing == wasPlaying) return;
    wasPlaying = playing;
    if (playing) {
      armHide();
    } else {
      hideTimer?.cancel();
      if (mounted && !controls) setState(() => controls = true);
    }
  }

  void armHide() {
    hideTimer?.cancel();
    if (widget.kind != 'video' ||
        !controls ||
        player?.value.isPlaying != true) {
      return;
    }
    hideTimer = Timer(_controlsTimeout, () {
      if (mounted && player?.value.isPlaying == true) {
        setState(() => controls = false);
      }
    });
  }

  void toggleControls() {
    setState(() => controls = !controls);
    if (controls) {
      armHide();
    } else {
      hideTimer?.cancel();
    }
  }

  void retry() {
    final old = player;
    setState(() {
      player = null;
      error = null;
    });
    unawaited(old?.dispose());
    unawaited(load());
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    player?.removeListener(playingChanged);
    player?.dispose();
    zoomMotion.dispose();
    zoom.dispose();
    super.dispose();
  }

  /// Moves the zoom to [target], gliding unless motion is reduced.
  void zoomTo(Matrix4 target) {
    zoomMotion.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      zoom.value = target;
      return;
    }
    zoomTween = Matrix4Tween(begin: zoom.value, end: target);
    unawaited(zoomMotion.forward(from: 0));
  }

  /// Double tap: in on the tapped point, or back out when already zoomed. A tap beside the picture zooms on its nearest
  /// edge, so the zoomed picture always fills the viewer.
  void toggleZoom() {
    if (zoom.value.getMaxScaleOnAxis() > 1.05) {
      zoomTo(Matrix4.identity());
      return;
    }
    final box = viewerKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    const scale = 2.5;
    final size = box.size;
    final local = box.globalToLocal(
      doubleTapAt ?? box.localToGlobal(size.center(Offset.zero)),
    );
    final at = Offset(
      local.dx.clamp(0.0, size.width),
      local.dy.clamp(0.0, size.height),
    );
    // The tapped point stays where it is; the translation never leaves [size * (1 - scale), 0], where the zoomed
    // picture still covers the whole viewer.
    zoomTo(
      Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
        (at.dx * (1 - scale)).clamp(size.width * (1 - scale), 0.0),
        (at.dy * (1 - scale)).clamp(size.height * (1 - scale), 0.0),
        0,
      ),
    );
  }

  Future<SaveResult> saveToAlbum() async {
    final bytes = await widget.controller.api.download(widget.url);
    final type = _mediaType(bytes, widget.kind);
    return downloadMedia(
      bytes,
      'jarvis-${DateTime.now().millisecondsSinceEpoch}.${type.extension}',
      type.mime,
    );
  }

  Future<void> share() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final bytes = await widget.controller.api.download(widget.url);
      final type = _mediaType(bytes, widget.kind);
      await NativeFiles.share(
        bytes,
        'jarvis-${DateTime.now().millisecondsSinceEpoch}.${type.extension}',
        type.mime,
      );
    } catch (_) {
      if (mounted) showNotice(context, '文件未能保存，请检查网络后重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Bars fade with the controls; hidden, they neither answer touches nor speak to VoiceOver.
  Widget bar({required Widget child, required bool top}) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    child: ExcludeSemantics(
      excluding: !controls,
      child: IgnorePointer(
        ignoring: !controls,
        // Touching a control starts the countdown again.
        child: Listener(
          onPointerDown: (_) => armHide(),
          child: AnimatedOpacity(
            opacity: controls ? 1 : 0,
            duration: motion(context, 180),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                  end: top ? Alignment.bottomCenter : Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: .6),
                    Colors.black.withValues(alpha: 0),
                  ],
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    // The picture sits on black, so the bars over it use the light-on-dark colours whatever the app theme is.
    final theme = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        onSurface: Colors.white,
        onSurfaceVariant: Colors.white,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      // Rings and bars on black are white: the light theme's teal nearly disappears there.
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.white,
        linearTrackColor: Colors.white24,
        circularTrackColor: Colors.transparent,
      ),
    );
    final video = widget.kind == 'video';
    final shortScreen = MediaQuery.sizeOf(context).height < 500;
    final ready = player?.value.isInitialized == true;
    final Widget media = error != null
        ? Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  key: const Key('video-retry'),
                  onPressed: retry,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(88, 44),
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          )
        : !video
        ? InteractiveViewer(
            key: viewerKey,
            transformationController: zoom,
            minScale: 1,
            maxScale: 6,
            // A pinch or drag takes over from a zoom that is still gliding.
            onInteractionStart: (_) => zoomMotion.stop(),
            child: Builder(
              builder: (context) {
                final picture = AuthenticatedImage(
                  controller: widget.controller,
                  url: widget.url,
                  thumbnail: false,
                  animateSize: false,
                  thumbnailUnderlay: true,
                );
                final tag = widget.heroTag;
                return tag == null
                    ? picture
                    : Hero(
                        tag: tag,
                        flightShuttleBuilder: (_, _, _, _, _) =>
                            AuthenticatedImage(
                              controller: widget.controller,
                              url: widget.url,
                              animateSize: false,
                            ),
                        child: picture,
                      );
              },
            ),
          )
        : ready
        ? AspectRatio(
            aspectRatio: player!.value.aspectRatio,
            child: VideoPlayer(player!),
          )
        : const JarvisSpinner.page();
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: Colors.black,
        bottomNavigationBar: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final voice = widget.controller.voice;
            if (!voice.active) return const SizedBox.shrink();
            return ColoredBox(
              color: Colors.black,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
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
                          voice.ready ? '语音通话中' : voice.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '打断回复',
                        onPressed: voice.interrupt,
                        icon: const Icon(Icons.stop_circle_outlined, size: 20),
                      ),
                      IconButton(
                        tooltip: '返回语音界面',
                        onPressed: () {
                          final previewRoute = ModalRoute.of(context);
                          Navigator.of(context).popUntil(
                            (route) =>
                                route.isFirst ||
                                (route != previewRoute &&
                                    route.settings.name != voiceWorksRouteName),
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
            );
          },
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: toggleControls,
                onDoubleTapDown: video
                    ? null
                    : (details) => doubleTapAt = details.globalPosition,
                onDoubleTap: video ? null : toggleZoom,
                child: Center(child: media),
              ),
            ),
            bar(
              top: true,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    const BackButton(),
                    Expanded(
                      child: Text(
                        video ? '视频' : '图片',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    CopyFeedback(
                      text: widget.prompt,
                      builder: (context, copied, copy) => IconButton(
                        tooltip: copied ? '已复制' : '复制提示词',
                        onPressed: copy,
                        icon: Icon(
                          copied ? Icons.check_rounded : Icons.copy_outlined,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '分享',
                      onPressed: saving ? null : share,
                      icon: const Icon(Icons.share_outlined),
                    ),
                    SaveAction(save: saveToAlbum, compact: true),
                  ],
                ),
              ),
            ),
            bar(
              top: false,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ready)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: player!,
                        builder: (context, value, _) => Column(
                          children: [
                            // The scrubbing area is the bar and its padding: 4 + 2 * 14 = 32 pt tall instead of a
                            // fingertip-missing 9.
                            VideoProgressIndicator(
                              player!,
                              allowScrubbing: true,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: value.isPlaying ? '暂停' : '播放',
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
                                  // Digits of one width: the time does not tremble as it counts.
                                  style: const TextStyle(
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Metrics.pageMargin,
                        shortScreen ? 4 : 8,
                        Metrics.pageMargin,
                        shortScreen ? 8 : 16,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.prompt,
                          maxLines: shortScreen ? 2 : 4,
                          overflow: TextOverflow.ellipsis,
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
    );
  }
}

/// A sent picture, full screen. On the iPhone Duo the back control stands in the right strip (like the other pages);
/// elsewhere the AppBar carries it.
class AttachmentImageViewer extends StatelessWidget {
  const AttachmentImageViewer({
    super.key,
    required this.name,
    required this.data,
  });
  final String name;
  final Uint8List data;

  @override
  Widget build(BuildContext context) {
    // The picture keeps to the content area: on the iPhone Duo the strip covers the right 84 pt, so a picture under it
    // would sit off-centre and pinches over the strip would go to its buttons. The strip's width is the side inset.
    final layout = DuoLayoutScope.of(context);
    return DuoRailPage(
      top: [DuoRailPage.back(context)],
      child: Scaffold(
        appBar: AppBar(
          title: Text(name),
          automaticallyImplyLeading: !DuoRailPage.active(context),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          minimum: EdgeInsets.only(
            left: layout.edge == DuoBarEdge.left ? layout.barWidth : 0,
            right: layout.edge == DuoBarEdge.right ? layout.barWidth : 0,
          ),
          child: Center(
            key: const Key('attachment-viewer-area'),
            child: InteractiveViewer(child: Image.memory(data)),
          ),
        ),
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
    this.preview = false,
  });
  final JarvisController controller;
  final Attachment item;
  final bool removable;

  /// In a sent message: a picture shows as a rounded thumbnail instead of a file-name chip.
  final bool preview;
  @override
  State<AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<AttachmentCard> {
  late final Future<Uint8List> bytes = widget.controller.blobs.get(
    widget.item.id,
  );

  Future<void> open(BuildContext context) async {
    if (widget.item.kind == 'document') {
      unawaited(
        showFoldDialog<void>(
          context: context,
          builder: (context, insets) => AlertDialog(
            insetPadding: insets,
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
        ),
      );
      return;
    }
    try {
      final data = await bytes;
      if (!context.mounted) return;
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'image'),
            builder: (_) =>
                AttachmentImageViewer(name: widget.item.name, data: data),
          ),
        ),
      );
    } catch (_) {
      if (context.mounted) showNotice(context, '附件无法读取');
    }
  }

  Widget chip(BuildContext context) => InputChip(
    label: ConstrainedBox(
      // A chip waiting in the composer is narrower, so the next one peeks in from the right on a phone. Its height is
      // at least the cross's: the chip's content is as tall as its tallest part.
      constraints: BoxConstraints(
        maxWidth: widget.removable ? 120 : 170,
        minHeight: widget.removable ? 44 : 0,
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          widget.item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
    // The cross is a 44 pt square for a finger; the chip's own vertical padding goes instead, so the whole chip is 44
    // tall and fits the composer's 48 pt row.
    deleteIconBoxConstraints: widget.removable
        ? const BoxConstraints(minWidth: 44, minHeight: 44)
        : null,
    padding: widget.removable
        ? const EdgeInsets.symmetric(horizontal: 8)
        : null,
    // The avatar's box would grow with the content to a 44 pt square.
    avatarBoxConstraints: widget.removable
        ? const BoxConstraints.tightFor(width: 24, height: 24)
        : null,
    deleteButtonTooltipMessage: '移除 ${widget.item.name}',
    onPressed: () => unawaited(open(context)),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.preview || widget.item.kind != 'image') return chip(context);
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        // Still reading: keep the thumbnail's square, so the message does not jump when the picture arrives.
        if (data == null && !snapshot.hasError) {
          return SizedBox.square(
            key: Key('attachment-thumb-loading-${widget.item.id}'),
            dimension: 112,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Radii.small),
              ),
            ),
          );
        }
        // The file is gone: the chip still names it.
        if (data == null) return chip(context);
        return Semantics(
          button: true,
          label: '图片 ${widget.item.name}',
          onTap: () => unawaited(open(context)),
          excludeSemantics: true,
          child: GestureDetector(
            key: Key('attachment-thumb-${widget.item.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(open(context)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.small),
              child: Image.memory(
                data,
                width: 112,
                height: 112,
                fit: BoxFit.cover,
                // Decoded at thumbnail size, not at the photo's.
                cacheWidth: 224,
                gaplessPlayback: true,
                errorBuilder: (context, _, _) => chip(context),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
    style: _cardActionStyle(context),
  );
}

/// A finished video's card face: no download happens until the preview opens. A dark gradient (its hue from [seed], so
/// cards differ) carries the prompt and a play badge; the full video (up to 256 MB on iOS) is fetched only on a tap.
class VideoCover extends StatelessWidget {
  const VideoCover({super.key, required this.prompt, required this.seed});
  final String prompt, seed;

  @override
  Widget build(BuildContext context) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              HSLColor.fromAHSL(1, hue, .45, .26).toColor(),
              HSLColor.fromAHSL(1, (hue + 40) % 360, .5, .12).toColor(),
            ],
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (prompt.isNotEmpty)
              Positioned(
                left: 14,
                right: 14,
                top: 12,
                child: Text(
                  prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .85),
                    fontSize: 13,
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: .45),
              ),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 40,
                  color: Colors.white,
                  semanticLabel: '播放视频',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

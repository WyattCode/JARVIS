import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../model/media.dart';
import 'call_controls.dart';
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

class MediaCard extends StatelessWidget {
  const MediaCard({super.key, required this.task, required this.controller});
  final MediaTask task;
  final JarvisController controller;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (task.status == 'completed' && task.urls.isNotEmpty)
          for (final url in task.urls)
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MediaPreview(
                    controller: controller,
                    kind: task.kind,
                    url: url,
                    prompt: task.prompt,
                  ),
                ),
              ),
              child: task.kind == 'image'
                  ? AuthenticatedImage(
                      controller: controller,
                      url: url,
                      fit: BoxFit.contain,
                    )
                  : SizedBox(
                      height: 150,
                      child: Center(
                        child: Icon(
                          Icons.play_circle_outline,
                          size: 52,
                          semanticLabel: '播放视频',
                        ),
                      ),
                    ),
            ),
        Padding(
          padding: const EdgeInsets.all(12),
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
                LinearProgressIndicator(
                  value: task.progress > 0 ? task.progress / 100 : null,
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Row(
                children: [
                  IconButton(
                    tooltip: '复制提示词',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: task.prompt)),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                  ),
                  const Spacer(),
                  if (!task.pending && task.status != 'completed')
                    TextButton.icon(
                      onPressed: () => controller.retryMedia(task),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  if (task.status == 'completed' && task.urls.isNotEmpty)
                    IconButton(
                      tooltip: '下载',
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () async {
                        try {
                          final data = await controller.api.download(
                            task.urls.first,
                          );
                          if (!context.mounted) return;
                          final type = _mediaType(data, task.kind);
                          await NativeFiles.save(
                            data,
                            'jarvis-${task.id}.${type.extension}',
                            type.mime,
                          );
                        } catch (_) {
                          if (context.mounted) showNotice(context, '下载失败，请重试');
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class AuthenticatedImage extends StatelessWidget {
  const AuthenticatedImage({
    super.key,
    required this.controller,
    required this.url,
    this.fit = BoxFit.contain,
    this.thumbnail = true,
  });
  final JarvisController controller;
  final String url;
  final BoxFit fit;
  final bool thumbnail;
  @override
  Widget build(BuildContext context) {
    Uri uri;
    try {
      uri = controller.api.mediaUri(url);
    } catch (_) {
      return const SizedBox(height: 80, child: Center(child: Text('图片地址不可用')));
    }
    final provider = NetworkImage(
      uri.toString(),
      headers: uri.origin == controller.api.endpoint.origin
          ? controller.api.mediaHeaders
          : null,
    );
    return Image(
      image: thumbnail
          ? ResizeImage(
              provider,
              width: 1024,
              height: 1024,
              policy: ResizeImagePolicy.fit,
            )
          : provider,
      fit: fit,
      loadingBuilder: (context, child, loading) => loading == null
          ? child
          : const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            ),
      errorBuilder: (_, _, _) =>
          const SizedBox(height: 80, child: Center(child: Text('图片暂时无法加载'))),
    );
  }
}

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

class _MediaPreviewState extends State<MediaPreview> {
  VideoPlayerController? player;
  String? error;
  bool saving = false;
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.kind == 'video' ? '视频' : '图片'),
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
    bottomNavigationBar: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final voice = widget.controller.voice;
        if (!voice.active) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(Icons.circle, size: 7, color: Color(0xff2d9f80)),
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
                  onPressed: () => voice.interrupt(source: 'reply_interrupt_button'),
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
        );
      },
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(error!, textAlign: TextAlign.center),
                    )
                  : widget.kind == 'image'
                  ? InteractiveViewer(
                      minScale: 1,
                      maxScale: 6,
                      child: AuthenticatedImage(
                        controller: widget.controller,
                        url: widget.url,
                        thumbnail: false,
                      ),
                    )
                  : player?.value.isInitialized == true
                  ? AspectRatio(
                      aspectRatio: player!.value.aspectRatio,
                      child: VideoPlayer(player!),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
          if (player?.value.isInitialized == true)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: player!,
              builder: (context, value, _) => Column(
                children: [
                  VideoProgressIndicator(player!, allowScrubbing: true),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: value.isPlaying ? '暂停' : '播放',
                        onPressed: () =>
                            value.isPlaying ? player!.pause() : player!.play(),
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      Text(
                        '${value.position.inSeconds} / ${value.duration.inSeconds} 秒',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.prompt,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class AttachmentCard extends StatefulWidget {
  const AttachmentCard({
    super.key,
    required this.controller,
    required this.item,
    this.removable = false,
    this.expanded = false,
    this.onError,
  });
  final JarvisController controller;
  final Attachment item;
  final bool removable, expanded;
  final ValueChanged<String>? onError;
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

  @override
  Widget build(BuildContext context) {
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

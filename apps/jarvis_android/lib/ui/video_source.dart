import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../state/jarvis_controller.dart';

/// One download per video; it starts when first needed.
class _Download {
  _Download(this._job);
  final Future<File> Function() _job;
  Future<File>? _started;
  File? file;
  Future<File> start() => _started ??= _job().then((f) => file = f);
}

/// Most recently opened first-in, oldest first-out: [_files] keeps insertion order.
final _files = <String, _Download>{};
Future<Directory>? _folder;

/// Downloaded videos kept on disk at once. A video is only fetched when the user opens it, so a couple of recent ones are
/// enough for replaying; older files are deleted instead of piling up in tmp (a video can be 256 MB).
const _keptVideos = 2;

/// iOS's AVPlayer drops the login Cookie on its own requests and needs byte-range responses, so there the
/// authenticated video is fetched by the app's own client once, played from the file, and the file is dropped again once
/// newer videos have been opened (or on [clearVideoCache]). Task cards do not call this: their covers are placeholders.
Future<VideoPlayerController> openVideo(
  JarvisController controller,
  String url,
) async {
  final api = controller.api;
  if (defaultTargetPlatform != TargetPlatform.iOS) {
    final uri = api.mediaUri(url);
    return VideoPlayerController.networkUrl(
      uri,
      httpHeaders: uri.origin == api.endpoint.origin ? api.mediaHeaders : {},
    );
  }
  final key = '${api.endpoint.origin}|$url';
  // Re-inserted, so it counts as the newest.
  final download =
      _files.remove(key) ?? _Download(() => _fetch(controller, url));
  _files[key] = download;
  try {
    final file = await download.start();
    _trim(keep: key);
    return VideoPlayerController.file(file);
  } catch (_) {
    _files.remove(key);
    rethrow;
  }
}

void _trim({required String keep}) {
  final done = _files.entries.where((e) => e.value.file != null).toList();
  var excess = done.length - _keptVideos;
  for (final entry in done) {
    if (excess <= 0) break;
    if (entry.key == keep) continue;
    excess--;
    _files.remove(entry.key);
    _delete(entry.value.file);
  }
}

void _delete(File? file) {
  if (file == null) return;
  try {
    file.deleteSync();
  } catch (_) {
    // Already gone, or in use by a player that is closing: the next launch clears the folder anyway.
  }
}

/// Deletes every downloaded video (sign-out, leaving the chat).
Future<void> clearVideoCache() async {
  for (final download in _files.values) {
    _delete(download.file);
  }
  _files.clear();
  final folder = _folder;
  _folder = null;
  if (folder == null) return;
  try {
    final dir = await folder;
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // Best effort.
  }
}

Future<File> _fetch(JarvisController controller, String url) async {
  final folder = await (_folder ??= _freshFolder());
  final file = File(
    '${folder.path}/${DateTime.now().microsecondsSinceEpoch}.mp4',
  );
  // Streamed to disk: the video is never held in memory whole.
  await controller.api.downloadTo(url, file);
  return file;
}

Future<Directory> _freshFolder() async {
  final folder = Directory('${Directory.systemTemp.path}/jarvis-video');
  if (await folder.exists()) await folder.delete(recursive: true);
  return folder.create(recursive: true);
}

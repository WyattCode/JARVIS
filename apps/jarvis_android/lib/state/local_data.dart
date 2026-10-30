import 'dart:io';

import 'package:flutter/foundation.dart';

/// Temp sub-folders this app fills with media it can fetch again: played videos (lib/ui/video_source.dart), staged
/// downloads and backup parts. None of it is user data; it goes when the user signs out.
const cachedMediaFolders = ['jarvis-video', 'jarvis-transfer', 'jarvis-backup'];

/// Tests point this at a folder of their own.
@visibleForTesting
Directory? debugTempRoot;

/// Off under `flutter test`: tests start several controllers in turn (as a second device, say) and other test processes
/// stage files in the real temp folder; a test of the sweep turns it on together with [debugTempRoot].
@visibleForTesting
bool sweepStaleMediaOnStart = !Platform.environment.containsKey('FLUTTER_TEST');

Directory tempFolder(String name) =>
    Directory('${(debugTempRoot ?? Directory.systemTemp).path}/$name');

/// What a kill leaves behind: exports, backup parts and downloads staged in the temp folders are plain text copies of
/// the history. Run once at launch, before anything can use the folders; synchronous so it is finished by then, and a
/// few directory entries at most.
void clearStaleCachedMedia() {
  if (!sweepStaleMediaOnStart) return;
  for (final name in cachedMediaFolders) {
    try {
      final folder = tempFolder(name);
      if (!folder.existsSync()) continue;
      for (final entry in folder.listSync()) {
        try {
          entry.deleteSync(recursive: true);
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      continue;
    }
  }
}

/// Empties the cache folders (the folders themselves stay, so a player that is mid-download keeps a place to write).
/// Anything missing or busy is skipped; this never blocks signing out.
Future<void> clearCachedMedia() async {
  for (final name in cachedMediaFolders) {
    try {
      final folder = tempFolder(name);
      if (!await folder.exists()) continue;
      await for (final entry in folder.list()) {
        try {
          await entry.delete(recursive: true);
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      continue;
    }
  }
}

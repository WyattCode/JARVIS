import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/video_source.dart';

import 'support.dart';

class VideoApi extends FakeApi {
  int downloads = 0;
  @override
  Future<Uint8List> download(String path) async {
    downloads++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return Uint8List.fromList([downloads, 2, 3]);
  }
}

void main() {
  testWidgets(
    'iOS: covers opened together keep their files, and one video is fetched once',
    (t) async {
      final api = VideoApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      final players = await t.runAsync(
        () => Future.wait([
          openVideo(c, '/v1/videos/a/content'),
          openVideo(c, '/v1/videos/b/content'),
          openVideo(c, '/v1/videos/a/content'),
        ]),
      );
      expect(api.downloads, 2);
      for (final p in players!) {
        expect(File(Uri.parse(p.dataSource).toFilePath()).existsSync(), isTrue);
      }
      expect(players[0].dataSource, players[2].dataSource);
      expect(players[0].dataSource, isNot(players[1].dataSource));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

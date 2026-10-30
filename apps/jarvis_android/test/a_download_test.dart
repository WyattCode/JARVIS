import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/net/jarvis_api.dart';

import 'http_api_test.dart' show Client, Reply;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('a_download'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'downloadTo streams the body into the file and leaves no partial file',
    () async {
      final client = Client(
        Reply(200, [
          [1, 2],
          [3],
          [4, 5],
        ]),
      );
      final api = JarvisApi(
        Uri.parse('https://jarvis.test'),
        clientFactory: () => client,
      )..cookie = 'cookie=test';
      final file = File('${dir.path}/clip.mp4');
      expect(await api.downloadTo('/v1/videos/x/content', file), 5);
      expect(file.readAsBytesSync(), [1, 2, 3, 4, 5]);
      expect(File('${file.path}.part').existsSync(), isFalse);
      expect(client.request!.headers.values['cookie'], 'cookie=test');
    },
  );

  test('a failed download leaves nothing behind', () async {
    final api = JarvisApi(
      Uri.parse('https://jarvis.test'),
      clientFactory: () => Client(Reply(500, [])),
    );
    final file = File('${dir.path}/clip.mp4');
    await expectLater(
      api.downloadTo('/v1/videos/x/content', file),
      throwsA(isA<JarvisException>()),
    );
    expect(dir.listSync(), isEmpty);
  });
}

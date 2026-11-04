import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/net/sse.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/model/adaptive_layout.dart';

void main() {
  test(
    'SSE survives arbitrary byte boundaries, CRLF, comments and multiline data',
    () async {
      final bytes = utf8.encode(
        ': ping\r\ndata: {"text":"中文"}\r\n\r\ndata:first\ndata: second\n\ndata: [DONE]\n\n',
      );
      final result = await sseData(Stream.fromIterable(bytes.map((b) => [b])))
          .toList();
      expect(result, ['{"text":"中文"}', 'first\nsecond', '[DONE]']);
    },
  );
  test('EOF without DONE remains distinguishable', () async {
    expect(
      await sseData(Stream.value(utf8.encode('data: incomplete'))).toList(),
      ['incomplete'],
    );
  });
  test('Reject unsafe service URLs without weakening TLS', () {
    for (final url in [
      'http://jarvis.test',
      'https://user:secret@jarvis.test',
      'https://jarvis.test/v1',
      'https://jarvis.test/?api_key=secret',
    ]) {
      expect(() => JarvisApi(Uri.parse(url)), throwsA(isA<JarvisException>()));
    }
    JarvisApi(Uri.parse('https://jarvis.odn.cc')).close();
  });
  test('Foldable layout uses actual logical window size', () {
    expect(AdaptiveLayout.forWindow(1168 / 2.75, 1712 / 2.75).docked, false);
    expect(AdaptiveLayout.forWindow(1712 / 2.75, 1168 / 2.75).docked, false);
    expect(AdaptiveLayout.forWindow(1672 / 2.75, 2364 / 2.75).docked, false);
    expect(AdaptiveLayout.forWindow(2364 / 2.75, 1672 / 2.75).docked, true);
    expect(AdaptiveLayout.forWindow(500, 650).docked, false);
    expect(
      AdaptiveLayout.forWindow(
        860,
        608,
        horizontalInsets: 64,
        verticalInsets: 48,
      ).docked,
      true,
    );
  });
}

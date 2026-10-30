import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/net/jarvis_api.dart';

/// A WebSocket that only records being closed.
class FakeSocket implements WebSocket {
  bool closed = false;
  @override
  Future close([int? code, String? reason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

JarvisApi apiWith(
  Future<WebSocket> Function(Uri, Map<String, dynamic>) connect,
) =>
    JarvisApi(Uri.parse('https://jarvis.test'), socketConnector: connect)
      ..cookie = '__Host-jarvis_session=x';

void main() {
  test('a socket that opens after the timeout is closed, not leaked', () {
    fakeAsync((async) {
      final late = Completer<WebSocket>();
      final api = apiWith((_, _) => late.future);
      Object? failure;
      api.openRealtime().then<void>(
        (_) {},
        onError: (Object e) {
          failure = e;
        },
      );
      async.elapse(const Duration(seconds: 21));
      expect(failure, isA<TimeoutException>());

      final socket = FakeSocket();
      late.complete(socket);
      async.flushMicrotasks();
      expect(socket.closed, isTrue);
    });
  });

  test('a socket that opens in time is returned and nothing stays pending', () {
    fakeAsync((async) {
      final socket = FakeSocket();
      final api = apiWith((_, _) async => socket);
      var opened = false;
      api.openRealtime().then((_) => opened = true);
      async.flushMicrotasks();
      expect(opened, isTrue);
      expect(socket.closed, isFalse);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a refused upgrade with 401 or 403 is an expired session', () async {
    for (final code in [401, 403, 303]) {
      final api = apiWith(
        (_, _) async => throw WebSocketException('not upgraded', code),
      );
      await expectLater(
        api.openRealtime(),
        throwsA(
          isA<JarvisException>()
              .having((e) => e.unauthorized, 'unauthorized', isTrue)
              .having((e) => e.message, 'message', contains('登录已过期')),
        ),
        reason: '$code',
      );
    }
  });

  test('other failures stay what they are', () async {
    final server = apiWith(
      (_, _) async => throw const WebSocketException('not upgraded', 502),
    );
    await expectLater(
      server.openRealtime(),
      throwsA(isA<WebSocketException>()),
    );
    final network = apiWith(
      (_, _) async => throw const SocketException('down'),
    );
    await expectLater(network.openRealtime(), throwsA(isA<SocketException>()));
  });

  test('the handshake carries the session and the origin', () async {
    Map<String, dynamic>? headers;
    Uri? url;
    final api = apiWith((u, h) async {
      url = u;
      headers = h;
      return FakeSocket();
    })..apiKey = 'sk-1';
    await api.openRealtime();
    expect(url.toString(), 'wss://jarvis.test/v1/realtime');
    expect(headers!['Cookie'], '__Host-jarvis_session=x');
    expect(headers!['Authorization'], 'Bearer sk-1');
    expect(headers!['Origin'], 'https://jarvis.test');
  });
}

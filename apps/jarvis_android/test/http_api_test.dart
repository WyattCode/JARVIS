import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/model/settings.dart';

class Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Reply extends StreamView<List<int>> implements HttpClientResponse {
  Reply(this.statusCode, List<List<int>> chunks, {this.cookies = const []})
    : super(Stream.fromIterable(chunks));
  @override
  final int statusCode;
  @override
  final List<Cookie> cookies;
  @override
  final Headers headers = Headers();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Request implements HttpClientRequest {
  Request(this.method, this.url, this.reply, {this.delay});
  final Duration? delay;
  @override
  final String method;
  final Uri url;
  final Reply reply;
  @override
  final Headers headers = Headers();
  @override
  int contentLength = -1;
  @override
  bool followRedirects = true;
  final bytes = <int>[];
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async {
    if (delay != null) await Future<void>.delayed(delay!);
    return reply;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Client implements HttpClient {
  Client(this.reply);
  final Reply reply;
  Request? request;
  Duration? delay;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      request = Request(method, url, reply, delay: delay);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('Login uses exact UTF8 Content-Length, Origin, no redirect and never query credentials', () async {
    final client = Client(
      Reply(303, [], cookies: [Cookie('__Host-jarvis_session', 'test-cookie')]),
    );
    final api = JarvisApi(
      Uri.parse('https://jarvis.test'),
      clientFactory: () => client,
    );
    await api.login('测试用户', 'a@ b');
    final r = client.request!;
    expect(r.method, 'POST');
    expect(r.url.query, isEmpty);
    expect(r.contentLength, r.bytes.length);
    expect(r.contentLength, greaterThan(0));
    expect(r.followRedirects, false);
    expect(r.headers.values['origin'], 'https://jarvis.test');
    expect(
      r.headers.contentType!.mimeType,
      'application/x-www-form-urlencoded',
    );
    expect(Uri.splitQueryString(utf8.decode(r.bytes)), {
      'username': '测试用户',
      'password': 'a@ b',
    });
    expect(api.cookie, '__Host-jarvis_session=test-cookie');
  });
  test('Chat preserves byte-split Unicode, tool deltas and DONE while using authenticated headers', () async {
    final text =
        'data: {"choices":[{"delta":{"content":"中文","tool_calls":[{"index":0,"id":"call1","function":{"name":"generate_video","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\r\n\r\ndata: [DONE]\n\n';
    final client = Client(
      Reply(200, utf8.encode(text).map((b) => [b]).toList()),
    );
    final api =
        JarvisApi(Uri.parse('https://jarvis.test'), clientFactory: () => client)
          ..cookie = 'cookie=test'
          ..apiKey = 'test-key';
    final parts = await api.chat('r', 'model', 'high', [
      {'role': 'user', 'content': '中文'},
    ], options: const ChatOptions(maxTokens: 24000)).toList();
    expect(parts.first.text, '中文');
    expect(parts.first.toolDeltas.single.name, 'generate_video');
    expect(parts.last.done, true);
    expect(client.request!.headers.values['authorization'], 'Bearer test-key');
    expect(client.request!.headers.values['cookie'], 'cookie=test');
    final body = jsonDecode(utf8.decode(client.request!.bytes));
    expect(body['max_tokens'], 24000);
    expect(body['chat_template_kwargs']['enable_thinking'], true);
  });
  test('a slow chat start is waited for longer than a cheap call', () async {
    const text =
        'data: {"choices":[{"delta":{"content":"好"}}]}\n\ndata: [DONE]\n\n';
    Client slow() =>
        Client(Reply(200, [utf8.encode(text)]))
          ..delay = const Duration(milliseconds: 150);
    final api = JarvisApi(
      Uri.parse('https://jarvis.test'),
      clientFactory: slow,
    );
    // The default leaves room for an upload and a long prompt; the 30 s of the cheap calls does not.
    expect(
      api.chatHeaderTimeout,
      greaterThanOrEqualTo(const Duration(seconds: 90)),
    );
    api.chatHeaderTimeout = const Duration(milliseconds: 40);
    await expectLater(
      api.chat('r', 'm', 'high', [
        {'role': 'user', 'content': 'x'},
      ]).toList(),
      throwsA(isA<TimeoutException>()),
    );
    api.chatHeaderTimeout = const Duration(seconds: 5);
    final parts = await api.chat('r2', 'm', 'high', [
      {'role': 'user', 'content': 'x'},
    ]).toList();
    expect(parts.first.text, '好');
  });
  test('EOF without DONE is an interruption even after partial text', () async {
    final client = Client(
      Reply(200, [
        utf8.encode('data: {"choices":[{"delta":{"content":"半句"}}]}\n\n'),
      ]),
    );
    final api = JarvisApi(
      Uri.parse('https://jarvis.test'),
      clientFactory: () => client,
    );
    final seen = <String>[];
    await expectLater(
      api.chat('r', 'm', 'none', []).forEach((part) => seen.add(part.text)),
      throwsA(isA<JarvisException>()),
    );
    expect(seen, ['半句']);
  });
  test('Media credentials cannot be forwarded to another origin', () {
    final api = JarvisApi(Uri.parse('https://jarvis.test'))
      ..cookie = 'cookie=test';
    expect(
      api.mediaUri('http://old-worker/v1/files/image.png').origin,
      'https://jarvis.test',
    );
    expect(
      api.mediaUri('https://other.test/p.png').origin,
      'https://other.test',
    );
    expect(
      () => api.mediaUri('javascript:alert(1)'),
      throwsA(isA<JarvisException>()),
    );
  });
}

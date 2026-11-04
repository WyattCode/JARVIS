import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/media.dart';
import '../model/settings.dart';
import 'realtime_wire.dart';
import 'model_tools.dart';

import '../model/conversation.dart';
import 'sse.dart';

class JarvisException implements Exception {
  const JarvisException(this.message, {this.unauthorized = false});
  final String message;
  final bool unauthorized;
  @override
  String toString() => message;
}

abstract class JarvisTransport {
  String apiKey = '';
  Future<Map<String, dynamic>> modelSkill() async => {
    'enabled': false,
    'text': '',
  };
  Future<Map<String, dynamic>> toolsStatus() async => {'data': []};
  Future<String> modelTool(
    String requestId,
    String name,
    Map<String, dynamic> args,
  ) => throw UnsupportedError('Model management unavailable');
  Uri get endpoint => Uri.parse('https://jarvis.odn.cc');
  Map<String, String> get mediaHeaders => {};
  Uri mediaUri(String path) => endpoint.resolve(path);
  Future<RealtimeWire> openRealtime() =>
      throw UnsupportedError('Realtime unavailable');
  Future<Map<String, dynamic>> jobStatus(String id) =>
      throw UnsupportedError('Job status unavailable');
  Future<String> extractPdf(Uint8List bytes) =>
      throw UnsupportedError('PDF unavailable');
  Future<Uint8List> download(String path) =>
      throw UnsupportedError('Download unavailable');
  Future<Uint8List> preview(VoiceInfo voice, String model) =>
      throw UnsupportedError('Preview unavailable');
  Future<List<String>> generate(
    String requestId,
    String kind,
    Map<String, dynamic> args, {
    String? resumeJobId,
    void Function(String)? onJob,
    void Function(double)? onProgress,
  }) => throw UnsupportedError('Media unavailable');
  String? get cookie;
  set cookie(String? value);
  Future<void> login(String username, String password);
  Future<void> logout();
  Future<List<ModelInfo>> models();
  Stream<ChatDelta> chat(
    String requestId,
    String model,
    String effort,
    List<Map<String, dynamic>> messages, {
    ChatOptions options = const ChatOptions(),
  });
  void cancel(String requestId);
  void close();
}

class JarvisApi extends JarvisTransport {
  JarvisApi(this.base, {this._clientFactory}) {
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw const JarvisException('请输入 HTTPS 服务地址，不包含路径或账户信息');
    }
  }
  final Uri base;
  final HttpClient Function()? _clientFactory;
  @override
  Uri get endpoint => base;
  @override
  Map<String, String> get mediaHeaders => {
    'Cookie': ?cookie,
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };
  @override
  Uri mediaUri(String path) {
    final url = base.resolve(path);
    if (!['https', 'http'].contains(url.scheme) || url.userInfo.isNotEmpty) {
      throw const JarvisException('媒体地址无效');
    }
    if (url.origin != base.origin &&
        (url.path.startsWith('/v1/files/') ||
            url.path.startsWith('/v1/videos/'))) {
      return base.resolve(url.path + (url.hasQuery ? '?${url.query}' : ''));
    }
    return url;
  }

  @override
  String? cookie;
  int _authSequence = 0;
  final _requests = <String, HttpClient>{};
  HttpClient _client() =>
      (_clientFactory?.call() ?? HttpClient())
        ..connectionTimeout = const Duration(seconds: 20);
  void _headers(HttpClientRequest r) {
    r.followRedirects = false;
    r.headers.set('Origin', base.origin);
    if (apiKey.isNotEmpty) r.headers.set('Authorization', 'Bearer $apiKey');
    if (cookie != null) r.headers.set(HttpHeaders.cookieHeader, cookie!);
  }

  Future<HttpClientResponse> _request(
    HttpClient client,
    String method,
    String path, {
    String? body,
    String? type,
    Duration headerTimeout = const Duration(seconds: 30),
  }) async {
    final r = await client.openUrl(method, base.resolve(path));
    _headers(r);
    if (body != null) {
      r.headers.contentType = ContentType.parse(type ?? 'application/json');
      final bytes = utf8.encode(body);
      r.contentLength = bytes.length;
      r.add(bytes);
    }
    return r.close().timeout(headerTimeout);
  }

  Future<void> _check(HttpClientResponse r) async {
    if (r.statusCode == 401 || r.statusCode == 303) {
      await r.drain<void>().timeout(const Duration(seconds: 10));
      throw const JarvisException('登录已过期，请重新登录', unauthorized: true);
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      await r.drain<void>().timeout(const Duration(seconds: 10));
      throw JarvisException(
        r.statusCode == 429 ? '请求过于频繁，请稍后重试' : '服务暂时不可用（${r.statusCode}）',
      );
    }
  }

  @override
  Future<void> login(String username, String password) async {
    final sequence = ++_authSequence;
    final client = _client();
    try {
      final body =
          'username=${Uri.encodeQueryComponent(username)}&password=${Uri.encodeQueryComponent(password)}';
      final r = await _request(
        client,
        'POST',
        '/login',
        body: body,
        type: 'application/x-www-form-urlencoded',
      );
      final tokens = r.cookies
          .where((c) => c.name == '__Host-jarvis_session')
          .toList();
      if (r.statusCode == 303 &&
          tokens.length == 1 &&
          tokens.single.value.isNotEmpty) {
        if (sequence != _authSequence) throw const JarvisException('登录操作已结束');
        cookie = '${tokens.single.name}=${tokens.single.value}';
        await r.drain<void>().timeout(const Duration(seconds: 10));
        return;
      }
      await r.drain<void>().timeout(const Duration(seconds: 10));
      throw JarvisException(
        r.statusCode == 429 ? '尝试次数较多，请稍后再试' : '登录未成功，请检查账户与密码',
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> logout() async {
    _authSequence++;
    final previous = cookie;
    cookie = null;
    final client = _client();
    try {
      final request = await client.postUrl(base.resolve('/logout'));
      _headers(request);
      if (previous != null) {
        request.headers.set(HttpHeaders.cookieHeader, previous);
      }
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.contentLength = 0;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      await response.drain<void>().timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<List<ModelInfo>> models() async {
    final client = _client();
    try {
      final r = await _request(client, 'GET', '/v1/models');
      await _check(r);
      final value = jsonDecode(
        await utf8.decoder.bind(r).join().timeout(const Duration(seconds: 30)),
      ) as Map<String, dynamic>;
      return (value['data'] as List)
          .cast<Map<String, dynamic>>()
          .where((m) => m['qualified'] != false)
          .map(ModelInfo.fromJson)
          .toList();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<ChatDelta> chat(
    String requestId,
    String model,
    String effort,
    List<Map<String, dynamic>> messages, {
    ChatOptions options = const ChatOptions(),
  }) async* {
    final client = _client();
    _requests[requestId] = client;
    var done = false;
    try {
      final r = await _request(
        client,
        'POST',
        '/v1/chat/completions',
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'stream': true,
          'stream_options': {'include_usage': true},
          'reasoning_effort': effort,
          if (options.maxTokens > 0) 'max_tokens': options.maxTokens,
          'chat_template_kwargs': {'enable_thinking': effort != 'none'},
          if (options.tools.isNotEmpty) 'tools': options.tools,
          if (options.tools.isNotEmpty) 'tool_choice': 'auto',
        }),
      );
      await _check(r);
      await for (final data in sseData(
        r.timeout(const Duration(seconds: 120)),
      )) {
        if (data == '[DONE]') {
          done = true;
          yield const ChatDelta(done: true);
          break;
        }
        final event = jsonDecode(data) as Map<String, dynamic>;
        if (event['error'] != null) {
          throw const JarvisException('模型返回错误，已保留收到的内容');
        }
        final choices = event['choices'] as List? ?? [];
        if (choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;
        final delta = choice['delta'] as Map<String, dynamic>? ?? {};
        yield ChatDelta(
          text: delta['content'] as String? ?? '',
          reasoning: delta['reasoning_content'] as String? ?? '',
          finishReason: choice['finish_reason'] as String?,
          toolDeltas: (delta['tool_calls'] as List? ?? []).map((t) {
            final f = t['function'] as Map? ?? {};
            return ToolDelta(
              (t['index'] as num?)?.toInt() ?? 0,
              t['id'] as String? ?? '',
              f['name'] as String? ?? '',
              f['arguments'] as String? ?? '',
            );
          }).toList(),
        );
      }
      if (!done) throw const JarvisException('连接中断，已保留收到的内容；未自动重试');
    } finally {
      _requests.remove(requestId);
      client.close(force: true);
    }
  }

  @override
  void cancel(String requestId) {
    _requests.remove(requestId)?.close(force: true);
  }

  @override
  void close() {
    for (final c in _requests.values) {
      c.close(force: true);
    }
    _requests.clear();
  }

  @override
  Future<Map<String, dynamic>> modelSkill() => _json(
    'GET',
    '/v1/skills/model-manager',
    wait: const Duration(seconds: 5),
  );
  @override
  Future<Map<String, dynamic>> toolsStatus() => _json('GET', '/v1/tools');
  @override
  Future<String> modelTool(
    String requestId,
    String name,
    Map<String, dynamic> args,
  ) async {
    if (!modelToolNames.contains(name)) throw const JarvisException('此工具未开放');
    final client = _client();
    _requests[requestId] = client;
    try {
      final json = await _json(
        'POST',
        '/mcp',
        body: {
          'jsonrpc': '2.0',
          'id': DateTime.now().microsecondsSinceEpoch,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': args},
        },
        wait: const Duration(minutes: 10),
        owner: client,
      );
      if (json['error'] != null) {
        return jsonEncode({'error': json['error']['message']});
      }
      final result = json['result'] as Map? ?? {};
      final text = (result['content'] as List? ?? [])
          .where((p) => p['type'] == 'text')
          .map((p) => p['text'])
          .join('\n');
      return result['isError'] == true ? jsonEncode({'error': text}) : text;
    } finally {
      if (identical(_requests[requestId], client)) _requests.remove(requestId);
      client.close(force: true);
    }
  }

  @override
  Future<RealtimeWire> openRealtime() async {
    final url = base.replace(scheme: 'wss', path: '/v1/realtime');
    final socket = await WebSocket.connect(
      url.toString(),
      protocols: ['realtime'],
      headers: {...mediaHeaders, 'Origin': base.origin},
    ).timeout(const Duration(seconds: 20));
    socket.pingInterval = const Duration(seconds: 20);
    return WebSocketWire(socket);
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration wait = const Duration(seconds: 30),
    HttpClient? owner,
  }) async {
    final client = owner ?? _client();
    try {
      final r = await _request(
        client,
        method,
        path,
        body: body == null ? null : jsonEncode(body),
        headerTimeout: wait,
      );
      await _check(r);
      return Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(r).join().timeout(wait)) as Map,
      );
    } finally {
      if (owner == null) client.close(force: true);
    }
  }

  @override
  Future<Uint8List> download(String path) async {
    final client = _client(), url = mediaUri(path);
    try {
      final req = await client.getUrl(url);
      req.followRedirects = false;
      if (url.origin == base.origin) _headers(req);
      final r = await req.close().timeout(const Duration(seconds: 30));
      await _check(r);
      final bytes = BytesBuilder();
      await for (final chunk in r.timeout(const Duration(seconds: 60))) {
        bytes.add(chunk);
        if (bytes.length > 256 * 1024 * 1024) {
          throw const JarvisException('文件超过256MB，请通过网页下载');
        }
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, dynamic>> jobStatus(String id) =>
      _json('GET', '/v1/jobs/${Uri.encodeComponent(id)}');
  @override
  Future<String> extractPdf(Uint8List bytes) async {
    final client = _client();
    try {
      final r = await client.postUrl(base.resolve('/v1/jarvis/extract-pdf'));
      _headers(r);
      r.headers.contentType = ContentType('application', 'pdf');
      r.contentLength = bytes.length;
      r.add(bytes);
      final response = await r.close().timeout(const Duration(seconds: 90));
      await _check(response);
      final j = jsonDecode(
        await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 30)),
      ) as Map;
      return j['text'] as String;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Uint8List> preview(VoiceInfo voice, String model) async {
    if (voice.preview != null) return download(voice.preview!);
    final client = _client();
    try {
      final r = await _request(
        client,
        'POST',
        '/v1/audio/speech',
        body: jsonEncode({
          'model': model,
          'voice': voice.id,
          'input': '你好，我是贾维斯。我们把问题理清楚，一步一步找到答案。',
          'response_format': 'wav',
        }),
        headerTimeout: const Duration(minutes: 2),
      );
      await _check(r);
      final b = BytesBuilder();
      await for (final chunk in r.timeout(const Duration(seconds: 45))) {
        b.add(chunk);
        if (b.length > 8 * 1024 * 1024) throw const JarvisException('试听音频过大');
      }
      return b.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<List<String>> generate(
    String requestId,
    String kind,
    Map<String, dynamic> args, {
    String? resumeJobId,
    void Function(String)? onJob,
    void Function(double)? onProgress,
  }) async {
    final client = _client();
    _requests[requestId] = client;
    bool current() => identical(_requests[requestId], client);
    try {
      final request = <String, dynamic>{
        'prompt': args['prompt'],
        if (args['model'] != null) 'model': args['model'],
      };
      if (kind == 'image') {
        if (args['size'] != null) request['size'] = args['size'].toString();
        request['response_format'] = 'url';
        final j = await _json(
          'POST',
          '/v1/images/generations',
          body: request,
          wait: const Duration(minutes: 15),
          owner: client,
        );
        return (j['data'] as List? ?? [])
            .map((v) => v['url'] as String)
            .toList();
      }
      if (args['seconds'] != null) {
        request['seconds'] = args['seconds'].toString();
      }
      var j = resumeJobId == null
          ? await _json('POST', '/v1/videos', body: request, owner: client)
          : await _json(
              'GET',
              '/v1/videos/${Uri.encodeComponent(resumeJobId)}',
              owner: client,
            );
      final id = (j['id'] ?? resumeJobId) as String;
      onJob?.call(id);
      final deadline = DateTime.now().add(const Duration(minutes: 30));
      while (['queued', 'in_progress', 'running'].contains(j['status'])) {
        if (!current()) throw const JarvisException('任务跟踪已取消');
        if (DateTime.now().isAfter(deadline)) {
          throw const JarvisException('视频仍未完成，请稍后重新检查原任务');
        }
        onProgress?.call((j['progress'] as num?)?.toDouble() ?? 0);
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!current()) throw const JarvisException('任务跟踪已取消');
        j = await _json(
          'GET',
          '/v1/videos/${Uri.encodeComponent(id)}',
          owner: client,
        );
      }
      if (j['status'] != 'completed') {
        throw const JarvisException('视频生成失败，请检查原任务');
      }
      return ['/v1/videos/${Uri.encodeComponent(id)}/content'];
    } finally {
      if (current()) _requests.remove(requestId);
      client.close(force: true);
    }
  }
}

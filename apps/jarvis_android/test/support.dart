import 'dart:async';

import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/vault.dart';
import 'package:jarvis_android/model/settings.dart';

class MemoryVault implements Vault {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class FakeApi extends JarvisTransport {
  @override
  String? cookie;
  final streams = <String, StreamController<ChatDelta>>{};
  final cancelled = <String>[];
  @override
  Future<void> login(String username, String password) async {
    cookie = '__Host-jarvis_session=test';
  }

  @override
  Future<void> logout() async {
    cookie = null;
  }

  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('test-model', 'Test model'),
  ];
  @override
  Stream<ChatDelta> chat(
    String requestId,
    String model,
    String effort,
    List<Map<String, dynamic>> messages, {
    ChatOptions options = const ChatOptions(),
  }) {
    final stream = StreamController<ChatDelta>();
    streams[requestId] = stream;
    return stream.stream;
  }

  @override
  void cancel(String requestId) {
    cancelled.add(requestId);
    streams[requestId]?.close();
  }

  @override
  void close() {
    for (final s in streams.values) {
      if (!s.isClosed) s.close();
    }
  }
}

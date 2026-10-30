import 'dart:io';

abstract class RealtimeWire {
  Stream<String> get events;
  void send(String value);
  Future<void> close();
}

class WebSocketWire implements RealtimeWire {
  WebSocketWire(this.socket);
  final WebSocket socket;
  @override
  Stream<String> get events => socket.where((v) => v is String).cast<String>();
  @override
  void send(String value) => socket.add(value);
  @override
  Future<void> close() async {
    try {
      await socket
          .close(WebSocketStatus.normalClosure)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      /* Closing a dead connection must not block logout or microphone release. */
    }
  }
}

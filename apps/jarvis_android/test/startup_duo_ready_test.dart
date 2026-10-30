import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/duo_layout.dart';

void main() {
  testWidgets('the startup waits for the native layout, but not for ever', (
    t,
  ) async {
    // A native shell that never reports, whatever the host (a bare test binding has no handler at all).
    const method = MethodChannel('ai.jarvis.app/duo');
    const events = EventChannel('ai.jarvis.app/duo-events');
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async => null);
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(events, null);
    });
    final source = ChannelDuoLayoutSource();
    expect(source.resolved.value, isFalse);
    await t.pump(const Duration(milliseconds: 500));
    expect(source.resolved.value, isFalse);
    await t.pump(const Duration(milliseconds: 300));
    expect(source.resolved.value, isTrue, reason: 'an old shell never reports');
    source.dispose();
  });
}

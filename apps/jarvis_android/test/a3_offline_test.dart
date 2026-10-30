import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

/// The service is unreachable (or rejects the session) until [failure] is cleared.
class FlakyApi extends FakeApi {
  Object? failure = const SocketException('offline');
  int attempts = 0;
  @override
  Future<List<ModelInfo>> models() async {
    attempts++;
    if (failure != null) throw failure!;
    return super.models();
  }
}

Future<(FlakyApi, JarvisController)> saved({Object? failure}) async {
  final api = FlakyApi()
    ..cookie = '__Host-jarvis_session=test'
    ..failure = failure ?? const SocketException('offline');
  final vault = MemoryVault();
  // A previous run left history behind.
  final first = JarvisController(FakeApi()..cookie = api.cookie, vault);
  await first.initialize();
  first.current.messages.add(ChatMessage('user', '本地历史'));
  await first.save();
  first.dispose();
  return (api, JarvisController(api, vault));
}

void main() {
  testWidgets('offline cold start opens the local history, not the login', (
    t,
  ) async {
    final (api, c) = await saved();
    c.offlineRetryDelay = (_) => const Duration(minutes: 10);
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(seconds: 4));
    await t.pump(const Duration(milliseconds: 1500));
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(JarvisHome), findsOneWidget);
    expect(c.authenticated, isFalse);
    expect(c.offlineSession, isTrue);
    expect(c.conversations.single.messages.single.text, '本地历史');

    // Sending stays off while offline.
    c.setDraft('不应发出');
    await c.send();
    expect(api.streams, isEmpty);

    // The service comes back: one retry and the session is live.
    api.failure = null;
    await c.retryConnect();
    await t.pump();
    expect(c.authenticated, isTrue);
    expect(c.offlineSession, isFalse);
    expect(find.byType(JarvisHome), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected session (401) still goes to the login page', (
    t,
  ) async {
    final (api, c) = await saved(
      failure: const JarvisException('登录已过期，请重新登录', unauthorized: true),
    );
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(seconds: 4));
    expect(find.byType(JarvisHome), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(c.offlineSession, isFalse);
    expect(api.cookie, isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no saved session and no network stays on the login page', (
    t,
  ) async {
    final api = FlakyApi()..cookie = null;
    final c = JarvisController(api, MemoryVault());
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(LoginPage), findsOneWidget);
    expect(c.offlineSession, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a server error with a saved session is offline, not a logout', (
    t,
  ) async {
    final (api, c) = await saved(
      failure: const JarvisException('服务暂时不可用（503）'),
    );
    c.offlineRetryDelay = (_) => const Duration(minutes: 10);
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(seconds: 1));
    expect(c.offlineSession, isTrue);
    expect(api.cookie, isNotNull);
    expect(find.byType(JarvisHome), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('coming back to the foreground retries, throttled', (t) async {
    final (api, c) = await saved();
    c.offlineRetryDelay = (_) => const Duration(minutes: 10);
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(seconds: 1));
    expect(api.attempts, 1);

    // Right after an attempt nothing is repeated.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(api.attempts, 1);

    c.resumeThrottle = Duration.zero;
    api.failure = null;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    await t.pump();
    expect(api.attempts, 2);
    expect(c.authenticated, isTrue);
    expect(c.offlineSession, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('while offline it retries by itself with a growing wait', (
    t,
  ) async {
    final (api, c) = await saved();
    final waits = <int>[];
    c.offlineRetryDelay = (n) {
      waits.add(n);
      return Duration(seconds: 2 << n);
    };
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(const Duration(milliseconds: 100));
    expect(api.attempts, 1);
    await t.pump(const Duration(seconds: 2));
    expect(api.attempts, 2);
    await t.pump(const Duration(seconds: 3));
    expect(api.attempts, 2, reason: 'the second wait is longer');
    await t.pump(const Duration(seconds: 2));
    expect(api.attempts, 3);
    api.failure = null;
    await t.pump(const Duration(seconds: 8));
    expect(c.authenticated, isTrue);
    final attempts = api.attempts;
    await t.pump(const Duration(minutes: 1));
    expect(api.attempts, attempts, reason: 'no more retries once connected');
    expect(waits.take(3), [0, 1, 2]);
    await t.pumpWidget(const SizedBox());
  });

  test('the default wait grows gently and stops at a minute', () async {
    final c = JarvisController(FakeApi(), MemoryVault());
    final waits = [
      for (var i = 0; i < 8; i++) c.offlineRetryDelay(i).inSeconds,
    ];
    expect(waits, [5, 10, 20, 40, 60, 60, 60, 60]);
    c.dispose();
  });
}

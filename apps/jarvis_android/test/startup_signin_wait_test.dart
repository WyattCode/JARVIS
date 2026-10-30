import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

class SlowApi extends FakeApi {
  final gate = Completer<void>();
  bool rejected = false;
  @override
  Future<List<ModelInfo>> models() async {
    await gate.future;
    if (rejected) throw const JarvisException('登录已过期', unauthorized: true);
    return super.models();
  }
}

void main() {
  testWidgets(
    'a saved session never flashes the login page while it is checked',
    (t) async {
      final api = SlowApi()..cookie = '__Host-jarvis_session=test';
      final c = JarvisController(api, MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(JarvisHome), findsNothing);

      api.gate.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(JarvisHome), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a very slow check opens the local session after the grace and the login page only when the session is rejected',
    (t) async {
      final api = SlowApi()..cookie = '__Host-jarvis_session=test';
      final c = JarvisController(api, MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump(signInGrace + const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(JarvisHome), findsOneWidget);

      // The service answers that the session is no good: the login page cross-fades in over the chat.
      api.rejected = true;
      api.gate.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 150));
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(JarvisHome), findsOneWidget, reason: 'still fading');
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(JarvisHome), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reduced motion swaps login and chat at once', (t) async {
    final api = SlowApi()..cookie = '__Host-jarvis_session=test';
    final c = JarvisController(api, MemoryVault());
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await t.pumpWidget(JarvisApp(controller: c));
    await t.pump(signInGrace + const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(JarvisHome), findsOneWidget);
    api.rejected = true;
    api.gate.complete();
    await t.pump();
    await t.pump();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(JarvisHome), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}

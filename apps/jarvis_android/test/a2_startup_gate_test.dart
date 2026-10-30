import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/startup_scene.dart';

import 'support.dart';

/// The login request stays open until [release], so `connecting` is true while the login page is up.
class HoldLoginApi extends FakeApi {
  final release = Completer<void>();
  @override
  Future<void> login(String username, String password) async {
    await release.future;
    await super.login(username, password);
  }
}

class SlowModelsApi extends FakeApi {
  final gate = Completer<void>();
  @override
  Future<List<ModelInfo>> models() async {
    await gate.future;
    return super.models();
  }
}

/// Native duo channels that stay silent, so the app waits on `resolved` like on a device that has not reported yet.
void silentDuoChannels(WidgetTester t) {
  final messenger = t.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('ai.jarvis.app/duo'),
    (call) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('ai.jarvis.app/duo-events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('ai.jarvis.app/duo'),
      null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('ai.jarvis.app/duo-events'),
      null,
    );
  });
}

void main() {
  testWidgets(
    'tapping login while the page is up keeps the page and never replays the launch flight',
    (t) async {
      final api = HoldLoginApi();
      final c = JarvisController(api, MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 1200));
      await t.pump();
      expect(find.byType(LoginPage), findsOneWidget);
      final page = t.state(find.byType(LoginPage));
      await t.enterText(find.byType(TextField).first, 'user');
      await t.enterText(find.byType(TextField).last, 'secret');
      await t.pump();

      await t.tap(find.widgetWithText(FilledButton, '登录'));
      await t.pump();
      expect(c.connecting, isTrue);
      // Within the 3 s sign-in grace period: used to read as "checking a saved session".
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsOneWidget);
      expect(
        identical(page, t.state(find.byType(LoginPage))),
        isTrue,
        reason: 'the page (typed text, focus) must not be rebuilt from scratch',
      );
      expect(
        t.widget<TextField>(find.byType(TextField).first).controller!.text,
        'user',
      );
      final gate = t.state(find.byType(StartupGate)) as dynamic;
      expect(gate.landed, isTrue, reason: 'the launch flight stays landed');
      expect(
        find.bySemanticsLabel('贾维斯正在启动'),
        findsNothing,
        reason: 'no second launch overlay',
      );

      api.release.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.byType(JarvisHome), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a saved session still waits on the launch scene, then opens home',
    (t) async {
      final api = SlowModelsApi()..cookie = '__Host-jarvis_session=test';
      final c = JarvisController(api, MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump(const Duration(seconds: 1));
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(JarvisHome), findsNothing);
      api.gate.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.byType(JarvisHome), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the sign-in timer gives way to the local session after the grace, not to the login page',
    (t) async {
      final api = SlowModelsApi()..cookie = '__Host-jarvis_session=test';
      final c = JarvisController(api, MemoryVault());
      await t.pumpWidget(JarvisApp(controller: c));
      // The old 3 s grace is gone: a slow network gets the full check.
      await t.pump(const Duration(milliseconds: 3500));
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(JarvisHome), findsNothing);
      await t.pump(signInGrace - const Duration(milliseconds: 3500));
      await t.pump(const Duration(milliseconds: 1500));
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(JarvisHome), findsOneWidget);
      expect(find.byKey(const Key('offline-bar')), findsOneWidget);
      api.gate.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(JarvisHome), findsOneWidget);
      expect(find.byKey(const Key('offline-bar')), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('home stays away until the native layout is known', (t) async {
    silentDuoChannels(t);
    final source = ChannelDuoLayoutSource();
    final c = JarvisController(FakeApi(), MemoryVault());
    await t.pumpWidget(JarvisApp(controller: c, duoLayout: source));
    await t.pump(const Duration(milliseconds: 300));
    expect(c.initialized, isTrue);
    expect(source.resolved.value, isFalse);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(JarvisHome), findsNothing);
    await t.pump(const Duration(milliseconds: 500));
    expect(source.resolved.value, isTrue, reason: '700 ms fallback');
    await t.pump(const Duration(milliseconds: 1500));
    expect(find.byType(LoginPage), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    source.dispose();
  });

  testWidgets('disposing the app unhooks its listener from the layout source', (
    t,
  ) async {
    silentDuoChannels(t);
    final source = ChannelDuoLayoutSource();
    final c = JarvisController(FakeApi(), MemoryVault());
    await t.pumpWidget(JarvisApp(controller: c, duoLayout: source));
    // ignore: invalid_use_of_protected_member
    expect(source.resolved.hasListeners, isTrue);
    await t.pumpWidget(const SizedBox());
    // ignore: invalid_use_of_protected_member
    expect(source.resolved.hasListeners, isFalse);
    source.dispose();
  });

  group('StartupGate', () {
    Widget gate({
      required bool ready,
      Alignment align = Alignment.topLeft,
      Size box = const Size(300, 250),
    }) => MaterialApp(
      home: StartupGate(
        ready: ready,
        child: Scaffold(
          body: Align(
            alignment: align,
            child: SizedBox.fromSize(
              size: box,
              child: const StartupReactorLanding(),
            ),
          ),
        ),
      ),
    );

    testWidgets('ready true -> false -> true flies again and lands again', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(gate(ready: false));
      await t.pumpWidget(gate(ready: true));
      await t.pump();
      await t.pump(const Duration(milliseconds: 1000));
      await t.pump();
      expect(
        t.getRect(find.byType(LoginScene)),
        const Rect.fromLTWH(0, 0, 300, 250),
      );

      await t.pumpWidget(gate(ready: false));
      await t.pump();
      final centre = t.getRect(find.byType(LoginScene));
      expect(centre.center, const Offset(200, 434.5));
      expect(centre.size, const Size(176, 176));

      await t.pumpWidget(gate(ready: true));
      await t.pump();
      await t.pump(const Duration(milliseconds: 1000));
      await t.pump();
      expect(
        t.getRect(find.byType(LoginScene)),
        const Rect.fromLTWH(0, 0, 300, 250),
      );
      expect(find.byType(LoginScene), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the flight follows a landing box that moves meanwhile', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(gate(ready: false));
      await t.pumpWidget(gate(ready: true));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      // The page settles elsewhere (keyboard, layout update) while the reactor is in flight.
      await t.pumpWidget(gate(ready: true, align: Alignment.bottomRight));
      await t.pump(const Duration(milliseconds: 800));
      await t.pump();
      expect(
        t.getRect(find.byType(LoginScene)),
        Rect.fromLTWH(100, 619, 300, 250),
        reason: 'lands where the box is now, not where it was measured',
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });
}

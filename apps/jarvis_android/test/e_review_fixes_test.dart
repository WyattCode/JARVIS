import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/vault.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/duo_rail.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'c2_support.dart' show sizeWindow;
import 'c3_support.dart';
import 'support.dart';
import 'voice_support.dart';

/// Signing out takes as long as the test says.
class SlowLogoutApi extends FakeApi {
  final response = Completer<void>();
  int calls = 0;
  @override
  Future<void> logout() async {
    calls++;
    await response.future;
    cookie = null;
  }
}

/// Writes fail once [failing] is set (a locked Keychain, a full disk).
class BrokenVault extends MemoryVault {
  bool failing = false;
  int writes = 0;
  @override
  Future<void> write(String value) async {
    writes++;
    if (failing) throw Exception('keychain locked');
    await super.write(value);
  }
}

class ErasableVault extends BrokenVault implements StateEraser {
  int erased = 0;
  @override
  Future<void> eraseState() async {
    erased++;
    value = null;
  }
}

/// While [held] is set, the next write waits for it and then fails; later ones go through.
class HeldVault extends MemoryVault {
  Completer<void>? held;
  int writes = 0;
  @override
  Future<void> write(String value) async {
    writes++;
    final gate = held;
    if (gate != null) {
      held = null;
      await gate.future;
      throw Exception('disk full');
    }
    await super.write(value);
  }
}

/// A job the server finished while the app was suspended.
class FinishedJobApi extends FakeApi {
  int asked = 0;
  @override
  Future<Map<String, dynamic>> jobStatus(String id) async {
    asked++;
    return {
      'status': 'completed',
      'kind': 'image',
      'urls': ['https://example.test/cat.png'],
    };
  }
}

class OfflineApi extends FakeApi {
  @override
  Future<List<ModelInfo>> models() async =>
      throw const SocketException('offline');
}

Future<void> frames(WidgetTester t, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

/// Frames with real time in between, for the file work signing out does (the cached media folders).
Future<void> settleIo(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await t.pump(const Duration(milliseconds: 16));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
  await frames(t, 40);
}

Finder settingsScroll() => find
    .descendant(
      of: find.byKey(const Key('settings-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

NavigatorState navigatorOf(WidgetTester t) =>
    t.widget<MaterialApp>(find.byType(MaterialApp)).navigatorKey!.currentState!;

void main() {
  group('sign out and erase', () {
    testWidgets(
      'a failed erase is said on the login page (the settings page is gone by then)',
      (t) async {
        final api = SlowLogoutApi();
        final vault = BrokenVault();
        final c = JarvisController(api, vault, audioDevice: FakeAudio());
        await t.pumpWidget(JarvisApp(controller: c));
        await t.pump();
        await t.pump();
        await c.login('user', 'test');
        await frames(t, 70);
        c.current.messages.add(ChatMessage('user', '不应留下'));
        await c.save();
        unawaited(
          navigatorOf(t).push(
            MaterialPageRoute<void>(
              // The wiring of the app (jarvis_app.dart), not a stub.
              builder: (_) => SettingsPage(
                controller: c,
                onLogoutAndClear: c.clearLocalData,
              ),
            ),
          ),
        );
        await frames(t);
        await t.scrollUntilVisible(
          find.text('退出登录'),
          350,
          scrollable: settingsScroll(),
        );
        await t.tap(find.text('退出登录'));
        await t.pumpAndSettle();
        await t.tap(find.text('退出并清除本机数据'));
        await t.pumpAndSettle();
        vault.failing = true;
        await t.tap(find.text('退出并清除'));
        await t.pump();
        for (var i = 0; i < 8 && api.calls == 0; i++) {
          await t.pump();
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        expect(api.calls, 1);
        // The network sign-out is slow: the settings page leaves before the erase is done.
        await frames(t, 40);
        expect(find.byType(SettingsPage), findsNothing);
        api.response.complete();
        await settleIo(t, () => c.error != null);
        expect(find.byType(LoginPage), findsOneWidget);
        expect(find.text('未能清除本机数据，请稍后重试'), findsOneWidget);
        // The saved file still holds the history: nothing claims it was erased.
        expect(vault.value, contains('不应留下'));
        expect(c.persistFailed, isTrue);
        await t.pumpWidget(const SizedBox());
      },
    );

    test('a failed last write deletes the saved file instead', () async {
      final vault = ErasableVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.login('user', 'test');
      c.current.messages.add(ChatMessage('user', '历史'));
      await c.save();
      expect(vault.value, contains('jarvis_session'));
      vault.failing = true;
      expect(await c.clearLocalData(), isTrue);
      expect(vault.erased, 1);
      // Nothing is left for the next launch to sign in with.
      expect(vault.value, isNull);
      expect(c.error, isNull);
      expect(c.persistFailed, isFalse);
      // The cleared state is still written once the vault works again.
      vault.failing = false;
      await c.saveIfDirty();
      expect(vault.value, isNot(contains('历史')));
      expect(vault.value, isNot(contains('jarvis_session')));
      c.dispose();
    });
  });

  test(
    'a voice job past its deadline is asked about before it is given up',
    () async {
      final api = FinishedJobApi();
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await c.login('user', 'test');
      // The first poll comes after the deadline, as after a long suspension.
      c.voicePollInterval = const Duration(milliseconds: 40);
      c.voicePollDeadline = const Duration(milliseconds: 1);
      final owner = c.current;
      c.voiceTask(owner, {
        'type': 'call',
        'call_id': 'call_1',
        'name': 'generate_image',
        'arguments': '{"prompt":"猫"}',
      });
      c.voiceTask(owner, {
        'type': 'localrouter.job.created',
        'job_id': 'job_1',
      });
      final task = owner.tasks.single;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(api.asked, 1);
      expect(task.status, 'completed');
      expect(task.urls, ['https://example.test/cat.png']);
      c.dispose();
    },
  );

  group('saveIfDirty', () {
    test(
      'a draft-only save does not count as having written everything',
      () async {
        final vault = MemoryVault();
        final c = JarvisController(FakeApi(), vault);
        await c.initialize();
        await c.login('user', 'test');
        final first = c.current;
        first.messages.add(ChatMessage('user', '第一条'));
        c.newConversation();
        await c.save();
        // A change the draft-only path does not re-encode (another conversation), then typing in this one.
        first.messages.add(ChatMessage('assistant', '后来的回复'));
        c.setDraft('草稿');
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(vault.value, contains('草稿'), reason: 'the cheap save ran');
        // Going to the background writes the rest.
        await c.saveIfDirty();
        expect(vault.value, contains('后来的回复'));
        c.dispose();
      },
    );

    test('a write still running that then fails is tried again', () async {
      final vault = HeldVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.login('user', 'test');
      await c.save();
      final gate = vault.held = Completer<void>();
      c.setDraft('要保存');
      // Going inactive starts the write; paused arrives while it is still running.
      final inactive = c.saveIfDirty();
      final paused = c.saveIfDirty();
      await Future<void>.delayed(Duration.zero);
      final tries = vault.writes;
      gate.complete();
      await inactive;
      await paused;
      expect(vault.writes, tries + 1, reason: 'tried again, once');
      expect(vault.value, contains('要保存'));
      expect(c.persistFailed, isFalse);
      c.dispose();
    });
  });

  testWidgets(
    'signing out of an offline session takes the settings page away',
    (t) async {
      final vault = MemoryVault();
      final first = JarvisController(
        FakeApi()..cookie = '__Host-jarvis_session=test',
        vault,
      );
      await first.initialize();
      first.current.messages.add(ChatMessage('user', '本地历史'));
      await first.save();
      first.dispose();
      final c = JarvisController(
        OfflineApi()..cookie = '__Host-jarvis_session=test',
        vault,
        audioDevice: FakeAudio(),
      );
      c.offlineRetryDelay = (_) => const Duration(minutes: 10);
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(seconds: 4));
      await t.pump(const Duration(milliseconds: 1500));
      expect(c.offlineSession, isTrue);
      expect(find.byType(JarvisHome), findsOneWidget);
      unawaited(
        navigatorOf(t).push(
          MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c)),
        ),
      );
      await frames(t);
      expect(find.byType(SettingsPage), findsOneWidget);
      unawaited(c.logout());
      await settleIo(t, () => false);
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(navigatorOf(t).canPop(), isFalse);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a fling that ends while the settings page relays out', (
    t,
  ) async {
    final c = await pumpSettings3(t);
    await t.fling(settingsScroll(), const Offset(0, -2500), 6000);
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 16));
    // The window grows mid-fling: the page relays out and the fling stops inside that layout.
    sizeWindow(
      t,
      const Size(1200, 3000),
      const EdgeInsets.only(top: 62, bottom: 34),
    );
    await t.pump();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    sizeWindow(
      t,
      const Size(402, 874),
      const EdgeInsets.only(top: 62, bottom: 34),
    );
    await t.pumpAndSettle();
    await t.fling(settingsScroll(), const Offset(0, -5000), 8000);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    // At the end the last chip is the active one, measured after the frame.
    final state = t.state(find.byType(SettingsPage)) as dynamic;
    expect(
      (state.active as ValueNotifier<int>).value,
      (state.sectionKeys as List).length - 1,
    );
    await end(t, c);
  });

  testWidgets('an appearance the window did not take is sent again', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final sent = <Object?>[];
    const channel = MethodChannel('ai.jarvis.app/appearance');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      sent.add(call.arguments);
      // The window is not attached yet the first time.
      if (sent.length == 1) throw PlatformException(code: 'no_window');
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    try {
      final c = JarvisController(FakeApi(), MemoryVault());
      await t.pumpWidget(
        JarvisApp(controller: c, duoLayout: ValueNotifier(DuoLayout.none)),
      );
      await t.pump();
      // Any later build (the launch, signing in) tries again; the theme is the same.
      await c.login('user', 'test');
      await frames(t, 10);
      expect(sent, ['dark', 'dark']);
      await frames(t, 10);
      expect(sent, ['dark', 'dark'], reason: 'sent once it went through');
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('the bottom rail controls while the keyboard stays up', () {
    test('a keyboard that grows and shrinks back keeps them stacked', () {
      double lift(double k) => DuoRail.liftFor(k, 700);
      expect(lift(0), 1);
      for (final k in [100.0, 200.0, 300.0]) {
        lift(k);
      }
      expect(DuoRail.keyboardSettled(), 0);
      // Text to emoji keyboard and back (or the suggestion bar on and off), staying up.
      for (final k in [320.0, 340.0, 320.0, 300.0]) {
        expect(lift(k), 0, reason: 'keyboard at $k');
      }
      expect(DuoRail.keyboardSettled(), 0);
      expect(lift(300), 0);
      // Going down for real they still follow it from where it stood.
      expect(lift(150), closeTo(.5, .01));
      expect(lift(0), 1);
      // The next rise is measured against where it stood (300), not its peak (340): it ends stacked.
      expect(lift(150), closeTo(.5, .01));
      expect(lift(300), 0);
      expect(lift(0), 1);
    });

    test(
      'a keyboard that shrinks while up ends stacked once it stands still',
      () {
        double lift(double k) => DuoRail.liftFor(k, 710);
        expect(lift(0), 1);
        lift(200);
        lift(340);
        expect(DuoRail.keyboardSettled(), 0);
        // The suggestion bar goes: it cannot be told from a dismissal until the keyboard stops.
        final between = lift(300);
        expect(between, greaterThan(0));
        expect(between, lessThan(.2));
        expect(DuoRail.keyboardSettled(), 0);
        expect(lift(300), 0, reason: 'steady again, at its new height');
        expect(lift(0), 1);
        // The next rise ends stacked at that height.
        expect(lift(300), 0);
        expect(lift(0), 1);
      },
    );

    testWidgets(
      'a native rail made with the keyboard up starts lifted and stacks once it stands still',
      (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final created = <Map<Object?, Object?>>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async {
            if (call.method == 'create') {
              created.add(call.arguments as Map<Object?, Object?>);
            }
            return null;
          },
        );
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          ),
        );
        final layout = DuoLayout.fromMap({
          'edge': 'right',
          'width': 951.0,
          'height': 669.0,
          'safe': {'left': 0.0, 'top': 0.0, 'right': 84.0, 'bottom': 34.0},
          'regions': [
            {
              'kind': 'occlusion',
              'active': true,
              'x': 867.0,
              'y': 0.0,
              'w': 84.0,
              'h': 124.0,
            },
          ],
        });
        DuoRailAction action(String id) => DuoRailAction(
          id: id,
          icon: Icons.circle,
          symbol: 'circle',
          label: id,
          onPressed: () {},
        );
        Widget rail(double keyboard) => DuoLayoutScope(
          layout: ValueNotifier(layout),
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(951, 669),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: Stack(
                children: [
                  DuoRail(top: [action('a')], bottom: [action('b')]),
                ],
              ),
            ),
          ),
        );
        try {
          expect(DuoRail.liftFor(0, 669), 1);
          await t.pumpWidget(rail(100));
          await t.pump();
          expect(created, hasLength(1));
          final raw = created.single['params'];
          final params = const StandardMessageCodec().decodeMessage(
            raw is ByteData
                ? raw
                : ByteData.sublistView(Uint8List.fromList(raw as List<int>)),
          ) as Map<Object?, Object?>;
          final start = params['lift'] as double;
          expect(start, greaterThan(0));
          expect(start, lessThan(1), reason: 'not at rest, then jumping');
          final lifts = <Object?>[];
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel('ai.jarvis.app/duo-rail/${created.single['id']}'),
            (call) async {
              if (call.method == 'lift') lifts.add(call.arguments);
              return null;
            },
          );
          // The keyboard stays at this height: the controls stand stacked.
          await t.pump(const Duration(milliseconds: 250));
          expect(lifts, [0.0]);
          await t.pumpWidget(const SizedBox());
          expect(DuoRail.liftFor(0, 669), 1);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}

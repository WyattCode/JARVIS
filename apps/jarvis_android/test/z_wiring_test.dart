import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/vault.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

class UnreadableVault extends MemoryVault implements UnreadableKeeper {
  int kept = 0;
  bool broken = true;
  @override
  Future<String?> read() async =>
      broken ? throw Exception('keychain locked') : super.read();
  @override
  Future<void> keepUnreadable() async {
    kept++;
  }
}

void main() {
  testWidgets('read-only storage offers a confirmed way out: start fresh', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 800);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final vault = UnreadableVault();
    final c = JarvisController(FakeApi(), vault);
    await c.initialize();
    addTearDown(c.dispose);
    expect(c.storageReadOnly, isTrue);
    await t.pumpWidget(
      DuoLayoutScope(
        layout: ValueNotifier(DuoLayout.none),
        child: MaterialApp(home: JarvisHome(controller: c)),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));

    await t.tap(find.byKey(const Key('start-fresh')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('从空白开始？'), findsOneWidget);

    // Cancelling changes nothing.
    await t.tap(find.text('取消'));
    await t.pump(const Duration(milliseconds: 400));
    expect(c.storageReadOnly, isTrue);

    await t.tap(find.byKey(const Key('start-fresh')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.widgetWithText(FilledButton, '从空白开始'));
    await t.pump(const Duration(milliseconds: 400));
    expect(vault.kept, 1);
    expect(c.storageReadOnly, isFalse);
    expect(find.byKey(const Key('start-fresh')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a refused microphone offers Settings, other failures do not', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    addTearDown(c.dispose);
    late BuildContext context;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    c.voice
      ..error = '需要麦克风权限才能语音通话，请在系统设置中允许'
      ..permissionDenied = true;
    var opened = 0;
    reportCallFailure(context, c, openSettings: () async => opened++);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('去设置'), findsOneWidget);
    await t.tap(find.text('去设置'));
    expect(opened, 1);

    ScaffoldMessenger.of(context).clearSnackBars();
    await t.pumpAndSettle();
    c.voice
      ..error = '语音服务暂时不可用'
      ..permissionDenied = false;
    reportCallFailure(context, c);
    await t.pump();
    expect(find.text('语音服务暂时不可用'), findsOneWidget);
    expect(find.text('去设置'), findsNothing);
    await t.pumpAndSettle(const Duration(seconds: 4));
  });
}

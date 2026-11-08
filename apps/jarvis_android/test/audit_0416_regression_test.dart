import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'support.dart';

class PendingDownloadApi extends FakeApi {
  final result = Completer<Uint8List>();
  @override
  Uri mediaUri(String path) {
    // Match the production transport's scheme validation without starting image HTTP requests.
    if (path.startsWith('file:')) {
      throw const FormatException('invalid media URL');
    }
    return super.mediaUri(path);
  }

  @override
  Future<Uint8List> download(String url) => result.future;
}

void main() {
  testWidgets(
    'A removed media card cannot open a file dialog after its download finishes',
    (t) async {
      final api = PendingDownloadApi(), calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('cc.odn.jarvis/files'),
            (call) async {
              calls.add(call);
              return true;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('cc.odn.jarvis/files'),
              null,
            ),
      );
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaCard(
              controller: c,
              task: MediaTask(
                id: 'gone',
                kind: 'video',
                prompt: 'done',
                args: {},
                status: 'completed',
                urls: ['https://example.test/video.mp4'],
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('下载'));
      await t.pump();
      await t.pumpWidget(const SizedBox());
      api.result.complete(Uint8List.fromList([1, 2, 3]));
      await t.pump();
      await t.pump();
      expect(
        calls,
        isEmpty,
        reason:
            'do not interrupt another screen with a stale native file dialog',
      );
      c.dispose();
    },
  );

  for (final action in ['下载', '分享']) {
    testWidgets('Leaving media preview cancels late $action dialog', (t) async {
      final api = PendingDownloadApi(), calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('cc.odn.jarvis/files'),
            (call) async {
              calls.add(call);
              return true;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('cc.odn.jarvis/files'),
              null,
            ),
      );
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          home: MediaPreview(
            controller: c,
            kind: 'image',
            url: 'file:///invalid-image',
            prompt: 'preview',
          ),
        ),
      );
      await t.tap(find.byTooltip(action));
      await t.pump();
      await t.pumpWidget(const SizedBox());
      api.result.complete(
        Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      );
      await t.pump();
      await t.pump();
      expect(
        calls,
        isEmpty,
        reason: 'leaving preview must not open a dialog over another screen',
      );
      c.dispose();
    });
  }
  testWidgets('A visible media card still opens its requested save dialog', (
    t,
  ) async {
    final api = PendingDownloadApi(), calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('cc.odn.jarvis/files'), (
          call,
        ) async {
          calls.add(call);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('cc.odn.jarvis/files'),
            null,
          ),
    );
    final c = JarvisController(api, MemoryVault());
    await c.initialize();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCard(
            controller: c,
            task: MediaTask(
              id: 'visible',
              kind: 'video',
              prompt: 'ready',
              args: {},
              status: 'completed',
              urls: ['https://example.test/video.mp4'],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('下载'));
    await t.pump();
    api.result.complete(Uint8List.fromList([1, 2, 3]));
    await t.pump();
    await t.pump();
    expect(calls.map((c) => c.method), ['save']);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Blank rename stays in the dialog and cannot silently submit', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(860, 608);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    final old = c.current.title;
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump();
    await openConversationMenu(t);
    await t.tap(find.text('重命名'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final field = find.byKey(const Key('rename-field'));
    await t.enterText(field, '   ');
    await t.pump();
    final save = t.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    expect(
      save.onPressed,
      isNull,
      reason: 'blank name must not present an enabled save action',
    );
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('rename-dialog')), findsOneWidget);
    expect(c.current.title, old);
    await t.enterText(field, '  合法会话名  ');
    await t.pump();
    await t.tap(find.text('保存'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(c.current.title, '合法会话名');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

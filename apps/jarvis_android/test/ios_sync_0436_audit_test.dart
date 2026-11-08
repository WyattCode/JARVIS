import 'dart:async';

import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'support.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/ui/markdown_style.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';

void main() {
  test('Video cover images are not mistaken for actual videos', () {
    for (final url in [
      '/v1/videos/video_a/poster.jpg',
      '/videos/album/photo.png',
      'https://example.test/videos/cover.webp',
    ]) {
      final task = MediaTask(
        id: 'a',
        kind: 'image',
        prompt: '',
        args: {},
        urls: [url],
      )..settleKind();
      expect(task.kind, 'image', reason: url);
    }
    expect(MediaTask.isVideoUrl('/v1/videos/video_a/content'), isTrue);
    expect(MediaTask.isVideoUrl('/assets/videos/clip.MP4?token=x'), isTrue);
  });
  testWidgets('Clipboard failure is visible and does not claim success', (
    t,
  ) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CodeBlock(code: 'one')),
      ),
    );
    await t.tap(find.text('复制'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('复制失败'), findsOneWidget);
    expect(find.text('已复制'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 2));
  });
  testWidgets('Late clipboard receipt cannot confirm a different code block', (
    t,
  ) async {
    final done = Completer<void>();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') await done.future;
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    Widget host(String code) => MaterialApp(
      home: Scaffold(body: CodeBlock(code: code)),
    );
    await t.pumpWidget(host('one'));
    await t.tap(find.text('复制'));
    await t.pump();
    expect(find.text('复制中'), findsOneWidget);
    await t.pumpWidget(host('two'));
    done.complete();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('已复制'), findsNothing);
    expect(find.text('复制'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('Long setting labels fit a narrow pane with large text', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 600);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: PickerRow<int>(
            label: '回答前等待时长',
            options: const [(5000, '5 秒')],
            value: 5000,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await t.pump();
    expect(t.takeException(), isNull);
    final arrow = find.byIcon(Icons.unfold_more_rounded);
    final row = find.byType(PickerRow<int>);
    expect(t.getRect(row).right - t.getRect(arrow).right, closeTo(16, .1));
    await t.tap(find.text('回答前等待时长'));
    await t.pumpAndSettle();
    expect(find.text('5 秒'), findsWidgets);
    expect(t.takeException(), isNull);
  });
  testWidgets('Rapid section changes finish on the last requested group', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(425, 623);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('settings-chip-3')));
    await t.pump(const Duration(milliseconds: 40));
    await t.tap(find.byKey(const ValueKey('settings-chip-2')));
    await t.pump(const Duration(milliseconds: 40));
    await t.tap(find.byKey(const ValueKey('settings-chip-1')));
    await t.pumpAndSettle();
    expect(t.widget<SettingsChips>(find.byType(SettingsChips)).active.value, 1);
    expect(
      find
          .byWidgetPredicate((w) => w is PickerRow<String> && w.label == '思考深度')
          .hitTestable(),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
    c.dispose();
    expect(t.takeException(), isNull);
  });
  testWidgets('Fenced code renders a scrollable code block in real Markdown', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MarkdownBody(
              data: '```dart\nprint(1);\n```',
              styleSheet: chatMarkdownStyle(context, 20),
              builders: chatMarkdownBuilders(20),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(t.widget<CodeBlock>(find.byType(CodeBlock)).fontSize, 18);
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('print(1);'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}

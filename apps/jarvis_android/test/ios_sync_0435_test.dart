import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/settings_widgets.dart';
import 'package:jarvis_android/ui/markdown_style.dart';

import 'support.dart';

void main() {
  test('Video results and restored history recover missing kind', () {
    for (final url in [
      '/v1/videos/video_a/content',
      'https://example.test/out.MP4?key=x',
      '/clip.webm',
    ]) {
      final t = MediaTask(
        id: 'a',
        kind: 'image',
        prompt: '',
        args: {},
        urls: [url],
      )..settleKind();
      expect(t.kind, 'video');
      final restored = MediaTask.fromJson({...t.toJson(), 'kind': 'image'});
      expect(restored.kind, 'video');
    }
    final image = MediaTask(
      id: 'b',
      kind: 'image',
      prompt: '',
      args: {},
      urls: ['/image.png'],
    );
    image.settleKind();
    expect(image.kind, 'image');
  });
  testWidgets(
    'Settings keep every section reachable across Android windows and font scales',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final size in [
        const Size(360, 560),
        const Size(425, 623),
        const Size(436, 948),
        const Size(608, 860),
        const Size(860, 608),
      ]) {
        for (final scale in [1.0, 1.5]) {
          t.view.physicalSize = size;
          final c = JarvisController(FakeApi(), MemoryVault());
          await c.initialize();
          await t.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: SettingsPage(controller: c),
            ),
          );
          await t.pump();
          expect(
            t.takeException(),
            isNull,
            reason: '$size text=$scale initial',
          );
          final effort = find.byWidgetPredicate(
            (w) => w is PickerRow<String> && w.label == '思考深度',
          );
          await t.ensureVisible(effort);
          await t.pump();
          await t.tap(effort);
          await t.pumpAndSettle();
          await t.tap(find.text('低').last);
          await t.pumpAndSettle();
          expect(c.effort, 'low');
          final font = find.byKey(const Key('message-font-size'));
          await t.ensureVisible(font);
          await t.pump();
          t.widget<Slider>(font).onChanged!(20);
          await t.pump();
          expect(c.settings.messageFontSize, 20);
          final exit = find.text('退出登录');
          await t.ensureVisible(exit);
          await t.pump();
          expect(exit.hitTestable(), findsOneWidget);
          expect(
            t.takeException(),
            isNull,
            reason: '$size text=$scale controls',
          );
          await t.pumpWidget(const SizedBox());
          c.dispose();
        }
      }
    },
  );
  testWidgets('Code copy confirms in place and font follows preference', (
    t,
  ) async {
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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
        home: Scaffold(
          body: CodeBlock(code: 'print(1);', language: 'dart', fontSize: 18),
        ),
      ),
    );
    expect(
      t.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize,
      18,
    );
    await t.tap(find.text('复制'));
    await t.pump(const Duration(milliseconds: 200));
    expect(copied, ['print(1);']);
    expect(find.text('已复制'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('复制'), findsOneWidget);
  });
}

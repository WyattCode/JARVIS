import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/reply_action_button.dart';
import 'package:jarvis_android/ui/status_page.dart';

import 'support.dart';

void main() {
  test('Display names preserve acronyms and leave model IDs untouched', () {
    final model = ModelInfo('qwen3-asr-1.7b', 'qwen3-asr-1.7b');
    expect(displayModelName(model.name), 'Qwen3-ASR-1.7b');
    expect(model.id, 'qwen3-asr-1.7b');
    expect(displayModelName('minimax-h3'), 'MiniMax-H3');
    expect(displayModelName('fishaudio/drama-3'), 'FishAudio/Drama-3');
    expect(displayModelName('GLM-5.3-Flash-EXL3'), 'GLM-5.3-Flash-EXL3');
  });
  testWidgets(
    'The bar has no title or status dot; the more menu opens model status',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(425, 623);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await t.pump();
      expect(find.byKey(const ValueKey('chat-heading-line')), findsNothing);
      expect(find.byKey(const Key('connection-dot')), findsNothing);
      await t.tap(find.byTooltip('更多操作'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('模型状态'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(StatusPage), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('Compact reply actions retain 48dp targets and copy text once', (
    t,
  ) async {
    final calls = <MethodCall>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
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
      MaterialApp(
        home: Scaffold(
          body: ReplyActionButton(
            tooltip: '复制回复',
            icon: Icons.copy_outlined,
            onPressed: () =>
                Clipboard.setData(const ClipboardData(text: '复制正文')),
          ),
        ),
      ),
    );
    final action = find.byType(ReplyActionButton);
    expect(t.getSize(action), const Size(48, 48));
    await t.tap(action);
    await t.pump();
    final writes = calls.where((c) => c.method == 'Clipboard.setData').toList();
    expect(writes.length, 1);
    expect(writes.single.arguments, {'text': '复制正文'});
  });
}

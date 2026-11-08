import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'support.dart';

/// The chat's own bar, as the iOS app has it.
void main() {
  Future<JarvisController> home(WidgetTester t, Size size) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
    await t.pump();
    return c;
  }

  testWidgets('the list button at the left; new and more at the right', (
    t,
  ) async {
    final c = await home(t, const Size(425, 623));
    final list = t.getRect(find.byTooltip('展开会话'));
    final fresh = t.getRect(find.byKey(const Key('start-new-chat')));
    final more = t.getRect(find.byTooltip('更多操作'));
    expect(list.left, lessThan(60));
    expect(fresh.right, lessThanOrEqualTo(more.left + 1));
    expect(more.right, greaterThan(425 - 60));
    expect(find.byKey(const ValueKey('chat-heading-line')), findsNothing);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('the more menu: settings, the works, the model status', (
    t,
  ) async {
    final c = await home(t, const Size(425, 623));
    await t.tap(find.byTooltip('更多操作'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('作品'), findsOneWidget);
    expect(find.text('模型状态'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a starter\'s prompt goes after what is written', (t) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c.addStarterPrompt('第一句');
    expect(c.current.draft, '第一句');
    c.addStarterPrompt('第二句');
    expect(c.current.draft, '第一句\n第二句');
    c.current.draft = '   ';
    c.addStarterPrompt('第三句');
    expect(c.current.draft, '第三句');
    c.dispose();
  });
}

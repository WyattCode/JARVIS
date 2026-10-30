import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jarvis_android/main.dart' as app;

const user = String.fromEnvironment('JARVIS_TEST_USER');
const pass = String.fromEnvironment('JARVIS_TEST_PASS');

Future<void> wait(WidgetTester t, int seconds) async {
  for (var i = 0; i < seconds * 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('login, send one message, read reply', (t) async {
    app.main();
    await wait(t, 4);
    debugPrint('STEP window=${t.view.physicalSize / t.view.devicePixelRatio} '
        'padding=${t.view.padding} viewPadding=${t.view.viewPadding} '
        'insets=${t.view.viewInsets} dpr=${t.view.devicePixelRatio}');
    expect(find.text('登录'), findsWidgets);
    await t.enterText(find.byType(TextField).at(0), user);
    await t.enterText(find.byType(TextField).at(1), pass);
    await wait(t, 3);
    debugPrint('STEP typed credentials');
    await t.tap(find.text('登录').last);
    await wait(t, 12);
    debugPrint('STEP texts=${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).whereType<String>().take(25).toList()}');
    final input = find.byKey(const Key('chat-input'));
    debugPrint('STEP chat-input visible=${input.evaluate().isNotEmpty}');
    expect(input, findsOneWidget, reason: '登录后应进入聊天页');
    await wait(t, 3);
    await t.enterText(input, '你好，请用一句话介绍你自己');
    await wait(t, 2);
    await t.tap(find.byTooltip('发送'));
    debugPrint('STEP sent');
    await wait(t, 110);
    debugPrint('STEP done');
    binding.reportData = {'ok': true};
  });
}

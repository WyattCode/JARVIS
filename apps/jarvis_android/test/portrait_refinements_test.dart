import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/adaptive_layout.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/login_art.dart';

import 'support.dart';

void main() {
  test('Tall-phone sidebar widens without changing fold-profile width', () {
    expect(AdaptiveLayout.forWindow(400, 869).sidebarWidth, closeTo(286, .1));
    expect(
      AdaptiveLayout.forWindow(425, 623).sidebarWidth,
      closeTo(425 * .65, .1),
    );
  });
  testWidgets(
    'Tall-phone home, voice target and one-line title use available space',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 869);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: JarvisHome(controller: c),
        ),
      );
      await t.pump();
      expect(
        t.widget<CoreAvatar>(find.byType(CoreAvatar)).size,
        greaterThanOrEqualTo(320),
      );
      expect(
        t.getSize(find.byKey(const ValueKey('starter-0'))).height,
        greaterThanOrEqualTo(64),
      );
      final voice = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '语音对话',
      );
      final button = t.widget<IconButton>(voice);
      expect(button.style!.fixedSize!.resolve({}), const Size(36, 36));
      expect(t.getSize(voice).width, greaterThanOrEqualTo(48));
      final first = t.state(find.byType(LoginScene));
      c.newConversation();
      await t.pump();
      expect(identical(first, t.state(find.byType(LoginScene))), isFalse);
      c.current.title = '这是一条足够长的会话标题，用来验证单行省略';
      c.current.messages.add(ChatMessage('user', '你好'));
      c.notifyDraftSuggestion();
      await t.pump();
      // The bar has no title (as on iOS), however long the conversation's is.
      expect(find.byKey(const ValueKey('chat-heading-line')), findsNothing);
      expect(find.text(c.current.title), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

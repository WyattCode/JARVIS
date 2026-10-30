import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/duo_layout.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';

import 'b_chat_ui_test.dart' show pumpPhone;
import 'support.dart';

/// The outer display of a foldable on its side is 678 x 466 pt: short and wide.
const outerLandscape = Size(678, 466);

void main() {
  for (final scale in [1.0, 1.3, 1.5, 2.0, 2.4]) {
    testWidgets(
      'short landscape: the composer is one row, not a field over a row of buttons (text x$scale)',
      (t) async {
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpPhone(t, size: outerLandscape);
        final frame = t.getRect(find.byKey(const Key('composer-frame')));
        if (scale == 1.0) expect(frame.height, lessThan(80));
        // The attach button, the effort menu and the field share the row.
        final field = t.getRect(find.byKey(const Key('chat-input')));
        final attach = t.getRect(find.byTooltip('添加附件'));
        final effort = t.getRect(find.byTooltip('选择思考深度'));
        expect(attach.center.dy, closeTo(field.center.dy, 1), reason: 'attach');
        expect(effort.center.dy, closeTo(field.center.dy, 1), reason: 'effort');
        expect(effort.right, lessThanOrEqualTo(field.left + 1));
        // The effort label and the field's hint sit on one line.
        final label = t.getRect(find.textContaining('思考 ·'));
        final hint = t.getRect(find.text('发送消息…'));
        expect(label.center.dy, closeTo(field.center.dy, 1.5), reason: 'label');
        expect(label.center.dy, closeTo(hint.center.dy, 1), reason: 'hint');
        // The microphone is nudged up 2pt by design; the rest of the row is level with the field.
        final mic = t.getRect(find.byTooltip('语音对话'));
        expect(mic.center.dy, closeTo(field.center.dy, 2.5), reason: 'mic');
        // Typing swaps in the send button: it stays level too.
        await t.enterText(find.byKey(const Key('chat-input')), '你好');
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        final typed = t.getRect(find.byKey(const Key('chat-input')));
        final send = t.getRect(find.byTooltip('发送'));
        expect(send.center.dy, closeTo(typed.center.dy, 1), reason: 'send');
        expect(
          t.getRect(find.textContaining('思考 ·')).center.dy,
          closeTo(typed.center.dy, 1.5),
        );
        expect(t.takeException(), isNull);
        // The draft is saved half a second after the last change.
        await t.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets('portrait keeps the field over the row of buttons', (t) async {
    await pumpPhone(t);
    final field = t.getRect(find.byKey(const Key('chat-input')));
    final attach = t.getRect(find.byTooltip('添加附件'));
    expect(attach.top, greaterThanOrEqualTo(field.bottom - 1));
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'short landscape welcome: avatar, greeting and all four cards, side by side',
    (t) async {
      await pumpPhone(t, size: outerLandscape);
      await t.pump(const Duration(milliseconds: 400));
      final body = t.getRect(find.byKey(const Key('composer-frame'))).top;
      final avatar = t.getRect(find.byType(CoreAvatar));
      for (var i = 0; i < 4; i++) {
        final rect = t.getRect(find.byKey(ValueKey('starter-$i')));
        expect(rect.bottom, lessThanOrEqualTo(body + 1), reason: 'starter-$i');
        expect(rect.left, greaterThan(avatar.right), reason: 'starter-$i');
      }
      // Nothing comes and goes while the room changes (the keyboard, the header): the page just fades out for typing.
      await t.tap(find.byKey(const Key('chat-input')));
      await t.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(ValueKey('starter-$i')), findsOneWidget);
      }
      await t.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'short landscape login: the form sits beside the emblem and the button is in view',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = outerLandscape;
      t.view.padding = const FakeViewPadding(right: 84, bottom: 34);
      t.view.viewPadding = t.view.padding;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await t.pumpWidget(
        DuoLayoutScope(
          layout: ValueNotifier(DuoLayout.none),
          child: MaterialApp(home: LoginPage(controller: c)),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      final button = t.getRect(find.byType(FilledButton).first);
      expect(button.bottom, lessThanOrEqualTo(outerLandscape.height - 34));
      final reactor = t.getRect(find.byKey(const ValueKey('login-brand-row')));
      final field = t.getRect(find.byType(TextField).first);
      expect(field.left, greaterThan(reactor.left + 100));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

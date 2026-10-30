import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/call_controls.dart';

import 'support.dart';
import 'voice_support.dart';

class DeferredLogoutApi extends FakeApi {
  final response = Completer<void>();
  int calls = 0;
  @override
  Future<void> logout() async {
    calls++;
    await response.future;
    cookie = null;
  }
}

Future<void> frames(WidgetTester t, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets(
    'Delayed logout must retain the login route after settings reverse begins',
    (t) async {
      final api = DeferredLogoutApi();
      final c = JarvisController(api, MemoryVault(), audioDevice: FakeAudio());
      await t.pumpWidget(JarvisApp(controller: c));
      await t.pump();
      await t.pump();
      await c.login('AuditUser', 'test');
      await frames(t, 70);
      final nav = t
          .widget<MaterialApp>(find.byType(MaterialApp))
          .navigatorKey!
          .currentState!;
      unawaited(
        nav.push(
          MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c)),
        ),
      );
      await frames(t);
      final scroll = find
          .descendant(
            of: find.byKey(const Key('settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await t.scrollUntilVisible(find.text('退出登录'), 350, scrollable: scroll);
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      // Signing out asks first.
      await t.tap(find.widgetWithText(FilledButton, '退出登录'));
      await t.pump();
      for (var i = 0; i < 8 && api.calls == 0; i++) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      expect(api.calls, 1);
      expect(nav.canPop(), isFalse);
      api.response.complete();
      await frames(t, 70);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(SettingsPage), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Return to voice closes both the preview and works sheet, preserving the call',
    (t) async {
      final c = JarvisController(
        VoiceApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      c.models.add(
        ModelInfo(
          'speech',
          'Speech',
          kind: 'speech',
          defaultVoice: 'Atlas',
          voices: const [VoiceInfo('Atlas', 'Atlas', '')],
        ),
      );
      c.settings.speechModel = 'speech';
      c.settings.voices['speech'] = 'Atlas';
      c.current.tasks.add(
        MediaTask(
          id: 'pic',
          // A video: its card face is a placeholder, so a tap always opens the preview (an unreachable picture
          // turns the card into a retry button).
          kind: 'video',
          prompt: 'Audit',
          args: {},
          status: 'completed',
          urls: ['https://127.0.0.1:9/audit.mp4'],
        ),
      );
      await t.runAsync(() => c.voice.start(c.current));
      c.voice.ready = true;
      await t.pumpWidget(MaterialApp(home: JarvisHome(controller: c)));
      await frames(t);
      await t.tap(find.textContaining('生成作品 ·'));
      await frames(t);
      await t.tap(
        find
            .descendant(
              of: find.byType(MediaCard),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await frames(t);
      expect(find.byType(MediaPreview), findsOneWidget);
      expect(find.byType(HangupButton), findsOneWidget);
      await t.tap(find.byTooltip('返回语音界面'));
      await frames(t, 70);
      expect(find.byType(MediaPreview), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(c.voice.open, isTrue);
      expect(c.voice.active, isTrue);
      expect(find.byType(HangupButton), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => c.voice.stop());
      c.dispose();
    },
  );
}

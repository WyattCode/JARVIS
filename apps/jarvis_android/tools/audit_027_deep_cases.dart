import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import '../test/support.dart';
import '../test/voice_support.dart';

class DelayedLogoutApi extends FakeApi {
  final barrier = Completer<void>();
  int calls = 0;
  @override
  Future<void> logout() async {
    calls++;
    await barrier.future;
    cookie = null;
  }
}

void main() {
  testWidgets('Audit logout route race and media-to-voice return path', (
    t,
  ) async {
    final root = Directory('/home/user/.local/state/jarvis-audit-027-review3');
    await t.runAsync(() => root.create(recursive: true));
    final notes = <String, dynamic>{};
    await t.runAsync(() async {
      final bytes = ByteData.sublistView(
        await File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
            .readAsBytes(),
      );
      for (final family in ['Roboto', 'JarvisAudit']) {
        final loader = FontLoader(family)..addFont(Future.value(bytes));
        await loader.load();
      }
      final icon = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icon.load();
    });
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 869);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    var canvas = GlobalKey();
    Future<void> frames([int n = 24]) async {
      for (var i = 0; i < n; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    List<String> errors() {
      final result = <String>[];
      Object? e;
      while ((e = t.takeException()) != null) {
        result.add(e.toString());
      }
      return result;
    }

    Future<void> capture(String name) async {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pump();
      await t.runAsync(() async {
        final image =
            await (canvas.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    final api = DelayedLogoutApi();
    final c = JarvisController(api, MemoryVault(), audioDevice: FakeAudio());
    await t.pumpWidget(
      RepaintBoundary(
        key: canvas,
        child: JarvisApp(controller: c),
      ),
    );
    await t.pump();
    await t.pump();
    await c.login('AuditUser', 'test');
    await frames(70);
    final nav = t
        .widget<MaterialApp>(find.byType(MaterialApp))
        .navigatorKey!
        .currentState!;
    unawaited(
      nav.push(
        MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c)),
      ),
    );
    await frames();
    final scroll = find
        .descendant(
          of: find.byKey(const Key('settings-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await t.scrollUntilVisible(find.text('退出登录'), 350, scrollable: scroll);
    await frames();
    await capture('logout-01-settings');
    await t.tap(find.text('退出登录'));
    await t.pump();
    notes['logout_after_router_pop'] = {
      'can_pop': nav.canPop(),
      'settings_mounted': find
          .byType(SettingsPage, skipOffstage: false)
          .evaluate()
          .isNotEmpty,
    };
    for (var i = 0; i < 8 && api.calls == 0; i++) {
      await t.pump();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    notes['logout_request_started'] = api.calls;
    api.barrier.complete();
    await t.pump();
    await frames(70);
    notes['logout_completion_errors'] = errors();
    notes['logout_after_completion'] = {
      'login_pages': find.byType(LoginPage).evaluate().length,
      'home_pages': find.byType(JarvisHome).evaluate().length,
      'settings_pages': find.byType(SettingsPage).evaluate().length,
      'scaffolds': find.byType(Scaffold).evaluate().length,
      'navigator_mounted': nav.mounted,
    };

    try {
      await capture('logout-02-after-response');
    } catch (e) {
      notes['logout_capture_error'] = e.toString();
    }
    await t.pumpWidget(const SizedBox());
    await t.pump();
    notes['logout_teardown_errors'] = errors();
    // Actual works bottom sheet → image preview → Return to voice path.
    canvas = GlobalKey();
    final voiceApi = VoiceApi();
    final v = JarvisController(
      voiceApi,
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await v.initialize();
    v.models.add(
      ModelInfo(
        'speech',
        'Audit speech',
        kind: 'speech',
        defaultVoice: 'Atlas',
        voices: const [VoiceInfo('Atlas', 'Atlas', '')],
      ),
    );
    v.settings.speechModel = 'speech';
    v.settings.voices['speech'] = 'Atlas';
    v.current.tasks.add(
      MediaTask(
        id: 'audit-image',
        kind: 'image',
        prompt: 'Offline audit image',
        args: {},
        status: 'completed',
        urls: ['https://127.0.0.1:9/audit.png'],
      ),
    );
    await t.runAsync(() => v.voice.start(v.current));
    v.voice.ready = true;
    v.voice.status = '已就绪';
    await t.pumpWidget(
      RepaintBoundary(
        key: canvas,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'JarvisAudit',
            ),
          ),
          home: JarvisHome(controller: v),
        ),
      ),
    );
    await frames();
    final works = find.textContaining('生成作品 ·');
    await t.tap(works);
    await frames();
    await capture('return-voice-01-works');
    final image = find
        .descendant(of: find.byType(MediaCard), matching: find.byType(InkWell))
        .first;
    await t.tap(image);
    await frames();
    await capture('return-voice-02-preview');
    await t.tap(find.byTooltip('返回语音界面'));
    await frames(70);
    notes['return_to_voice'] = {
      'media_preview_still_visible': find
          .byType(MediaPreview)
          .evaluate()
          .isNotEmpty,
      'works_sheet_still_visible': find
          .byType(BottomSheet)
          .evaluate()
          .isNotEmpty,
      'voice_open': v.voice.open,
      'visible_media_cards': find.byType(MediaCard).evaluate().length,
    };
    await capture('return-voice-03-after-return');
    notes['return_errors'] = errors();
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => v.voice.stop());
    v.dispose();
    await t.runAsync(
      () =>
          File('${root.path}/findings-data.json')
              .writeAsString(const JsonEncoder.withIndent('  ').convert(notes)),
    );
  });
}

// Audit evidence only. Does not modify production state or contact real services.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/login_art.dart';
import 'package:jarvis_android/ui/startup_scene.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import '../test/support.dart';
import '../test/voice_support.dart';

void main() {
  testWidgets('Capture compatibility matrix and untested transitions', (
    t,
  ) async {
    final output = Directory(
      Platform.environment['JARVIS_AUDIT_DIR'] ??
          '/home/user/.local/state/jarvis-audit-027-review2',
    );
    final notes = <String, dynamic>{};
    await t.runAsync(() async {
      await output.create(recursive: true);
      final font = FontLoader('JarvisPreview')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
              ).readAsBytes(),
            ),
          ),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
    });
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewInsets);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    GlobalKey boundary = GlobalKey();
    final light = Platform.environment['JARVIS_AUDIT_LIGHT'] == '1';
    final theme = ThemeData(
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xff3e899b),
            brightness: light ? Brightness.light : Brightness.dark,
          ).copyWith(
            surface: light ? const Color(0xfff9faf9) : const Color(0xff0d0d0f),
            primary: light ? const Color(0xff28596a) : const Color(0xffe8e6df),
            surfaceContainerLow: light ? Colors.white : const Color(0xff20201f),
            surfaceContainerHighest: light
                ? const Color(0xffe8edeb)
                : const Color(0xff323230),
          ),
      fontFamily: 'JarvisPreview',
    );
    Future<void> show(Widget child, {double scale = 1}) async {
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('zh')],
            locale: const Locale('zh'),
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: child,
          ),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await t.pump();
    }

    Future<void> settle() async {
      for (var i = 0; i < 35; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> capture(String name) async {
      // Let newly exposed Image.asset resources decode without advancing the
      // test animation clock (first-frame keyboard evidence remains unchanged).
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pump();
      final errors = <String>[];
      Object? error;
      while ((error = t.takeException()) != null) {
        errors.add(error.toString());
      }
      if (errors.isNotEmpty) notes['errors-$name'] = errors;
      await t.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> reset(Size size) async {
      await t.pumpWidget(const SizedBox());
      boundary = GlobalKey();
      t.view.physicalSize = size;
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.padding = FakeViewPadding.zero;
      t.view.viewPadding = FakeViewPadding.zero;
    }

    // Fresh component captures of all supported form factors.
    for (final profile in [
      ('slab', 400.0, 869.0),
      ('fold-outer', 425.0, 623.0),
      ('fold-inner-portrait', 608.0, 860.0),
      ('fold-inner-landscape', 860.0, 608.0),
    ]) {
      await reset(Size(profile.$2, profile.$3));
      final c = JarvisController(
        FakeApi(),
        MemoryVault(),
        audioDevice: FakeAudio(),
      );
      await c.initialize();
      await show(LoginPage(controller: c));
      await settle();
      await capture('matrix-${profile.$1}-login');
      await show(JarvisHome(controller: c));
      await settle();
      await capture('matrix-${profile.$1}-home');
      c.current.title = '兼容性审核：会话标题';
      c.current.messages.add(ChatMessage('user', '请检查不同屏幕下的界面。'));
      c.current.messages.add(
        ChatMessage('assistant', '这是离线界面检查，当前页面不会发送真实请求。'),
      );
      c.notifyDraftSuggestion();
      await settle();
      await capture('matrix-${profile.$1}-chat');
      final menu = find.byTooltip('展开会话');
      if (menu.evaluate().isNotEmpty) {
        await t.tap(menu);
        await settle();
      }
      await capture('matrix-${profile.$1}-sidebar');

      await show(SettingsPage(controller: c));
      await settle();
      await capture('matrix-${profile.$1}-settings');
      c.voice.ready = true;
      c.voice.status = '已就绪';
      c.voice.owner = c.current;
      await show(VoicePage(controller: c));
      await settle();
      await capture('matrix-${profile.$1}-voice');
      c.voice.lastYou = '这是一段用于检查语音文字区的离线示例。';
      c.voice.lastBot = List.filled(
        8,
        '检查折叠窗口、字号放大和长回复滚动，不会改变真实会话。',
      ).join('\n');
      c.notifyDraftSuggestion();
      await settle();
      await capture('matrix-${profile.$1}-voice-text');

      await t.pumpWidget(const SizedBox());
      c.dispose();
    }
    // Real Android inset bookkeeping: navigation padding disappears under IME.
    await reset(const Size(400, 869));
    t.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
    t.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    await show(LoginPage(controller: c));
    await settle();
    await t.enterText(find.byType(TextField).first, 'AuditUser');
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    t.view.padding = const FakeViewPadding(top: 28);
    await t.pump();
    await settle();
    await capture('bug-safearea-01-keyboard-open');
    final button = find.widgetWithText(FilledButton, '登录');
    final before = t.getTopLeft(button).dy;
    t.view.viewInsets = FakeViewPadding.zero;
    t.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    await t.pump();
    final first = t.getTopLeft(button).dy;
    await capture('bug-safearea-02-close-first-frame');
    final positions = <double>[before, first];
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
      positions.add(t.getTopLeft(button).dy);
    }
    await capture('bug-safearea-03-closed');
    notes['safearea-close'] = {
      'before': before,
      'first_frame': first,
      'delta_first': first - before,
      'positions': positions,
    };
    await t.pumpWidget(const SizedBox());
    c.dispose();
    // Expanded landscape stays physically landscape while the IME is shown.
    await reset(const Size(860, 608));
    final fold = JarvisController(FakeApi(), MemoryVault());
    await fold.initialize();
    await show(LoginPage(controller: fold));
    await settle();
    await t.enterText(find.byType(TextField).first, 'AuditUser');
    await settle();
    final focusBefore = t
        .widget<EditableText>(find.byType(EditableText).first)
        .focusNode
        .hasFocus;
    final stackedBefore = find
        .byKey(const ValueKey('login-reactor-size'))
        .evaluate()
        .isNotEmpty;
    await capture('bug-fold-ime-01-wide');
    t.view.viewInsets = const FakeViewPadding(bottom: 250);
    await t.pump();
    await settle();
    final focusAfter = t
        .widget<EditableText>(find.byType(EditableText).first)
        .focusNode
        .hasFocus;
    notes['fold-ime'] = {
      'stacked_before': stackedBefore,
      'stacked_after': find
          .byKey(const ValueKey('login-reactor-size'))
          .evaluate()
          .isNotEmpty,
      'focus_before': focusBefore,
      'focus_after': focusAfter,
    };
    await capture('bug-fold-ime-02-keyboard');
    await t.pumpWidget(const SizedBox());
    fold.dispose();
    // Cached-session cold launch: actual home currently has no shared landing.
    await reset(const Size(400, 869));
    final home = JarvisController(FakeApi(), MemoryVault());
    await home.initialize();
    await show(StartupGate(ready: false, child: JarvisHome(controller: home)));
    await t.pump(const Duration(milliseconds: 100));
    await show(StartupGate(ready: true, child: JarvisHome(controller: home)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    notes['cached-session-launch'] = {
      'reactor_instances_during_flight': find
          .byType(LoginScene)
          .evaluate()
          .length,
    };
    await capture('bug-cached-start-01-double-reactor');
    await settle();
    await t.pumpWidget(const SizedBox());
    home.dispose();
    // Narrow window / enlarged text and accessible press-to-talk actions.
    await reset(const Size(320, 700));
    final voice = JarvisController(
      FakeApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await voice.initialize();
    voice.voice.ready = true;
    voice.voice.status = '已就绪';
    voice.voice.owner = voice.current;
    await show(VoicePage(controller: voice), scale: 2);
    await settle();
    await capture('bug-narrow-large-text-voice');
    final semantics = t.ensureSemantics();
    await t.pump();
    final target = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == '按住说话',
    );
    final data = t.getSemantics(target).getSemanticsData();
    notes['ptt-semantics'] = {
      // ignore: deprecated_member_use
      'button': data.hasFlag(ui.SemanticsFlag.isButton),
      'tap': data.hasAction(ui.SemanticsAction.tap),
      'long_press': data.hasAction(ui.SemanticsAction.longPress),
    };
    semantics.dispose();
    await t.pumpWidget(const SizedBox());
    voice.dispose();
    await t.runAsync(
      () =>
          File('${output.path}/findings-data.json')
              .writeAsString(const JsonEncoder.withIndent('  ').convert(notes)),
    );
  });
}

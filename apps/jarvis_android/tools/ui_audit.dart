// Offline UI audit: renders production widgets/themes using fixture data only.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/status_page.dart';
import 'package:jarvis_android/ui/voice_page.dart';

import '../test/support.dart';
import '../test/voice_support.dart';

class AuditApi extends VoiceApi {
  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('chat', 'Qwen3.8-Flash-Next'),
    ModelInfo(
      'speech',
      'Fish Audio Drama 3 (44.1 kHz). Built with Fish Audio',
      kind: 'speech',
      defaultVoice: 'Mae',
      voices: const [
        VoiceInfo('Mae', 'Mae', '柔和女声 · 适合轻声交流'),
        VoiceInfo('Arlo', 'Arlo', '温润男声 · 适合日常交谈'),
        VoiceInfo('Ezra', 'Ezra', '低沉男声 · 适合简洁问答'),
        VoiceInfo('Nora', 'Nora', '清亮女声 · 适合清晰播报'),
      ],
    ),
    ModelInfo('image', 'Image', kind: 'image'),
    ModelInfo('video', 'Video', kind: 'video'),
  ];
  @override
  Future<Map<String, dynamic>> toolsStatus() async => {
    'mem_available_bytes': 64 * 1073741824,
    'data': [
      {'name': '聊天模型', 'state': 'ready'},
      {'name': '语音引擎', 'state': 'loading'},
      {'name': '图片模型', 'state': 'unloaded'},
      {'name': '视频模型', 'state': 'failed'},
    ],
  };
}

void main() {
  testWidgets('Render all UI surfaces in foldable windows and both themes', (
    t,
  ) async {
    final originalShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = originalShadows);
    final output = Platform.environment['JARVIS_UI_AUDIT_DIR'];
    if (output == null) throw StateError('Set JARVIS_UI_AUDIT_DIR');
    await t.runAsync(() async {
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
      final font = FontLoader('AuditCJK')
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
      for (final family in ['Roboto', 'Ahem']) {
        final fallback = FontLoader(family)
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
                ).readAsBytes(),
              ),
            ),
          );
        await fallback.load();
      }
    });
    // Read the actual application themes rather than approximating their colors.
    final seed = JarvisController(
      AuditApi(),
      MemoryVault(),
      audioDevice: FakeAudio(),
    );
    await t.pumpWidget(JarvisApp(controller: seed));
    await t.pump();
    final app = t.widget<MaterialApp>(find.byType(MaterialApp));
    final themes = [('light', app.theme!), ('dark', app.darkTheme!)];
    await t.pumpWidget(const SizedBox());
    ui.Image? art;
    await t.runAsync(() async {
      art = await decodeImageFromList(
        await File('assets/jarvis-core.webp').readAsBytes(),
      );
    });
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetViewInsets);
    final records = <String>[];
    final brief = Platform.environment['JARVIS_UI_AUDIT_BRIEF'] == '1';
    final loginOnly = Platform.environment['JARVIS_LOGIN_ONLY'] == '1';
    for (final profile in [
      ('outer', 425.0, 623.0),
      if (loginOnly) ('ultra-portrait', 400.0, 869.0),
      if (!brief) ('outer-landscape', 623.0, 425.0),
      if (!brief) ('inner-portrait', 608.0, 860.0),
      ('inner-landscape', 860.0, 608.0),
    ]) {
      t.view.physicalSize = Size(profile.$2, profile.$3);
      for (final theme in themes) {
        if (brief && theme.$1 == 'light') continue;
        final c = JarvisController(
          AuditApi(),
          MemoryVault(),
          audioDevice: FakeAudio(),
        );
        await c.initialize();
        await c.login('user', 'fixture');
        c.settings.speechModel = 'speech';
        c.settings.voices['speech'] = 'Mae';
        final boundaryKey = GlobalKey();
        final actualTheme = theme.$2.copyWith(
          textTheme: theme.$2.textTheme.apply(fontFamily: 'AuditCJK'),
          primaryTextTheme: theme.$2.primaryTextTheme.apply(
            fontFamily: 'AuditCJK',
          ),
        );
        Future<void> mount(Widget screen) async {
          await t.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                key: UniqueKey(),
                debugShowCheckedModeBanner: false,
                theme: actualTheme,
                locale: const Locale('zh'),
                supportedLocales: const [Locale('zh')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                ),
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => screen),
                onGenerateInitialRoutes: (_) => [
                  MaterialPageRoute<void>(builder: (_) => const Scaffold()),
                  MaterialPageRoute<void>(builder: (_) => screen),
                ],
              ),
            ),
          );
          await t.pump();
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await t.pumpAndSettle();
        }

        Future<void> capture(String state) async {
          await t.pumpAndSettle();
          expect(
            t.takeException(),
            isNull,
            reason: '${profile.$1}/${theme.$1}/$state',
          );
          final name = '${profile.$1}-${theme.$1}-$state.png';
          await t.runAsync(() async {
            final render =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await Directory(output).create(recursive: true);
            await File('$output/$name')
                .writeAsBytes(bytes.buffer.asUint8List());
            image.dispose();
          });
          records.add(name);
        }

        const url = 'https://jarvis.example.com/audit-art.webp';
        final provider = NetworkImage(url, headers: const {});
        final thumbnail = ResizeImage(
          provider,
          width: 1024,
          height: 1024,
          policy: ResizeImagePolicy.fit,
        );
        for (final imageProvider in <ImageProvider>[provider, thumbnail]) {
          final key = await imageProvider.obtainKey(ImageConfiguration.empty);
          PaintingBinding.instance.imageCache.putIfAbsent(
            key,
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: art!.clone())),
            ),
          );
        }
        if (loginOnly) {
          await mount(LoginPage(controller: c));
          await capture('login');
          await t.pumpWidget(const SizedBox());
          c.dispose();
          continue;
        }
        c.error = '账户或密码不正确，请重试。';
        await mount(LoginPage(controller: c));
        await capture('login-error');
        c.error = null;
        await mount(JarvisHome(controller: c));
        await capture('home');
        await t.tap(find.byTooltip('更多操作'));
        await capture('more-menu');
        Navigator.of(t.element(find.text('模型状态'))).pop();
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('选择思考深度'));
        await capture('thinking-menu');
        Navigator.of(t.element(find.text('低'))).pop();
        await t.pumpAndSettle();
        if (find.byTooltip('会话操作').evaluate().isEmpty) {
          await t.tap(find.byTooltip('展开会话'));
          await t.pumpAndSettle();
        }
        await t.tap(find.byTooltip('会话操作').first);
        await capture('conversation-menu');
        await t.tap(find.text('重命名'));
        await capture('rename-dialog');
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        final scaffold = t.state<ScaffoldState>(find.byType(Scaffold).first);
        if (scaffold.isDrawerOpen) {
          scaffold.closeDrawer();
          await t.pumpAndSettle();
        }
        showNotice(t.element(find.byKey(const Key('chat-input'))), '审查提示');
        await capture('notice');
        t.view.viewInsets = const FakeViewPadding(bottom: 250);
        await mount(JarvisHome(controller: c));
        await capture('keyboard');
        t.view.viewInsets = FakeViewPadding.zero;
        if (profile.$1 == 'inner-landscape') {
          await mount(JarvisHome(controller: c));
          await t.tap(find.byTooltip('收起会话'));
          await capture('home-collapsed');
        }
        c.current.messages.addAll([
          ChatMessage('user', '请用简洁的方式，帮我整理今天的任务。'),
          ChatMessage(
            'assistant',
            '### 今天的安排\n\n1. 先完成最重要的工作。\n2. 留出沟通与休息的时间。\n\n把待办发给我，我们逐项安排。',
            reasoning: '先明确目标，再根据重要性和截止时间排序。',
          ),
        ]);
        await mount(JarvisHome(controller: c));
        await capture('chat');
        await t.tap(find.text('思考过程'));
        await t.pump(const Duration(milliseconds: 300));
        await capture('reasoning');
        c.current.messages.clear();
        await mount(SettingsPage(controller: c));
        await capture('settings');
        await t.ensureVisible(find.text('音色'));
        await t.pump();
        await capture('settings-voices');
        await t.ensureVisible(find.text('退出登录'));
        await t.pump();
        await capture('settings-advanced');
        await t.tap(find.text('删除全部会话'));
        await capture('delete-confirmation');
        Navigator.of(t.element(find.text('取消'))).pop(false);
        await t.pumpAndSettle();
        await mount(StatusPage(controller: c));
        await capture('status');
        final v = c.voice;
        v.owner = c.current;
        v.open = true;
        v.ready = true;
        v.status = '准备好了';
        v.hint = '按住说话，松开后发送。';
        await mount(VoicePage(controller: c));
        await capture('voice-idle');
        v.lastYou = '帮我整理一下今天的计划。';
        v.lastBot = '好的。先把最重要的事情告诉我，我们一起按时间和优先级安排。';
        await mount(VoicePage(controller: c));
        await capture('voice-chat');
        await t.tap(find.text('Mae'));
        await t.pump(const Duration(milliseconds: 300));
        await capture('voice-picker');
        v.error = '麦克风暂时不可用，请检查权限后重试。';
        v.ready = false;
        await mount(VoicePage(controller: c));
        await capture('voice-error');
        v.error = null;
        v.ready = true;
        c.current.tasks.addAll([
          MediaTask(
            id: 'pending',
            kind: 'video',
            prompt: '城市夜空中的蓝金色星球',
            args: {},
            status: 'in_progress',
            progress: 42,
          ),
          MediaTask(
            id: 'done',
            kind: 'image',
            prompt: '贾维斯星核示意',
            args: {},
            status: 'completed',
            urls: [url],
          ),
          MediaTask(
            id: 'failed',
            kind: 'image',
            prompt: '一幅山间水彩',
            args: {},
            status: 'failed',
            error: '生成暂时失败，请重试。',
          ),
        ]);
        await mount(VoicePage(controller: c));
        await t.tap(find.textContaining('生成作品').first);
        await t.pump(const Duration(milliseconds: 300));
        await capture('works');
        await mount(
          MediaPreview(
            controller: c,
            kind: 'image',
            url: url,
            prompt: '贾维斯星核示意',
          ),
        );
        await capture('image-preview');
        final document = Attachment(
          id: 'doc',
          name: '会议纪要与后续安排.txt',
          mime: 'text/plain',
          kind: 'document',
          text: '会议纪要\n\n一、确认本周目标。\n二、整理任务优先级。\n三、按计划逐项跟进。',
        );
        await mount(
          Scaffold(
            body: Center(
              child: AttachmentCard(controller: c, item: document),
            ),
          ),
        );
        await t.tap(find.text(document.name));
        await t.pump(const Duration(milliseconds: 300));
        await capture('document-preview');
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }
    }
    await t.runAsync(
      () => File('$output/index.txt').writeAsString('${records.join('\n')}\n'),
    );
    art?.dispose();
    debugDisableShadows = originalShadows;
  }, timeout: const Timeout(Duration(minutes: 5)));
}

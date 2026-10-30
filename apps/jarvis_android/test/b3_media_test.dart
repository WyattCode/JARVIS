import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/completed_works.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/keyboard_dismiss.dart';
import 'package:jarvis_android/ui/markdown_style.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'b2_support.dart';
import 'support.dart';

class DownloadApi extends FakeApi {
  final started = <String>[];
  @override
  Future<Uint8List> download(String path) async {
    started.add(path);
    return Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);
  }
}

MediaTask task({
  String id = 't',
  String kind = 'image',
  String prompt = '一只猫',
  String status = 'completed',
  List<String> urls = const ['https://example.test/a.png'],
}) => MediaTask(
  id: id,
  kind: kind,
  prompt: prompt,
  args: {},
  status: status,
  urls: urls,
);

Future<JarvisController> pumpCard(
  WidgetTester t,
  MediaTask task, {
  VoidCallback? onCancel,
  Future<void> Function()? openSettings,
  FakeApi? api,
  Size size = const Size(400, 800),
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  final c = JarvisController(api ?? FakeApi(), MemoryVault());
  await c.initialize();
  addTearDown(c.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MediaCard(
            task: task,
            controller: c,
            onCancel: onCancel,
            openSettings: openSettings,
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return c;
}

void main() {
  group('keyboard dismissal on finger up', () {
    Widget app() => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextField(
              key: const Key('field'),
              onTapUpOutside: dismissKeyboardOnTapUpOutside,
            ),
            const Spacer(),
            TextButton(
              key: const Key('btn'),
              onPressed: () {},
              child: const Text('other'),
            ),
          ],
        ),
      ),
    );
    bool editing() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;

    testWidgets(
      'iOS: a press elsewhere keeps the keyboard until the finger lifts',
      (t) async {
        await t.pumpWidget(app());
        await t.tap(find.byKey(const Key('field')));
        await t.pump();
        expect(editing(), isTrue);
        final gesture = await t.startGesture(
          t.getCenter(find.byKey(const Key('btn'))),
        );
        await t.pump();
        expect(editing(), isTrue, reason: '手指按下时键盘不收起');
        await gesture.moveBy(const Offset(0, -40));
        await t.pump();
        expect(editing(), isTrue, reason: '拖动开始时也不收起');
        await gesture.up();
        await t.pump();
        expect(editing(), isFalse, reason: '抬起时才收起');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('iOS: selecting text inside the field keeps the keyboard', (
      t,
    ) async {
      await t.pumpWidget(app());
      await t.enterText(find.byKey(const Key('field')), 'hello world');
      await t.pump();
      final start =
          t.getTopLeft(find.byKey(const Key('field'))) + const Offset(24, 20);
      final gesture = await t.startGesture(start);
      await t.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(60, 0));
      await t.pump();
      await gesture.up();
      await t.pump();
      expect(editing(), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Android leaves the focus alone', (t) async {
      await t.pumpWidget(app());
      await t.tap(find.byKey(const Key('field')));
      await t.pump();
      await t.tap(find.byKey(const Key('btn')));
      await t.pump();
      expect(editing(), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('task cards', () {
    testWidgets('a pending task can be cancelled from its card', (t) async {
      var cancelled = 0;
      await pumpCard(
        t,
        task(status: 'in_progress', urls: const []),
        onCancel: () => cancelled++,
      );
      final cancel = find.widgetWithText(TextButton, '取消');
      expect(cancel, findsOneWidget);
      expect(t.getSize(cancel).height, greaterThanOrEqualTo(44));
      await t.tap(cancel);
      expect(cancelled, 1);
    });

    testWidgets('no cancel button without a hook, or once the task is done', (
      t,
    ) async {
      await pumpCard(t, task(status: 'in_progress', urls: const []));
      expect(find.text('取消'), findsNothing);
      await pumpCard(t, task(), onCancel: () {});
      expect(find.text('取消'), findsNothing);
    });

    testWidgets('card buttons are at least 44 pt tall', (t) async {
      await pumpCard(t, task(status: 'failed', urls: const []));
      for (final label in ['复制提示词', '重试']) {
        expect(
          t.getSize(find.widgetWithText(TextButton, label)).height,
          greaterThanOrEqualTo(44),
        );
      }
    });

    testWidgets('a result is one button that reads its prompt', (t) async {
      Semantics result() => t.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('open-https://example.test/a.png')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      await pumpCard(t, task());
      expect(result().properties.label, '一只猫');
      expect(result().properties.button, isTrue);
      await pumpCard(t, task(prompt: ''));
      expect(result().properties.label, '查看图片');
      await pumpCard(
        t,
        task(kind: 'video', urls: const ['https://example.test/a.png']),
      );
      expect(result().properties.label, '播放视频：一只猫');
    });

    testWidgets('a picture that fails to load is a tap-to-retry', (t) async {
      await pumpCard(t, task());
      // The test HTTP client answers 400: the picture fails.
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final retry = find.byKey(const Key('image-retry'));
      expect(retry, findsOneWidget);
      expect(find.text('图片暂时无法加载，点按重试'), findsOneWidget);
      expect(t.widget<Image>(find.byType(Image).first).key, const ValueKey(0));
      await t.tap(retry);
      await t.pump();
      expect(
        t.widget<Image>(find.byType(Image).first).key,
        const ValueKey(1),
        reason: '重新请求图片',
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump();
    });

    testWidgets('iOS: a video card shows a placeholder and downloads nothing', (
      t,
    ) async {
      final api = DownloadApi();
      await pumpCard(
        t,
        task(kind: 'video', urls: const ['/v1/videos/j/content']),
        api: api,
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      expect(find.byType(VideoCover), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('一只猫'), findsWidgets);
      expect(api.started, isEmpty, reason: '只在点开预览时才下载');
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a picture task with several results saves all of them', (
      t,
    ) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeFiles.channel, (call) async {
            calls.add((call.arguments as Map)['name'] as String);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeFiles.channel, null),
      );
      final api = DownloadApi();
      await pumpCard(
        t,
        task(urls: const ['/a.png', '/b.png', '/c.png']),
        api: api,
      );
      expect(find.text('全部保存'), findsOneWidget);
      await t.tap(find.text('全部保存'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(api.started, ['/a.png', '/b.png', '/c.png']);
      expect(calls, hasLength(3));
      expect(calls.toSet(), hasLength(3), reason: '每张图片一个文件名');
      expect(find.text('已保存到相册'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a single result keeps the plain download label', (t) async {
      await pumpCard(t, task());
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('全部保存'), findsNothing);
    });
  });

  group('photo-library refusal', () {
    testWidgets('the button turns into a way to Settings and stays', (t) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeFiles.channel, (call) async {
            throw PlatformException(code: 'photos_denied');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeFiles.channel, null),
      );
      var opened = 0;
      await pumpCard(
        t,
        task(),
        api: DownloadApi(),
        openSettings: () async => opened++,
      );
      await t.tap(find.text('下载'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('去设置开启相册权限'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(find.text('去设置开启相册权限'), findsOneWidget, reason: '至少停留数秒');
      await t.tap(find.text('去设置开启相册权限'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(opened, 1);
      expect(find.text('下载'), findsOneWidget, reason: '回到 Settings 后可再试');
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('Settings from a refused microphone', () {
    Future<BuildContext> host(WidgetTester t, JarvisController c) async {
      late BuildContext context;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return context;
    }

    Future<JarvisController> refused() async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      c.voice
        ..error = '需要麦克风权限才能语音通话，请在系统设置中允许'
        ..permissionDenied = true;
      return c;
    }

    testWidgets('Android without an opener offers no dead button', (t) async {
      final c = await refused();
      addTearDown(c.dispose);
      reportCallFailure(await host(t, c), c);
      await t.pump();
      expect(find.text('需要麦克风权限才能语音通话，请在系统设置中允许'), findsOneWidget);
      expect(find.text('去设置'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('Android with an injected opener uses it', (t) async {
      final c = await refused();
      addTearDown(c.dispose);
      var opened = 0;
      reportCallFailure(
        await host(t, c),
        c,
        openSettings: () async => opened++,
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('去设置'));
      expect(opened, 1);
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('iOS keeps its own Settings button', (t) async {
      final c = await refused();
      addTearDown(c.dispose);
      reportCallFailure(await host(t, c), c);
      await t.pump();
      expect(find.text('去设置'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('attachments in a message', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    testWidgets('a picture shows as a thumbnail, a document stays a chip', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await c.blobs.put('img', Uint8List.fromList(png));
      final image = Attachment(
        id: 'img',
        name: 'cat.png',
        mime: 'image/png',
        kind: 'image',
      );
      final doc = Attachment(
        id: 'doc',
        name: 'a.txt',
        mime: 'text/plain',
        kind: 'document',
        text: 'hi',
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                AttachmentCard(controller: c, item: image, preview: true),
                AttachmentCard(controller: c, item: doc, preview: true),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('attachment-thumb-img')), findsOneWidget);
      expect(
        t.getSize(find.byKey(const Key('attachment-thumb-img'))).width,
        greaterThanOrEqualTo(44),
      );
      final decoded = t.widget<Image>(
        find.descendant(
          of: find.byKey(const Key('attachment-thumb-img')),
          matching: find.byType(Image),
        ),
      );
      expect((decoded.image as ResizeImage).width, 224, reason: '按缩略图尺寸解码');
      expect(find.widgetWithText(InputChip, 'a.txt'), findsOneWidget);
      // The composer's list keeps chips (with the remove cross).
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentCard(controller: c, item: image, removable: true),
          ),
        ),
      );
      await t.pump();
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.byKey(const Key('attachment-thumb-img')), findsNothing);
    });
  });

  group('preview page', () {
    Future<void> pumpPreview(
      WidgetTester t,
      Device device, {
      String kind = 'image',
      double scale = 1,
    }) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = device.size;
      t.view.padding = FakeViewPadding(
        left: device.safe.left,
        top: device.safe.top,
        right: device.safe.right,
        bottom: device.safe.bottom,
      );
      t.view.viewPadding = t.view.padding;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        t.view.resetDevicePixelRatio();
        t.view.resetPhysicalSize();
        t.view.resetPadding();
        t.view.resetViewPadding();
        t.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: MediaPreview(
            controller: c,
            kind: kind,
            url: kind == 'image'
                ? 'https://example.test/a.png'
                : 'https://example.test/a.mp4',
            prompt: '一只在雪地里奔跑的猫，毛发细节清晰，电影感光影。' * 3,
          ),
        ),
      );
      await t.pump();
      // The route's entrance has finished, so touches reach the page.
      await t.pump(const Duration(milliseconds: 800));
    }

    for (final device in [
      ...straightPhones,
      const Device('outer', Size(466, 678)),
      const Device(
        'inner landscape',
        Size(951, 669),
        safe: EdgeInsets.only(right: 84, bottom: 34),
      ),
    ]) {
      for (final kind in ['image', 'video']) {
        for (final scale in [1.0, 2.4]) {
          testWidgets(
            '${device.name} $kind x$scale: no overflow, bars inside the safe area',
            (t) async {
              await pumpPreview(t, device, kind: kind, scale: scale);
              await t.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 100)),
              );
              await t.pump();
              expect(t.takeException(), isNull);
              final safe = device.safe;
              for (final tip in ['复制提示词', '分享']) {
                final r = t.getRect(find.byTooltip(tip));
                expect(r.left, greaterThanOrEqualTo(safe.left));
                expect(
                  r.right,
                  lessThanOrEqualTo(device.size.width - safe.right),
                );
                expect(r.top, greaterThanOrEqualTo(safe.top));
                expect(r.height, greaterThanOrEqualTo(40));
              }
              final back = t.getRect(find.byType(BackButton));
              expect(back.left, greaterThanOrEqualTo(safe.left));
              expect(back.height, greaterThanOrEqualTo(44));
              await t.pump(const Duration(seconds: 1));
            },
          );
        }
      }
    }

    // (The picture here fails to load, so its middle is a retry button: the taps go above it.)
    testWidgets('a tap hides the bars and brings them back', (t) async {
      await pumpPreview(t, const Device('p', Size(400, 800)));
      double barOpacity() => t
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byTooltip('分享'),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;
      expect(barOpacity(), 1);
      await t.tapAt(const Offset(60, 250));
      await t.pump(const Duration(milliseconds: 500));
      expect(barOpacity(), 0);
      expect(find.byTooltip('分享').hitTestable(), findsNothing);
      await t.tapAt(const Offset(60, 250));
      await t.pump(const Duration(milliseconds: 500));
      expect(barOpacity(), 1);
    });

    testWidgets('double tap zooms into the picture and out again', (t) async {
      await pumpPreview(t, const Device('p', Size(400, 800)));
      final viewer = find.byType(InteractiveViewer);
      double scale() => t
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(scale(), 1);
      await t.tapAt(const Offset(200, 250));
      await t.pump(const Duration(milliseconds: 40));
      await t.tapAt(const Offset(200, 250));
      await t.pump(const Duration(milliseconds: 500));
      // It glides (220 ms) rather than jumping.
      await t.pump(const Duration(milliseconds: 100));
      expect(scale(), allOf(greaterThan(1.05), lessThan(2.45)));
      await t.pump(const Duration(milliseconds: 300));
      expect(scale(), closeTo(2.5, .01));
      await t.tapAt(const Offset(200, 250));
      await t.pump(const Duration(milliseconds: 40));
      await t.tapAt(const Offset(200, 250));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 300));
      expect(scale(), 1);
    });

    testWidgets('a video that cannot play says so and can be retried', (
      t,
    ) async {
      await pumpPreview(t, const Device('p', Size(400, 800)), kind: 'video');
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump();
      expect(find.text('视频暂时无法播放，请检查连接后重试'), findsOneWidget);
      expect(
        t.getSize(find.byKey(const Key('video-retry'))).height,
        greaterThanOrEqualTo(44),
      );
      await t.tap(find.byKey(const Key('video-retry')));
      await t.pump();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump();
      expect(find.text('视频暂时无法播放，请检查连接后重试'), findsOneWidget);
    });
  });

  group('finished work', () {
    Future<(JarvisController, ValueNotifier<bool>)> pumpPresenter(
      WidgetTester t, {
      bool accessible = false,
    }) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(accessibleNavigation: accessible),
            child: Scaffold(
              body: CompletedWorksPresenter(
                controller: c,
                child: const Center(child: Text('聊天')),
              ),
            ),
          ),
        ),
      );
      return (c, ValueNotifier(false));
    }

    // A job is news only when it was seen running and then completes: it is added unfinished first.
    void finish(JarvisController c, String id) {
      final job = task(
        id: id,
        kind: 'video',
        urls: ['https://example.test/$id.mp4'],
      );
      final urls = job.urls, status = job.status;
      job
        ..status = 'in_progress'
        ..urls = const [];
      c.current.tasks.add(job);
      c.notifyDraftSuggestion();
      job
        ..status = status
        ..urls = urls;
      c.notifyDraftSuggestion();
    }

    testWidgets('an idle user gets the sheet, as before', (t) async {
      final (c, _) = await pumpPresenter(t);
      finish(c, 'a');
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('生成作品'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a user who just touched the screen gets a notice with 查看', (
      t,
    ) async {
      final (c, _) = await pumpPresenter(t);
      await t.tap(find.text('聊天'));
      finish(c, 'a');
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('生成作品'), findsNothing);
      expect(find.text('作品已生成'), findsOneWidget);
      await t.tap(find.text('查看'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('生成作品'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('after five quiet seconds the sheet comes up by itself again', (
      t,
    ) async {
      final (c, _) = await pumpPresenter(t);
      await t.tap(find.text('聊天'));
      await t.pump(const Duration(seconds: 6));
      finish(c, 'a');
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('生成作品'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('VoiceOver users are never interrupted by the sheet', (
      t,
    ) async {
      final (c, _) = await pumpPresenter(t, accessible: true);
      finish(c, 'a');
      finish(c, 'b');
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('生成作品'), findsNothing);
      expect(find.text('2 个作品已生成'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('code blocks', () {
    testWidgets('increase contrast gives the block an edge', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeBlock(code: 'print(1);', language: 'dart'),
          ),
        ),
      );
      final box = t.widget<Container>(find.byType(Container).first);
      expect((box.decoration as BoxDecoration).border, isNotNull);
    });
  });
}

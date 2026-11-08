import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'support.dart';

/// A picture that arrives when the test says so.
class Controlled extends ImageProvider<Controlled> {
  Controlled(this.future);
  final Future<ui.Image> future;
  @override
  Future<Controlled> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(Controlled key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
        future.then((image) => ImageInfo(image: image)),
      );
}

class SavingApi extends FakeApi {
  final downloaded = <String>[];
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<Uint8List> download(String url) async {
    downloaded.add(url);
    await gate?.future;
    if (fail) throw StateError('offline');
    return Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  }
}

Future<Uint8List> pngBytes(WidgetTester t, int w, int h) async =>
    (await t.runAsync(() async {
      final image = await createTestImage(width: w, height: h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }))!;

Future<void> host(WidgetTester t, Widget child, {Size? size}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size ?? const Size(800, 1200);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    videoCoverPlayer = (uri, headers) => throw StateError('no player in tests');
  });

  group('AuthenticatedImage', () {
    Widget picture(
      JarvisController c,
      Future<ui.Image> Function() next, {
      String alt = '',
      double maxWidth = 480,
      bool opensViewer = true,
    }) => Align(
      alignment: Alignment.topLeft,
      child: AuthenticatedImage(
        controller: c,
        url: 'https://example.test/a.png',
        thumbnail: false,
        alt: alt,
        maxWidth: maxWidth,
        opensViewer: opensViewer,
        providerFactory: (uri, headers) => Controlled(next()),
      ),
    );

    testWidgets('120 high place, then the picture fades in over 0.25 s', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final done = Completer<ui.Image>();
      await host(t, picture(c, () => done.future, maxWidth: 300));
      expect(t.getSize(find.byType(AuthenticatedImage)).height, 120);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final image = (await t.runAsync(
        () => createTestImage(width: 400, height: 200),
      ))!;
      done.complete(image);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      // 300 wide at the shape of the picture (0.5): 150 high.
      expect(t.getSize(find.byType(AuthenticatedImage)), const Size(300, 150));
      double opacity() => t
          .widget<Opacity>(
            find.descendant(
              of: find.byType(AuthenticatedImage),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      expect(opacity(), 0);
      await t.pump(const Duration(milliseconds: 125));
      expect(opacity(), inExclusiveRange(0, 1));
      await t.pump(const Duration(milliseconds: 200));
      expect(opacity(), 1);
      c.dispose();
    });

    for (final (w, h, expected) in [
      (400, 40, 75.0), // very flat: at least 0.25 of the width
      (100, 400, 480.0), // very tall: at most 1.6 of the width
      (300, 300, 300.0),
    ]) {
      testWidgets('Shape of a ${w}x$h picture is clamped to 0.25..1.6', (
        t,
      ) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        final image = (await t.runAsync(
          () => createTestImage(width: w, height: h),
        ))!;
        await host(t, picture(c, () => Future.value(image), maxWidth: 300));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
        expect(t.getSize(find.byType(AuthenticatedImage)), Size(300, expected));
        c.dispose();
      });
    }

    testWidgets('Never wider than 480, whatever room it is given', (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final image = (await t.runAsync(
        () => createTestImage(width: 100, height: 100),
      ))!;
      await host(t, picture(c, () => Future.value(image)));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(t.getSize(find.byType(AuthenticatedImage)), const Size(480, 480));
      c.dispose();
    });

    testWidgets('Failure says so, and a touch loads it again', (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      var asked = 0;
      final first = Completer<ui.Image>();
      final image = (await t.runAsync(
        () => createTestImage(width: 200, height: 100),
      ))!;
      await host(
        t,
        picture(c, () {
          asked++;
          return asked == 1 ? first.future : Future.value(image);
        }),
      );
      first.completeError(StateError('offline'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(find.text('图片暂时无法加载，点按重试'), findsOneWidget);
      final text = t.widget<Text>(find.text('图片暂时无法加载，点按重试'));
      expect(text.style!.fontSize, 13);
      expect(text.style!.color, const Color(0xffa1a1aa));
      expect(t.getSize(find.byType(AuthenticatedImage)).height, 120);
      await t.tap(find.text('图片暂时无法加载，点按重试'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(asked, 2);
      expect(find.text('图片暂时无法加载，点按重试'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(t.takeException(), isNull);
      c.dispose();
    });

    testWidgets('Accessibility label is the alt text, or 图片', (t) async {
      final handle = t.ensureSemantics();
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final image = (await t.runAsync(
        () => createTestImage(width: 10, height: 10),
      ))!;
      await host(
        t,
        Column(
          children: [
            picture(c, () => Future.value(image), alt: '一只猫'),
            picture(c, () => Future.value(image)),
          ],
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('一只猫'), findsOneWidget);
      expect(find.bySemanticsLabel('图片'), findsOneWidget);
      handle.dispose();
      c.dispose();
    });

    testWidgets('A touch on a loaded picture opens it full screen', (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final image = (await t.runAsync(
        () => createTestImage(width: 100, height: 100),
      ))!;
      await host(t, picture(c, () => Future.value(image), alt: '一只猫'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byType(Image));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(MediaPreview), findsOneWidget);
      expect(t.widget<MediaPreview>(find.byType(MediaPreview)).kind, 'image');
      c.dispose();
    });
  });

  group('MediaCard', () {
    MediaTask task({
      String status = 'completed',
      String kind = 'image',
      String prompt = '一只猫',
      List<String> urls = const ['https://example.test/a.png'],
      double progress = 0,
      String? error,
    }) => MediaTask(
      id: 'task-1',
      kind: kind,
      prompt: prompt,
      args: {},
      status: status,
      urls: urls,
      progress: progress,
      error: error,
    );

    testWidgets('Card: radius 16, hairline border, card fill, 560 wide', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await host(
        t,
        MediaCard(
          controller: c,
          task: task(status: 'failed', urls: const []),
        ),
      );
      final card = t.widget<Container>(
        find
            .descendant(
              of: find.byType(MediaCard),
              matching: find.byType(Container),
            )
            .first,
      );
      final fill = card.decoration! as BoxDecoration;
      expect(fill.color, const Color(0xff121214));
      expect(fill.borderRadius, BorderRadius.circular(16));
      final border = card.foregroundDecoration! as BoxDecoration;
      expect((border.border! as Border).top.color, const Color(0xff303036));
      expect((border.border! as Border).top.width, 1);
      expect(
        t
            .getSize(
              find
                  .descendant(
                    of: find.byType(MediaCard),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .width,
        560,
      );
      expect(t.widget<Text>(find.text('一只猫')).style!.fontSize, 16);
      c.dispose();
    });

    testWidgets(
      'Text buttons are 44 high, 13 point, and a failed task retries',
      (t) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await host(
          t,
          MediaCard(
            controller: c,
            task: task(status: 'failed', urls: const [], error: '生成失败'),
          ),
        );
        expect(find.text('复制提示词'), findsOneWidget);
        expect(find.text('重试'), findsOneWidget);
        expect(find.text('下载'), findsNothing);
        // There is no way to stop a running job in the controller, so there is no cancel button.
        expect(find.text('取消'), findsNothing);
        expect(find.text('生成失败'), findsOneWidget);
        for (final label in ['复制提示词', '重试']) {
          final button = find.ancestor(
            of: find.text(label),
            matching: find.byType(TextButton),
          );
          expect(t.getSize(button).height, 44);
          expect(t.widget<Text>(find.text(label)).style, isNull);
        }
        final label = t.widget<DefaultTextStyle>(
          find
              .ancestor(
                of: find.text('重试'),
                matching: find.byType(DefaultTextStyle),
              )
              .first,
        );
        expect(label.style.fontSize, 13);
        c.dispose();
      },
    );

    testWidgets('Progress: a fixed 5% at nothing, the figure after', (t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await host(
        t,
        MediaCard(
          controller: c,
          task: task(status: 'queued', urls: const []),
        ),
      );
      expect(
        t
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .05,
      );
      expect(find.text('后台生成中，可以继续对话'), findsOneWidget);
      await host(
        t,
        MediaCard(
          controller: c,
          task: task(status: 'in_progress', urls: const [], progress: 40),
        ),
      );
      expect(
        t
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .4,
      );
      expect(find.text('后台生成中 · 40%，可以继续对话'), findsOneWidget);
      c.dispose();
    });

    testWidgets('Copying the prompt says 已复制 for 1.6 s', (t) async {
      final copied = <Object?>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text']);
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await host(
        t,
        MediaCard(
          controller: c,
          task: task(urls: const []),
        ),
      );
      await t.tap(find.text('复制提示词'));
      await t.pump(const Duration(milliseconds: 100));
      expect(copied, ['一只猫']);
      expect(find.text('已复制'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1400));
      expect(find.text('已复制'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('复制提示词'), findsOneWidget);
      c.dispose();
    });

    testWidgets('Save all saves every result, and says how it went', (t) async {
      final api = SavingApi(), saved = <Map>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('cc.odn.jarvis/files'),
        (call) async {
          saved.add(call.arguments as Map);
          return true;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('cc.odn.jarvis/files'),
          null,
        ),
      );
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      final urls = ['https://example.test/a.png', 'https://example.test/b.png'];
      await host(
        t,
        MediaCard(
          controller: c,
          task: task(urls: urls),
        ),
      );
      expect(find.text('全部保存'), findsOneWidget);
      api.gate = Completer<void>();
      await t.tap(find.text('全部保存'));
      await t.pump();
      expect(find.text('保存中'), findsOneWidget);
      api.gate!.complete();
      await t.pump();
      await t.pump();
      expect(api.downloaded, urls);
      expect(saved.map((s) => s['name']), [
        'jarvis-task-1-1.png',
        'jarvis-task-1-2.png',
      ]);
      expect(find.text('已保存'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 2300));
      expect(find.text('全部保存'), findsOneWidget);
      c.dispose();
    });

    testWidgets('A failed save says 保存失败，点按重试 and offers the save again', (
      t,
    ) async {
      final api = SavingApi()..fail = true;
      final c = JarvisController(api, MemoryVault());
      await c.initialize();
      await host(t, MediaCard(controller: c, task: task()));
      expect(find.text('下载'), findsOneWidget);
      await t.tap(find.text('下载'));
      await t.pump();
      await t.pump();
      expect(find.text('保存失败，点按重试'), findsOneWidget);
      await t.tap(find.text('保存失败，点按重试'));
      await t.pump();
      expect(api.downloaded.length, 2);
      await t.pump();
      await t.pump(const Duration(milliseconds: 2300));
      expect(find.text('下载'), findsOneWidget);
      c.dispose();
    });

    testWidgets(
      'A video is a 16:9 gradient with a 44 point white play button',
      (t) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await host(
          t,
          MediaCard(
            controller: c,
            task: task(
              kind: 'video',
              urls: const ['https://example.test/v.mp4'],
            ),
          ),
        );
        await t.pump();
        final tile = t.getSize(find.byType(VideoTile));
        expect(tile.width / tile.height, closeTo(16 / 9, .01));
        final icon = t.widget<Icon>(find.byIcon(Icons.play_circle_filled));
        expect(icon.size, 44);
        expect(icon.color!.a, closeTo(.9, .01));
        expect(icon.color!.r, 1);
        final gradient = t
            .widgetList<DecoratedBox>(
              find.descendant(
                of: find.byType(VideoTile),
                matching: find.byType(DecoratedBox),
              ),
            )
            .map((d) => d.decoration)
            .whereType<BoxDecoration>()
            .map((d) => d.gradient)
            .whereType<LinearGradient>()
            .single;
        expect(gradient.colors, VideoTile.gradientFor('task-1'));
        expect(gradient.begin, Alignment.topLeft);
        expect(gradient.end, Alignment.bottomRight);
        expect(find.bySemanticsLabel('播放视频：一只猫'), findsOneWidget);
        c.dispose();
      },
    );

    test('Video tile colours follow the task and are dark', () {
      final a = VideoTile.gradientFor('a'), b = VideoTile.gradientFor('bb');
      expect(a, VideoTile.gradientFor('a'));
      expect(a, isNot(b));
      for (final color in [...a, ...b]) {
        expect(HSVColor.fromColor(color).value, lessThanOrEqualTo(.41));
      }
    });

    testWidgets(
      'A tapped video opens the viewer; a cover frame needs no player',
      (t) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await host(
          t,
          MediaCard(
            controller: c,
            task: task(
              kind: 'video',
              urls: const ['https://example.test/v.mp4'],
            ),
          ),
        );
        await t.tap(find.byType(VideoTile));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(find.byType(MediaPreview), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  });

  group('AttachmentCard', () {
    testWidgets(
      'A sent picture is a 96 point thumbnail that opens full screen',
      (t) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        final bytes = await pngBytes(t, 200, 100);
        await c.blobs.put('p1', bytes);
        final item = Attachment(
          id: 'p1',
          name: 'cat.png',
          mime: 'image/png',
          kind: 'image',
        );
        await host(
          t,
          Wrap(
            children: [AttachmentCard(controller: c, item: item)],
          ),
        );
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
        expect(find.byType(InputChip), findsNothing);
        final box = find
            .descendant(
              of: find.byType(AttachmentCard),
              matching: find.byType(SizedBox),
            )
            .first;
        expect(t.getSize(box), const Size(96, 96));
        expect(
          t.widget<ClipRRect>(find.byType(ClipRRect)).borderRadius,
          BorderRadius.circular(12),
        );
        expect(t.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
        await t.tap(find.byType(AttachmentCard));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        c.dispose();
      },
    );

    testWidgets(
      'A sent document is a 34 high pill, max 220, and cannot be tapped',
      (t) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        final name = '${List.filled(30, '很长的报告').join()}.pdf';
        final item = Attachment(
          id: 'd1',
          name: name,
          mime: 'application/pdf',
          kind: 'document',
          text: 'hello',
        );
        await host(
          t,
          Wrap(
            children: [AttachmentCard(controller: c, item: item)],
          ),
        );
        final pill = find.descendant(
          of: find.byType(AttachmentCard),
          matching: find.byType(Container),
        );
        expect(t.getSize(pill.first).height, 34);
        expect(t.getSize(pill.first).width, lessThanOrEqualTo(220));
        final decoration =
            t.widget<Container>(pill.first).decoration! as ShapeDecoration;
        expect(decoration.color, const Color(0xff1c1c20));
        expect(decoration.shape, isA<StadiumBorder>());
        final shown = t.widget<Text>(
          find.descendant(
            of: find.byType(AttachmentCard),
            matching: find.byType(Text),
          ),
        );
        expect(shown.data, contains('…'));
        expect(shown.data, endsWith('.pdf'));
        expect(shown.data, startsWith('很长'));
        expect(find.byIcon(Icons.description_outlined), findsOneWidget);
        await t.tap(find.byType(AttachmentCard));
        await t.pump(const Duration(milliseconds: 400));
        expect(find.byType(AlertDialog), findsNothing);
        c.dispose();
      },
    );

    testWidgets(
      'A short document name is shown whole; gap between pills is the Wrap\'s',
      (t) async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        final item = Attachment(
          id: 'd2',
          name: 'a.txt',
          mime: 'text/plain',
          kind: 'document',
        );
        await host(
          t,
          Wrap(
            children: [AttachmentCard(controller: c, item: item)],
          ),
        );
        expect(find.text('a.txt'), findsOneWidget);
        c.dispose();
      },
    );

    testWidgets('The composer chip and the expanded row keep their shapes', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      final item = Attachment(
        id: 'd3',
        name: 'b.txt',
        mime: 'text/plain',
        kind: 'document',
      );
      await host(
        t,
        Column(
          children: [
            AttachmentCard(controller: c, item: item, removable: true),
            AttachmentCard(
              controller: c,
              item: item,
              removable: true,
              expanded: true,
            ),
          ],
        ),
      );
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.textContaining('text/plain'), findsOneWidget);
      c.dispose();
    });

    test('Middle ellipsis keeps both ends and fits the width', () {
      const style = TextStyle(fontSize: 14);
      final fitted = MiddleEllipsisText.fit(
        'quarterly-report-final-2024.pdf',
        style,
        120,
        TextDirection.ltr,
        TextScaler.noScaling,
      );
      expect(fitted, contains('…'));
      expect(fitted, startsWith('qu'));
      expect(fitted, endsWith('pdf'));
      final painter = TextPainter(
        text: TextSpan(text: fitted, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(painter.width, lessThanOrEqualTo(120));
      expect(
        MiddleEllipsisText.fit(
          'a.txt',
          style,
          120,
          TextDirection.ltr,
          TextScaler.noScaling,
        ),
        'a.txt',
      );
    });
  });

  group('MediaPreview', () {
    Future<JarvisController> open(WidgetTester t) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MediaPreview(
                      controller: c,
                      kind: 'image',
                      url: 'https://example.test/a.png',
                      prompt: '不要显示的提示词',
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      return c;
    }

    testWidgets('Black page, transparent chrome, no prompt under the picture', (
      t,
    ) async {
      final c = await open(t);
      expect(
        t.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.black,
      );
      final bar = t.widget<AppBar>(find.byType(AppBar));
      expect(bar.backgroundColor, Colors.transparent);
      expect(find.text('不要显示的提示词'), findsNothing);
      expect(find.byTooltip('分享'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(
        t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).maxScale,
        6,
      );
      expect(
        t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).minScale,
        1,
      );
      c.dispose();
    });

    testWidgets('A tap hides and shows the chrome', (t) async {
      final c = await open(t);
      double opacity() =>
          t.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
      expect(opacity(), 1);
      await t.tapAt(const Offset(200, 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(opacity(), 0);
      expect(
        t
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byType(AnimatedOpacity),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
      await t.tapAt(const Offset(200, 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(opacity(), 1);
      c.dispose();
    });

    testWidgets('A double tap zooms in on the spot and out again', (t) async {
      final c = await open(t);
      final viewer = find.byType(InteractiveViewer);
      double scale() => t
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(scale(), 1);
      Future<void> doubleTap() async {
        await t.tapAt(const Offset(300, 500));
        await t.pump(kDoubleTapMinTime);
        await t.tapAt(const Offset(300, 500));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
      }

      await doubleTap();
      expect(scale(), closeTo(2.5, .01));
      // The spot that was touched stays where it was.
      final m = t
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value;
      final spot = MatrixUtils.transformPoint(m, const Offset(300, 500));
      expect(spot.dx, closeTo(300, 1));
      expect(spot.dy, closeTo(500, 1));
      await doubleTap();
      expect(scale(), closeTo(1, .01));
      c.dispose();
    });

    testWidgets('A drag down at rest takes the picture away', (t) async {
      final c = await open(t);
      await t.drag(find.byType(InteractiveViewer), const Offset(0, 320));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(MediaPreview), findsNothing);
      c.dispose();
    });

    testWidgets('A short drag springs back', (t) async {
      final c = await open(t);
      await t.drag(find.byType(InteractiveViewer), const Offset(0, 60));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(MediaPreview), findsOneWidget);
      expect(t.takeException(), isNull);
      c.dispose();
    });
  });
}

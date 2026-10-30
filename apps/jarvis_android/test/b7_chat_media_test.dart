import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/blobs.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'b_chat_ui_test.dart' show pumpPhone;
import 'support.dart';

const files = MethodChannel('ai.jarvis.app/files');

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A blob store whose reads wait for the test.
class SlowBlobs extends MemoryBlobs {
  final gate = Completer<void>();
  @override
  Future<Uint8List> get(String id) async {
    await gate.future;
    return super.get(id);
  }
}

void main() {
  Attachment file(String name, {String id = 'a'}) => Attachment(
    id: id,
    name: name,
    mime: 'image/jpeg',
    kind: 'image',
    size: 10,
  );

  group('preview zoom', () {
    Future<void> pumpPreview(WidgetTester t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: MediaPreview(
            controller: c,
            kind: 'image',
            url: 'https://example.test/a.png',
            prompt: '一只猫',
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 800));
    }

    Future<void> doubleTap(WidgetTester t, Offset at) async {
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 40));
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 500));
      // The zoom glides for 220 ms from the frame after the tap.
      await t.pump(const Duration(milliseconds: 300));
    }

    // (The picture here fails to load: the viewer is the small retry box, centred in the tall page. That is the same
    // situation as a wide picture on a tall phone: the viewer is smaller than the page.)
    testWidgets('the zoom keeps the tapped point of the picture under the '
        'finger and the picture covers the viewer', (t) async {
      await pumpPreview(t);
      final viewer = find.byType(InteractiveViewer);
      final box = t.getRect(viewer);
      expect(box.height, lessThan(400));
      Matrix4 matrix() =>
          t.widget<InteractiveViewer>(viewer).transformationController!.value;

      final tap = box.topLeft + const Offset(60, 20);
      await doubleTap(t, tap);
      final m = matrix();
      expect(m.getMaxScaleOnAxis(), closeTo(2.5, .01));
      final local = tap - box.topLeft;
      // The content point that was tapped is still where it was...
      final moved = MatrixUtils.transformPoint(m, local);
      expect(moved.dx, closeTo(local.dx, .01));
      expect(moved.dy, closeTo(local.dy, .01));
      // ...and the zoomed picture still spans the whole viewer: no black margin appears inside it.
      final topLeft = MatrixUtils.transformPoint(m, Offset.zero);
      final bottomRight = MatrixUtils.transformPoint(
        m,
        Offset(box.width, box.height),
      );
      expect(topLeft.dx, lessThanOrEqualTo(.01));
      expect(topLeft.dy, lessThanOrEqualTo(.01));
      expect(bottomRight.dx, greaterThanOrEqualTo(box.width - .01));
      expect(bottomRight.dy, greaterThanOrEqualTo(box.height - .01));
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('a tap beside the picture zooms on its nearest edge', (
      t,
    ) async {
      await pumpPreview(t);
      final viewer = find.byType(InteractiveViewer);
      final box = t.getRect(viewer);
      // Well above the viewer, on the black.
      await doubleTap(t, Offset(box.right - 10, box.top - 150));
      final m = t
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value;
      final topLeft = MatrixUtils.transformPoint(m, Offset.zero);
      final bottomRight = MatrixUtils.transformPoint(
        m,
        Offset(box.width, box.height),
      );
      expect(topLeft.dx, lessThanOrEqualTo(.01));
      expect(topLeft.dy, lessThanOrEqualTo(.01));
      expect(bottomRight.dx, greaterThanOrEqualTo(box.width - .01));
      expect(bottomRight.dy, greaterThanOrEqualTo(box.height - .01));
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('save button', () {
    for (final scale in [2.0, 2.4]) {
      testWidgets('"去设置开启相册权限" wraps instead of overflowing at x$scale', (
        t,
      ) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(320, 600);
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  child: SaveAction(
                    save: () async => SaveResult.denied,
                    openSettings: () async {},
                  ),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.byType(TextButton));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('去设置开启相册权限'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pump(const Duration(seconds: 10));
      });
    }
  });

  group('attachment chips in the composer', () {
    void seed(JarvisController c) {
      for (var i = 0; i < 3; i++) {
        c.current.pendingAttachments.add(
          file('IMG_20260101_0000$i.jpg', id: 'a$i'),
        );
      }
    }

    testWidgets('the cross is a 44 pt target, chips are spaced and narrower', (
      t,
    ) async {
      final c = await pumpPhone(
        t,
        platform: TargetPlatform.iOS,
        size: const Size(375, 667),
        seed: seed,
      );
      final chips = find.byType(InputChip);
      final first = t.getRect(chips.at(0)), second = t.getRect(chips.at(1));
      expect(first.height, lessThanOrEqualTo(48));
      expect(first.width, lessThan(225));
      expect(second.left - first.right, closeTo(6, .01));
      // The row is a draggable list with the iOS feel and the second chip peeks in.
      final list = t.widget<ListView>(
        find.descendant(
          of: find.byKey(const Key('composer-frame')),
          matching: find.byType(ListView),
        ),
      );
      expect(list.physics, isA<AlwaysScrollableScrollPhysics>());
      expect(second.left, lessThan(375));
      // The corner of the 44 pt box around the cross (8 pt chip padding to its right) still removes the attachment.
      await t.tapAt(Offset(first.right - 8 - 43, first.center.dy + 20));
      await t.pump();
      expect(c.current.pendingAttachments.map((a) => a.id), ['a1', 'a2']);
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('history thumbnails', () {
    testWidgets('a picture keeps its 112 square while it loads', (t) async {
      final blobs = SlowBlobs();
      await blobs.put('img', Uint8List.fromList(png));
      final c = JarvisController(FakeApi(), MemoryVault(), blobs: blobs);
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                AttachmentCard(
                  controller: c,
                  item: file('p.jpg', id: 'img'),
                  preview: true,
                ),
              ],
            ),
          ),
        ),
      );
      final placeholder = find.byKey(const Key('attachment-thumb-loading-img'));
      expect(placeholder, findsOneWidget);
      expect(t.getSize(placeholder), const Size(112, 112));
      expect(find.byType(InputChip), findsNothing);
      blobs.gate.complete();
      await t.pump();
      await t.pump();
      expect(placeholder, findsNothing);
      expect(
        t.getSize(find.byKey(const Key('attachment-thumb-img'))),
        const Size(112, 112),
      );
    });

    testWidgets('a picture that cannot be read falls back to the chip', (
      t,
    ) async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentCard(
              controller: c,
              item: file('gone.jpg', id: 'gone'),
              preview: true,
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byType(InputChip), findsOneWidget);
    });
  });

  testWidgets('a long server error on the login page is shown whole', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(375, 667);
    t.platformDispatcher.textScaleFactorTestValue = 2.4;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final c = JarvisController(FakeApi(), MemoryVault());
    addTearDown(c.dispose);
    c.error = '服务器暂时无法处理登录请求，请稍后再试；如果问题持续，请联系管理员并提供时间。';
    await t.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
    final subtitle = t.widget<Text>(
      find.byKey(const ValueKey('login-subtitle')),
    );
    expect(subtitle.maxLines, isNull);
    expect(subtitle.overflow, isNot(TextOverflow.ellipsis));
    expect(t.takeException(), isNull);
  });

  group('attach menu', () {
    testWidgets('VoiceOver sees a button named 添加附件 on iOS', (t) async {
      final handle = t.ensureSemantics();
      await pumpPhone(t, platform: TargetPlatform.iOS);
      expect(
        t.getSemantics(find.byTooltip('添加附件')),
        matchesSemantics(
          label: '添加附件',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: false,
        ),
      );
      handle.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    Future<void> failOnceSwitched(
      WidgetTester t, {
      required Object error,
    }) async {
      final gate = Completer<Object?>();
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (
        call,
      ) async {
        if (call.method == 'takePhoto') return gate.future;
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          files,
          null,
        ),
      );
      final c = await pumpPhone(
        t,
        platform: TargetPlatform.iOS,
        seed: (c) => c
          ..models = [
            ModelInfo(
              'm',
              'M',
              metadata: {
                'jarvis': {'image_input': true},
              },
            ),
          ]
          ..model = 'm',
      );
      await t.tap(find.byTooltip('添加附件'));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('拍照'));
      await t.pump(const Duration(milliseconds: 100));
      // The user starts another conversation while the camera is up: the keyed composer is replaced.
      final before = find.byKey(ValueKey('composer-${c.selectedId}'));
      expect(before, findsOneWidget);
      c.newConversation();
      await t.pump(const Duration(milliseconds: 100));
      expect(before, findsNothing);
      gate.completeError(error);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('a refused camera still tells the user after a conversation '
        'switch, with a way to Settings that stays up', (t) async {
      await failOnceSwitched(
        t,
        error: PlatformException(
          code: 'camera_denied',
          message: '请在“设置”里允许 JARVIS 使用相机',
        ),
      );
      expect(find.text('请在“设置”里允许 JARVIS 使用相机'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      // Longer than the plain 3 seconds, so there is time to reach it.
      await t.pump(const Duration(seconds: 5));
      expect(find.text('去设置'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('去设置'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('any other failure after a switch is reported without a '
        'Settings button', (t) async {
      await failOnceSwitched(
        t,
        error: PlatformException(code: 'invalid', message: 'x'),
      );
      expect(find.text('图片无法读取'), findsOneWidget);
      expect(find.text('去设置'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}

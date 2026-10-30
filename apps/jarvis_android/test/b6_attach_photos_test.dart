import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'b_chat_ui_test.dart' show pumpPhone;

/// What the native image bridge answers to `normalizeImage`: any bytes are "a JPEG".
const files = MethodChannel('ai.jarvis.app/files');
const picker = MethodChannel('plugins.flutter.io/file_selector');

void main() {
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall)? answer;
  Future<void> stubChannels(WidgetTester t) async {
    calls = [];
    answer = null;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'normalizeImage') return call.arguments;
      return answer?.call(call);
    });
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
      call,
    ) async {
      calls.add(call);
      return <String>[];
    });
    addTearDown(() {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, null);
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, null);
    });
  }

  /// A chat model that reads pictures.
  void seeVision(JarvisController c) => c
    ..models = [
      ModelInfo(
        'test-model',
        'Test model',
        metadata: {
          'jarvis': {'image_input': true},
        },
      ),
    ]
    ..model = 'test-model';

  Map<String, Object> photo(String name) => {
    'name': name,
    'bytes': Uint8List.fromList([1, 2, 3]),
  };

  /// Adding an attachment writes the picture to disk, which takes real time.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  group('iOS: the + button offers photos, camera and files', () {
    testWidgets('photos from the library become attachments', (t) async {
      await stubChannels(t);
      final c = await pumpPhone(
        t,
        platform: TargetPlatform.iOS,
        seed: seeVision,
      );
      answer = (call) async => call.method == 'pickPhotos'
          ? [photo('IMG_1.jpg'), photo('IMG_2.png')]
          : null;

      await t.tap(find.byTooltip('添加附件'));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      await t.tap(find.text('照片'));
      await t.pump(const Duration(milliseconds: 200));
      await settle(t);
      await t.pump(const Duration(milliseconds: 200));

      expect(calls.firstWhere((m) => m.method == 'pickPhotos').arguments, {
        'limit': 4,
      });
      expect(c.current.pendingAttachments.map((a) => a.name), [
        'IMG_1.jpg',
        'IMG_2.png',
      ]);
      expect(
        c.current.pendingAttachments.every((a) => a.kind == 'image'),
        isTrue,
      );
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('the camera adds one picture; cancelling adds none', (t) async {
      await stubChannels(t);
      final c = await pumpPhone(
        t,
        platform: TargetPlatform.iOS,
        seed: seeVision,
      );
      answer = (call) async =>
          call.method == 'takePhoto' ? [photo('photo-1.jpg')] : null;
      await t.tap(find.byTooltip('添加附件'));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('拍照'));
      await t.pump(const Duration(milliseconds: 200));
      await settle(t);
      await t.pump(const Duration(milliseconds: 200));
      expect(c.current.pendingAttachments.single.name, 'photo-1.jpg');

      answer = (call) async => <Object?>[];
      await t.tap(find.byTooltip('添加附件'));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('拍照'));
      await t.pump(const Duration(milliseconds: 200));
      await settle(t);
      await t.pump(const Duration(milliseconds: 200));
      expect(c.current.pendingAttachments, hasLength(1));
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets(
      'a refused camera says what to do; a text-only model says so before the picker opens',
      (t) async {
        await stubChannels(t);
        await pumpPhone(t, platform: TargetPlatform.iOS, seed: seeVision);
        answer = (call) async => throw PlatformException(
          code: 'camera_denied',
          message: '请在“设置”里允许 JARVIS 使用相机',
        );
        await t.tap(find.byTooltip('添加附件'));
        await t.pump(const Duration(milliseconds: 200));
        await t.tap(find.text('拍照'));
        await t.pump(const Duration(milliseconds: 200));
        await t.pump(const Duration(milliseconds: 200));
        expect(find.text('请在“设置”里允许 JARVIS 使用相机'), findsOneWidget);
        await t.pump(const Duration(seconds: 4));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('a model without vision never opens the photo picker', (
      t,
    ) async {
      await stubChannels(t);
      await pumpPhone(t, platform: TargetPlatform.iOS);
      await t.tap(find.byTooltip('添加附件'));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('照片'));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 200));
      expect(calls.where((m) => m.method == 'pickPhotos'), isEmpty);
      expect(find.text('当前模型不支持图片输入'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('files still opens the file picker', (t) async {
      await stubChannels(t);
      await pumpPhone(t, platform: TargetPlatform.iOS);
      await t.tap(find.byTooltip('添加附件'));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('文件'));
      await t.pump(const Duration(milliseconds: 200));
      expect(
        calls.any((m) => m.method.toLowerCase().contains('openfile')),
        isTrue,
      );
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  testWidgets('Android: the + button goes straight to the file picker', (
    t,
  ) async {
    await stubChannels(t);
    await pumpPhone(t, platform: TargetPlatform.android);
    await t.tap(find.byTooltip('添加附件'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('照片'), findsNothing);
    expect(
      calls.any((m) => m.method.toLowerCase().contains('openfile')),
      isTrue,
    );
    await t.pump(const Duration(seconds: 4));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

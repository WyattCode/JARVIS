import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

void main() {
  final calls = <String>[];
  Object? failure;
  setUp(() {
    calls.clear();
    failure = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeFiles.channel, (call) async {
          calls.add(call.method);
          if (failure != null) throw failure!;
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeFiles.channel, null);
  });

  Future<void> tapDownload(WidgetTester t, {bool compact = false}) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SaveAction(
              compact: compact,
              save: () => downloadMedia(
                Uint8List.fromList([1, 2, 3]),
                'a.mp4',
                'video/mp4',
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byType(SaveAction));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('iOS: the button itself confirms, then returns to normal', (
    t,
  ) async {
    await tapDownload(t);
    expect(calls, ['saveToPhotos']);
    expect(find.text('已保存到相册'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('下载'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS: a refused photo permission shows in the button', (t) async {
    failure = PlatformException(code: 'photos_denied');
    await tapDownload(t);
    expect(find.text('去设置开启相册权限'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('去设置开启相册权限'), findsOneWidget, reason: '拒绝提示停留更久');
    await t.pump(const Duration(seconds: 7));
    expect(find.text('下载'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS: other failures say so in the button', (t) async {
    failure = PlatformException(code: 'save_failed');
    await tapDownload(t);
    expect(find.text('保存失败'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS: the preview app-bar button swaps its icon', (t) async {
    await tapDownload(t, compact: true);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android keeps the save-to-file flow', (t) async {
    await tapDownload(t);
    expect(calls, ['save']);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('下载'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

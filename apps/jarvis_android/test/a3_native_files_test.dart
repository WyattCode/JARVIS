import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/app_info.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/state/system_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? reply;
  setUp(() {
    calls.clear();
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeFiles.channel, (call) async {
          calls.add(call);
          return reply?.call(call);
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeFiles.channel, null);
  });

  group('picture rules reach the user with their own words', () {
    for (final (code, message) in [
      ('image_dimensions', '图片尺寸过大，请选择小于6000万像素的图片'),
      ('image_compress', '图片压缩后仍超过3MB，请换一张较小的图片'),
      ('image_file_too_large', '图片文件过大，请选择20MB以内的图片'),
    ]) {
      test(code, () async {
        reply = (_) async =>
            throw PlatformException(code: code, message: message);
        await expectLater(
          NativeFiles.normalizeImage(Uint8List(3)),
          throwsA(
            isA<JarvisException>().having((e) => e.message, 'message', message),
          ),
        );
      });
    }

    test('an unrelated native failure is not disguised', () async {
      reply = (_) async => throw PlatformException(code: 'boom');
      await expectLater(
        NativeFiles.normalizeImage(Uint8List(3)),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('files are passed by path', () {
    test('iOS: save offers the files without reading them', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      reply = (_) async => true;
      expect(
        await NativeFiles.saveFiles([
          (path: '/tmp/a.json', name: 'a.json'),
          (path: '/tmp/b.json', name: 'b.json'),
        ], 'application/json'),
        isTrue,
      );
      expect(calls.single.method, 'save');
      expect(calls.single.arguments['files'], [
        {'path': '/tmp/a.json', 'name': 'a.json'},
        {'path': '/tmp/b.json', 'name': 'b.json'},
      ]);
      expect(calls.single.arguments.containsKey('bytes'), isFalse);
    });

    test(
      'elsewhere: the bytes API, one file at a time, stopping when cancelled',
      () async {
        final dir = Directory.systemTemp.createTempSync('a3_files');
        addTearDown(() => dir.deleteSync(recursive: true));
        final a = File('${dir.path}/a.json')..writeAsBytesSync([1]);
        final b = File('${dir.path}/b.json')..writeAsBytesSync([2]);
        var n = 0;
        reply = (_) async => ++n == 1 ? false : true;
        expect(
          await NativeFiles.saveFiles([
            (path: a.path, name: 'a.json'),
            (path: b.path, name: 'b.json'),
          ], 'application/json'),
          isFalse,
        );
        expect(calls, hasLength(1));
        expect(calls.single.arguments['bytes'], [1]);
        expect(calls.single.arguments['name'], 'a.json');
      },
    );

    test('photos and share take a path', () async {
      reply = (_) async => true;
      await NativeFiles.saveToPhotosFile('/tmp/v.mp4', 'v.mp4', 'video/mp4');
      await NativeFiles.shareFile('/tmp/v.mp4', 'v.mp4', 'video/mp4');
      expect(calls.map((c) => c.method), ['saveToPhotos', 'share']);
      for (final c in calls) {
        expect(c.arguments, {
          'path': '/tmp/v.mp4',
          'name': 'v.mp4',
          'mime': 'video/mp4',
        });
      }
    });

    test('transfer files live in a folder that sign-out empties', () async {
      final file = await NativeFiles.transferFile('mp4');
      expect(file.parent.path, endsWith('/jarvis-transfer'));
      expect(file.path, endsWith('.mp4'));
      expect(file.parent.existsSync(), isTrue);
    });
  });

  group('opening the app settings', () {
    test('goes through the native side', () async {
      reply = (_) async => true;
      expect(await openAppSettings(), isTrue);
      expect(calls.single.method, 'openAppSettings');
    });

    test('a platform without it answers false instead of throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeFiles.channel, null);
      expect(await openAppSettings(), isFalse);
    });

    test('iOS without the method falls back and still never throws', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeFiles.channel, null);
      expect(await openAppSettings(), isFalse);
    });

    test('a failing native call reports false', () async {
      reply = (_) async => throw PlatformException(code: 'x');
      expect(await openAppSettings(), isFalse);
    });
  });

  test('app info carries the support address; the policy url stays empty until provided', () {
    expect(AppInfo.appName, 'JARVIS');
    expect(AppInfo.privacyPolicyUrl, isEmpty);
    expect(AppInfo.supportEmail, isEmpty);
  });
}

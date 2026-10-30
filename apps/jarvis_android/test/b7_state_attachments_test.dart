import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';

import 'support.dart';

const files = MethodChannel('ai.jarvis.app/files');
const picker = MethodChannel('plugins.flutter.io/file_selector');

Map<String, Object> photo(String name) => {
  'name': name,
  'bytes': Uint8List.fromList([1, 2, 3]),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late JarvisController c;
  Future<Object?> Function(MethodCall)? answer;

  setUp(() async {
    calls = [];
    answer = null;
    messenger.setMockMethodCallHandler(files, (call) async {
      calls.add(call);
      if (call.method == 'normalizeImage') return call.arguments;
      return answer?.call(call);
    });
    messenger.setMockMethodCallHandler(picker, (call) async {
      calls.add(call);
      return <String>[];
    });
    c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    c
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
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(files, null);
    messenger.setMockMethodCallHandler(picker, null);
    c.dispose();
  });

  Future<String?> failure(Future<void> Function() run) async {
    try {
      await run();
    } on JarvisException catch (e) {
      return e.message;
    }
    return null;
  }

  test(
    'the composer counts as loading while the photo picker is open',
    () async {
      final seen = <bool>[];
      answer = (call) async {
        if (call.method == 'pickPhotos') {
          seen.add(c.attachmentsLoading(c.current.id));
          return [photo('IMG_1.jpg')];
        }
        return null;
      };
      await choosePhotos(c);
      expect(seen, [true]);
      expect(c.attachmentsLoading(c.current.id), isFalse);
      expect(c.current.pendingAttachments.single.name, 'IMG_1.jpg');
    },
  );

  test('a cancelled or failed pick lets go of the loading state', () async {
    answer = (call) async => throw PlatformException(code: 'busy');
    await failure(() => takePhotoAttachment(c)).catchError((_) => null);
    expect(c.attachmentsLoading(c.current.id), isFalse);
  });

  test('pictures that fail do not stop the others', () async {
    answer = (call) async => call.method == 'pickPhotos'
        ? [
            photo('IMG_1.jpg'),
            {'error': '图片无法下载，请检查网络后重试'},
            photo('IMG_3.heic'),
            {'error': '图片文件过大，请选择20MB以内的图片'},
          ]
        : null;
    final message = await failure(() => choosePhotos(c));
    expect(message, '2 张未能添加：图片无法下载，请检查网络后重试');
    // The picker's pictures skip the extension list: heic goes straight to the image bridge on any platform.
    expect(c.current.pendingAttachments.map((a) => a.name), [
      'IMG_1.jpg',
      'IMG_3.heic',
    ]);
    expect(c.attachmentsLoading(c.current.id), isFalse);
  });

  test('a single failed picture keeps its own message', () async {
    answer = (call) async => call.method == 'pickPhotos'
        ? [
            {'error': '图片无法读取'},
          ]
        : null;
    expect(await failure(() => choosePhotos(c)), '图片无法读取');
    expect(c.current.pendingAttachments, isEmpty);
  });

  test('a batch of files keeps going after one is refused', () async {
    final owner = c.current;
    Future<Uint8List> bytes(String s) async => Uint8List.fromList(s.codeUnits);
    AttachmentSource file(String name, String body) => (
      name: name,
      length: () async => body.length,
      read: () => bytes(body),
      isImage: false,
    );
    final message = await failure(
      () => attachFiles(c, owner, [
        file('a.txt', 'hello'),
        file('b.exe', 'nope'),
        file('c.md', 'world'),
      ]),
    );
    expect(message, '1 个未能添加：不支持此附件格式');
    expect(owner.pendingAttachments.map((a) => a.name), ['a.txt', 'c.md']);
    expect(
      await failure(() => attachFiles(c, owner, [file('d.exe', 'x')])),
      '不支持此附件格式',
    );
  });

  test('a full composer says so before any picker opens', () async {
    for (var i = 0; i < 4; i++) {
      c.current.pendingAttachments.add(
        Attachment(
          id: 'a$i',
          name: 'a$i.txt',
          mime: 'text/plain',
          kind: 'document',
        ),
      );
    }
    expect(await failure(() => choosePhotos(c)), '每条消息最多4个附件');
    expect(await failure(() => takePhotoAttachment(c)), '每条消息最多4个附件');
    expect(await failure(() => chooseAttachments(c)), '每条消息最多4个附件');
    expect(calls, isEmpty);
  });

  test('a text-only model is refused only when there is room', () async {
    c.models = [ModelInfo('test-model', 'Test model')];
    expect(await failure(() => choosePhotos(c)), '当前模型不支持图片输入');
    expect(calls.where((m) => m.method == 'pickPhotos'), isEmpty);
  });
}

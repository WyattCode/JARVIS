import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/attachments.dart';
import 'package:jarvis_android/state/backup.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/local_data.dart';

import 'support.dart';

Attachment image(String id, int size) => Attachment(
  id: id,
  name: '$id.jpg',
  mime: 'image/jpeg',
  kind: 'image',
  size: size,
);

Uint8List bytesOf(int n, int seed) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 0xff]);

List<FileSystemEntity> leftovers() => [
  for (final e
      in tempFolder('jarvis-backup').existsSync()
          ? tempFolder('jarvis-backup').listSync(recursive: true)
          : <FileSystemEntity>[])
    if (e is File) e,
];

Future<JarvisController> fresh() async {
  final c = JarvisController(FakeApi(), MemoryVault());
  await c.initialize();
  return c;
}

/// [count] conversations, each with one picture of [size] bytes.
Future<void> fill(JarvisController c, int count, int size) async {
  c.conversations.clear();
  for (var i = 0; i < count; i++) {
    final conv = Conversation('c$i', title: '会话$i');
    await c.blobs.put('b$i', bytesOf(size, i));
    conv.messages.add(
      ChatMessage('user', '图$i', attachments: [image('b$i', size)]),
    );
    c.conversations.add(conv);
  }
  c.selectedId = 'c0';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final defaults = (BackupLimits.importBytes, BackupLimits.partBytes);
  setUp(() {
    root = Directory.systemTemp.createTempSync('a3_backup');
    debugTempRoot = root;
  });
  tearDown(() {
    debugTempRoot = null;
    BackupLimits.importBytes = defaults.$1;
    BackupLimits.partBytes = defaults.$2;
    debugDefaultTargetPlatformOverride = null;
    root.deleteSync(recursive: true);
  });

  test(
    'a backup that fits is one file and round-trips with odd-sized attachments',
    () async {
      final c = await fresh();
      // Not a multiple of 3 and longer than one write chunk.
      await fill(c, 2, 48 * 1024 * 2 + 17);
      final export = await c.exportBackupFiles();
      expect(export.files, hasLength(1));
      expect(
        export.files.single.uri.pathSegments.last,
        matches(r'^jarvis-conversations-\d+\.json$'),
      );
      final text = await export.files.single.readAsString();
      expect((jsonDecode(text) as Map)['version'], 3);

      final second = await fresh();
      expect(
        await second.importBackup(await export.files.single.readAsBytes()),
        2,
      );
      for (var i = 0; i < 2; i++) {
        final a = second.conversations
            .firstWhere((x) => x.title == '会话$i')
            .messages
            .single
            .attachments
            .single;
        expect(await second.blobs.get(a.id), bytesOf(48 * 1024 * 2 + 17, i));
      }
      await export.dispose();
      expect(export.folder.existsSync(), isFalse);
      c.dispose();
      second.dispose();
    },
  );

  test(
    'a large history is split into parts that each import on their own',
    () async {
      BackupLimits.importBytes = 200 * 1000;
      BackupLimits.partBytes = 100 * 1000;
      final c = await fresh();
      await fill(c, 10, 30 * 1000);
      final export = await c.exportBackupFiles();
      expect(export.files.length, greaterThan(2));
      expect(
        export.files.map((f) => f.uri.pathSegments.last),
        everyElement(contains('of${export.files.length}')),
      );
      final titles = <String>{};
      for (final file in export.files) {
        expect(file.lengthSync(), lessThanOrEqualTo(BackupLimits.importBytes));
        final part = await fresh();
        final count = await part.importBackup(await file.readAsBytes());
        expect(count, greaterThan(0));
        for (final conv in part.conversations.where(
          (x) => x.title.startsWith('会话'),
        )) {
          titles.add(conv.title);
          final a = conv.messages.single.attachments.single;
          expect((await part.blobs.get(a.id)).length, 30 * 1000);
        }
        part.dispose();
      }
      expect(titles, {for (var i = 0; i < 10; i++) '会话$i'});
      await export.dispose();
      c.dispose();
    },
  );

  test('one conversation bigger than a part still fits in one file under the import limit', () async {
    BackupLimits.importBytes = 200 * 1000;
    BackupLimits.partBytes = 100 * 1000;
    final c = await fresh();
    c.conversations.clear();
    final conv = Conversation('big', title: '大会话');
    for (var i = 0; i < 3; i++) {
      await c.blobs.put('p$i', bytesOf(30 * 1000, i));
    }
    conv.messages.add(
      ChatMessage(
        'user',
        '三张',
        attachments: [for (var i = 0; i < 3; i++) image('p$i', 30 * 1000)],
      ),
    );
    c.conversations.add(conv);
    c.selectedId = 'big';
    final export = await c.exportBackupFiles();
    expect(export.files, hasLength(1));
    expect(
      export.files.single.lengthSync(),
      greaterThan(BackupLimits.partBytes),
    );
    expect(
      await (await fresh()).importBackup(
        await export.files.single.readAsBytes(),
      ),
      1,
    );
    await export.dispose();
    c.dispose();
  });

  test('a conversation no file can hold is refused at export, naming it, and leaves nothing behind', () async {
    BackupLimits.importBytes = 100 * 1000;
    BackupLimits.partBytes = 50 * 1000;
    final c = await fresh();
    await fill(c, 1, 90 * 1000);
    c.conversations.single.title = '太大的会话';
    await expectLater(
      c.exportBackupFiles(),
      throwsA(
        isA<JarvisException>().having(
          (e) => e.message,
          'message',
          contains('太大的会话'),
        ),
      ),
    );
    expect(leftovers(), isEmpty);
    // The old single-block API refuses too instead of producing something unimportable.
    await expectLater(c.exportBackup(), throwsA(isA<JarvisException>()));
    c.dispose();
  });

  test('an attachment whose recorded size was wrong cannot slip an unimportable file out', () async {
    BackupLimits.importBytes = 100 * 1000;
    BackupLimits.partBytes = 80 * 1000;
    final c = await fresh();
    await fill(c, 1, 90 * 1000);
    // Claims 1 KB, really 90 KB.
    c.conversations.single.messages.single.attachments
      ..clear()
      ..add(image('b0', 1000));
    await expectLater(c.exportBackupFiles(), throwsA(isA<JarvisException>()));
    expect(leftovers(), isEmpty);
    c.dispose();
  });

  test(
    'exactly at the limit exports and imports, one byte over does neither',
    () async {
      final c = await fresh();
      await fill(c, 1, 5000);
      var export = await c.exportBackupFiles();
      final size = export.files.single.lengthSync();
      final bytes = await export.files.single.readAsBytes();
      await export.dispose();

      BackupLimits.importBytes = size;
      export = await c.exportBackupFiles();
      expect(export.files.single.lengthSync(), lessThanOrEqualTo(size));
      await export.dispose();
      expect(await (await fresh()).importBackup(bytes), 1);

      BackupLimits.importBytes = size - 1;
      await expectLater(c.importBackup(bytes), throwsA(isA<JarvisException>()));
      c.dispose();
    },
  );

  test('missing attachments are counted over all parts', () async {
    BackupLimits.partBytes = 5000;
    final c = await fresh();
    await fill(c, 3, 3000);
    await c.blobs.delete('b0');
    await c.blobs.delete('b2');
    final export = await c.exportBackupFiles();
    expect(c.backupSkipped, unorderedEquals(['b0', 'b2']));
    for (final file in export.files) {
      expect(
        await (await fresh()).importBackup(await file.readAsBytes()),
        greaterThan(0),
      );
    }
    await export.dispose();
    c.dispose();
  });

  test(
    'an old web backup whose media list has a null url still imports',
    () async {
      final c = await fresh();
      final backup = {
        'version': 2,
        'files': [],
        'conversations': [
          {
            'id': 'web',
            'title': '旧会话',
            'msgs': [
              {
                'role': 'tool',
                'id': 'm1',
                'media': [
                  {'url': null},
                  {'url': '/v1/files/a.png'},
                ],
              },
            ],
          },
        ],
      };
      expect(
        await c.importBackup(
          Uint8List.fromList(utf8.encode(jsonEncode(backup))),
        ),
        1,
      );
      expect(c.conversations.first.tasks.single.urls, ['/v1/files/a.png']);
      c.dispose();
    },
  );

  test('the legacy bytes export still returns one importable block', () async {
    final c = await fresh();
    await fill(c, 2, 1000);
    final bytes = await c.exportBackup();
    expect(await (await fresh()).importBackup(bytes), 2);
    expect(leftovers(), isEmpty);
    c.dispose();
  });

  test('the app field and the diagnostics name the platform', () async {
    final c = await fresh();
    await fill(c, 1, 10);
    expect(
      jsonDecode(utf8.decode(await c.exportBackup()))['app'],
      'jarvis-android',
    );
    expect(jsonDecode(c.diagnostics())['app'], 'Jarvis Android');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final bytes = await c.exportBackup();
    expect(jsonDecode(utf8.decode(bytes))['app'], 'jarvis-ios');
    expect(jsonDecode(c.diagnostics())['app'], 'Jarvis iOS');
    // Backups from before the rename still import.
    final old = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>
      ..['app'] = 'jarvis-android';
    expect(
      await (await fresh()).importBackup(
        Uint8List.fromList(utf8.encode(jsonEncode(old))),
      ),
      1,
    );
    c.dispose();
  });

  test(
    'exportAndSaveBackup hands the files to the system by path and cleans up',
    () async {
      BackupLimits.partBytes = 5000;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final c = await fresh();
      await fill(c, 3, 3000);
      final calls = <MethodCall>[];
      final existed = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeFiles.channel, (call) async {
            calls.add(call);
            for (final f in (call.arguments as Map)['files'] as List) {
              existed.add(File(f['path'] as String).existsSync());
            }
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeFiles.channel, null),
      );
      final parts = await c.exportAndSaveBackup();
      expect(parts, greaterThan(1));
      expect(calls.single.method, 'save');
      final files = (calls.single.arguments as Map)['files'] as List;
      expect(files, hasLength(parts));
      expect(
        files.map((f) => f['name']),
        everyElement(matches(r'^jarvis-conversations-\d+-\dof\d\.json$')),
      );
      expect(existed, everyElement(isTrue));
      expect(
        leftovers(),
        isEmpty,
        reason: 'staged files are removed afterwards',
      );
      c.dispose();
    },
  );
}

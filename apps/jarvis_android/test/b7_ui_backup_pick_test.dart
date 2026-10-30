import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/backup.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';

import 'support.dart';

const picker = MethodChannel('plugins.flutter.io/file_selector');

Future<JarvisController> fresh() async {
  final c = JarvisController(FakeApi(), MemoryVault());
  await c.initialize();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the real picker lets several backup parts be chosen at once', () async {
    final source = await fresh();
    source.conversations
      ..clear()
      ..add(
        Conversation('a', title: '会话A')
          ..messages.add(ChatMessage('user', '你好')),
      )
      ..add(
        Conversation('b', title: '会话B')
          ..messages.add(ChatMessage('user', '再见')),
      );
    final bytes = await source.exportBackup();
    final dir = Directory.systemTemp.createTempSync('b7-pick');
    addTearDown(() => dir.deleteSync(recursive: true));
    final one = File('${dir.path}/1.json')..writeAsBytesSync(bytes);
    final two = File('${dir.path}/2.json')..writeAsBytesSync(bytes);
    final calls = <MethodCall>[];
    var chosen = <String>[one.path, two.path];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
          calls.add(call);
          return chosen;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(picker, null),
    );

    final target = await fresh();
    final before = target.conversations.length;
    final count = await SettingsPage.pickBackup(target);
    expect(calls.single.arguments['multiple'], true);
    expect(count, 4, reason: 'both parts are imported');
    expect(target.conversations.length, before + 4);

    chosen = <String>[];
    expect(await SettingsPage.pickBackup(target), isNull, reason: 'cancelled');
    expect(target.conversations.length, before + 4);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/vault.dart';

import 'support.dart';

/// A vault whose first read is still pending, like a slow Keychain/disk on a cold start.
class SlowVault implements Vault {
  SlowVault(this.stored);
  String? stored;
  final readGate = Completer<void>();
  final writes = <String>[];
  @override
  Future<String?> read() async {
    await readGate.future;
    return stored;
  }

  @override
  Future<void> write(String value) async {
    writes.add(value);
    stored = value;
  }
}

String savedState() => jsonEncode({
  'version': 1,
  'server': 'https://jarvis.example.com',
  'model': 'test-model',
  'settings': <String, dynamic>{},
  'cookie': '__Host-jarvis_session=keep-me',
  'selectedId': 'c1',
  'effort': 'high',
  'theme': 'dark',
  'themePreferenceVersion': 1,
  'conversations': [
    {'id': 'c1', 'title': '旧对话', 'messages': <Object>[]},
  ],
});

void main() {
  test('a stored file that cannot be read still blocks saving', () async {
    final vault = SlowVault('not json');
    final c = JarvisController(FakeApi(), vault);
    final init = c.initialize();
    vault.readGate.complete();
    await init;
    expect(c.storageReadOnly, isTrue);
    await c.save();
    expect(vault.writes, isEmpty);
    c.dispose();
  });

  test('a fresh install saves normally once started', () async {
    final vault = SlowVault(null)..readGate.complete();
    final c = JarvisController(FakeApi(), vault);
    await c.initialize();
    await c.save();
    expect(vault.writes, hasLength(1));
    c.dispose();
  });

  testWidgets('lifecycle inactive before the read finished writes nothing', (
    t,
  ) async {
    final vault = SlowVault(savedState());
    final c = JarvisController(FakeApi(), vault);
    await t.pumpWidget(JarvisApp(controller: c));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump(const Duration(milliseconds: 700));
    expect(vault.writes, isEmpty);
    vault.readGate.complete();
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    expect(c.initialized, isTrue);
    expect(vault.stored, savedState());
    await t.pumpWidget(const SizedBox());
  });
}

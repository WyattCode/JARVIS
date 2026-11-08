import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/sidebar_list.dart';

import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/net/jarvis_api.dart';
import 'package:jarvis_android/state/vault.dart';
import 'package:jarvis_android/model/settings.dart';

class MemoryVault implements Vault {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class FakeApi extends JarvisTransport {
  @override
  String? cookie;
  final streams = <String, StreamController<ChatDelta>>{};
  final cancelled = <String>[];
  @override
  Future<void> login(String username, String password) async {
    cookie = '__Host-jarvis_session=test';
  }

  @override
  Future<void> logout() async {
    cookie = null;
  }

  @override
  Future<List<ModelInfo>> models() async => [
    ModelInfo('test-model', 'Test model'),
  ];
  @override
  Stream<ChatDelta> chat(
    String requestId,
    String model,
    String effort,
    List<Map<String, dynamic>> messages, {
    ChatOptions options = const ChatOptions(),
  }) {
    final stream = StreamController<ChatDelta>();
    streams[requestId] = stream;
    return stream.stream;
  }

  @override
  void cancel(String requestId) {
    cancelled.add(requestId);
    streams[requestId]?.close();
  }

  @override
  void close() {
    for (final s in streams.values) {
      if (!s.isClosed) s.close();
    }
  }
}

/// Opens a conversation's menu the way a person does: by holding its row.
Future<void> openConversationMenu(WidgetTester t, {int index = 0}) async {
  final rows = find.descendant(
    of: find.byKey(const Key('conversation-list')),
    matching: find.byType(ConversationRowTile),
  );
  await t.longPress(rows.at(index));
  // Not pumpAndSettle: the welcome reactor never stops moving.
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// Deletes a conversation as a person does: hold its row, choose 删除, and
/// confirm.
Future<void> deleteConversationViaMenu(WidgetTester t, {int index = 0}) async {
  await openConversationMenu(t, index: index);
  await t.tap(find.text('删除'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('confirm-delete')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
}

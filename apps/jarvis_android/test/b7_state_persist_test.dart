import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/state/vault.dart';

import 'support.dart';

class WipingVault extends MemoryVault implements EvidenceWiper {
  int wiped = 0;
  @override
  Future<void> wipeEvidence() async => wiped++;
}

class CountingVault extends MemoryVault {
  int writes = 0;
  @override
  Future<void> write(String value) async {
    writes++;
    await super.write(value);
  }
}

class FailingOnceVault extends CountingVault {
  @override
  Future<void> write(String value) async {
    if (writes++ == 0) throw Exception('disk full');
    this.value = value;
  }
}

void main() {
  group('continueReply', () {
    test('leaves no draft behind when sending cannot happen', () async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      // Signed out.
      await c.continueReply();
      expect(c.current.draft, isEmpty);
      await c.login('a', 'b');
      // No model.
      c.model = '';
      await c.continueReply();
      expect(c.current.draft, isEmpty);
      // Attachments still loading.
      c.model = 'test-model';
      c.beginAttachment(c.current);
      await c.continueReply();
      expect(c.current.draft, isEmpty);
      c.endAttachment(c.current);
      c.dispose();
    });

    test('does not touch what the person already typed', () async {
      final c = JarvisController(FakeApi(), MemoryVault());
      await c.initialize();
      await c.login('a', 'b');
      c.setDraft('我的草稿');
      await c.continueReply();
      expect(c.current.draft, '我的草稿');
      c.dispose();
    });
  });

  group('saving while a reply streams', () {
    test('a stream of changes still writes within the max wait', () async {
      final vault = CountingVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      c.maxSaveWait = const Duration(milliseconds: 60);
      final before = vault.writes;
      // Faster than the 500 ms debounce, as streamed deltas are.
      for (var i = 0; i < 20; i++) {
        c.scheduleSave();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      expect(vault.writes, greaterThan(before));
      c.dispose();
    });
  });

  group('saving when the app leaves the foreground', () {
    test('writes once, then skips until something changes', () async {
      final vault = CountingVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.login('a', 'b');
      await c.save();
      final settled = vault.writes;
      await c.saveIfDirty();
      await c.saveIfDirty();
      expect(vault.writes, settled, reason: 'nothing changed since the write');
      // A change that goes through the controller.
      c.setDraft('新的草稿');
      await c.saveIfDirty();
      expect(vault.writes, settled + 1);
      await c.saveIfDirty();
      expect(vault.writes, settled + 1);
      // A change behind its back: the cookie is part of the saved file.
      c.api.cookie = 'new-cookie';
      await c.saveIfDirty();
      expect(vault.writes, settled + 2);
      expect(vault.value, contains('new-cookie'));
      // A pending debounce counts as unsaved.
      c.scheduleSave();
      await c.saveIfDirty();
      expect(vault.writes, settled + 3);
      c.dispose();
    });

    test('a failed write is tried again', () async {
      final vault = FailingOnceVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      await c.save();
      expect(c.persistFailed, isTrue);
      final tries = vault.writes;
      await c.saveIfDirty();
      expect(vault.writes, tries + 1);
      expect(c.persistFailed, isFalse);
      c.dispose();
    });
  });

  group('attachment files of removed conversations', () {
    test(
      'wiping conversations reclaims files still in the undo window',
      () async {
        final c = JarvisController(FakeApi(), MemoryVault());
        await c.initialize();
        await c.blobs.put('att', Uint8List.fromList([1]));
        c.current.messages.add(
          ChatMessage(
            'user',
            'x',
            attachments: [
              Attachment(
                id: 'att',
                name: 'a.jpg',
                mime: 'image/jpeg',
                kind: 'image',
              ),
            ],
          ),
        );
        final id = c.current.id;
        c.newConversation();
        c.deleteConversation(id);
        expect(c.wipeConversations(), isTrue);
        await c.save();
        expect(await c.blobs.list(), isEmpty);
        c.dispose();
      },
    );
  });

  group('clearLocalData', () {
    test('resets the theme and wipes the kept unreadable copies', () async {
      final vault = WipingVault();
      final c = JarvisController(FakeApi(), vault);
      await c.initialize();
      c.setTheme('light');
      expect(await c.clearLocalData(), isTrue);
      expect(c.theme, 'dark');
      expect(vault.wiped, 1);
      expect(vault.value, contains('"theme":"dark"'));
      c.dispose();
    });
  });
}

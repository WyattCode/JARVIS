import 'package:flutter/services.dart';

abstract class Vault {
  Future<String?> read();
  Future<void> write(String value);
}

/// A vault that can set aside the saved file it failed to read before that file is replaced.
abstract interface class UnreadableKeeper {
  Future<void> keepUnreadable();
}

/// A vault that can delete the unreadable-file copies it set aside (see [UnreadableKeeper]).
abstract interface class EvidenceWiper {
  Future<void> wipeEvidence();
}

/// A vault that can delete the saved file itself: an erase whose last write failed must not leave the old one behind.
abstract interface class StateEraser {
  Future<void> eraseState();
}

/// AES-GCM at rest; the key lives in Android Keystore or the iOS Keychain (ai.jarvis.app/vault).
class NativeVault
    implements Vault, UnreadableKeeper, EvidenceWiper, StateEraser {
  static const _channel = MethodChannel('ai.jarvis.app/vault');
  @override
  Future<String?> read() => _channel.invokeMethod<String>('read');
  @override
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', value);
  @override
  Future<void> keepUnreadable() async {
    try {
      await _channel.invokeMethod<void>('keepUnreadable');
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<void> wipeEvidence() async {
    try {
      await _channel.invokeMethod<void>('wipeEvidence');
    } on MissingPluginException {
      return;
    }
  }

  // No MissingPluginException fallback: a platform that cannot delete the file has not erased it.
  @override
  Future<void> eraseState() => _channel.invokeMethod<void>('eraseState');
}

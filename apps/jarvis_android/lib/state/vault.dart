import 'package:flutter/services.dart';

abstract class Vault {
  Future<String?> read();
  Future<void> write(String value);
}

/// AES-GCM at rest; the key lives in Android Keystore or the iOS Keychain (cc.odn.jarvis/vault).
class NativeVault implements Vault {
  static const _channel = MethodChannel('cc.odn.jarvis/vault');
  @override
  Future<String?> read() => _channel.invokeMethod<String>('read');
  @override
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', value);
}

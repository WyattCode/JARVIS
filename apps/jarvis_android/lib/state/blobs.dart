import 'package:flutter/services.dart';

abstract class BlobStore {
  Future<void> put(String id, Uint8List value);
  Future<Uint8List> get(String id);
}

class NativeBlobs implements BlobStore {
  static const channel = MethodChannel('cc.odn.jarvis/vault');
  @override
  Future<void> put(String id, Uint8List value) =>
      channel.invokeMethod('writeBlob', {'id': id, 'bytes': value});
  @override
  Future<Uint8List> get(String id) async {
    final value = await channel.invokeMethod<Uint8List>('readBlob', id);
    if (value == null) throw StateError('附件不存在');
    return value;
  }
}

class MemoryBlobs implements BlobStore {
  final _data = <String, Uint8List>{};
  @override
  Future<void> put(String id, Uint8List value) async {
    _data[id] = Uint8List.fromList(value);
  }

  @override
  Future<Uint8List> get(String id) async {
    final data = _data[id];
    if (data == null) throw StateError('附件不存在');
    return Uint8List.fromList(data);
  }
}

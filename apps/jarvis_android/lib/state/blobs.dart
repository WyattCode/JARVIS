import 'package:flutter/services.dart';

abstract class BlobStore {
  Future<void> put(String id, Uint8List value);
  Future<Uint8List> get(String id);
  Future<void> delete(String id);

  /// Ids of every stored attachment.
  Future<List<String>> list();
}

class NativeBlobs implements BlobStore {
  static const channel = MethodChannel('ai.jarvis.app/vault');
  @override
  Future<void> put(String id, Uint8List value) =>
      channel.invokeMethod('writeBlob', {'id': id, 'bytes': value});
  @override
  Future<Uint8List> get(String id) async {
    final value = await channel.invokeMethod<Uint8List>('readBlob', id);
    if (value == null) throw StateError('附件不存在');
    return value;
  }

  // Older native sides (Android) have no delete/list: nothing is collected there.
  @override
  Future<void> delete(String id) async {
    try {
      await channel.invokeMethod<void>('deleteBlob', id);
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<List<String>> list() async {
    try {
      return await channel.invokeListMethod<String>('listBlobs') ?? [];
    } on MissingPluginException {
      return [];
    }
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

  @override
  Future<void> delete(String id) async {
    _data.remove(id);
  }

  @override
  Future<List<String>> list() async => _data.keys.toList();
}

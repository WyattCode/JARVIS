import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import '../model/conversation.dart';
import '../model/media.dart';
import '../net/jarvis_api.dart';
import 'jarvis_controller.dart';
import 'local_data.dart';

/// A picked picture or file, already in memory. A picture from the photo picker or the camera is [isImage] whatever its
/// name says; one the picker could not load carries the reason in [error] instead of bytes.
class PickedFile {
  const PickedFile(this.name, this.bytes, {this.isImage = false, this.error});
  PickedFile.failed(String this.error)
    : name = '图片',
      bytes = Uint8List(0),
      isImage = true;
  final String name;
  final Uint8List bytes;
  final bool isImage;
  final String? error;
}

class NativeFiles {
  static const channel = MethodChannel('ai.jarvis.app/files');
  static Future<Uint8List> normalizeImage(Uint8List bytes) async {
    try {
      final result = await channel.invokeMethod<Uint8List>(
        'normalizeImage',
        bytes,
      );
      if (result == null) throw const JarvisException('图片无法读取');
      return result;
    } on PlatformException catch (e) {
      // The native side says which rule failed (too many pixels, still above 3MB after compressing, unreadable).
      if (e.code.startsWith('image_')) {
        throw JarvisException(e.message ?? '图片无法读取');
      }
      rethrow;
    }
  }

  static Future<bool> save(Uint8List bytes, String name, String mime) async =>
      await channel.invokeMethod<bool>('save', {
        'bytes': bytes,
        'name': name,
        'mime': mime,
      }) ??
      false;

  /// Offers files that already exist on disk to the system's save dialog, without reading them into memory (iOS). Other
  /// platforms fall back to the bytes API one file at a time. True when the user saved.
  static Future<bool> saveFiles(
    List<({String path, String name})> files,
    String mime,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      var saved = false;
      for (final f in files) {
        saved = await save(await File(f.path).readAsBytes(), f.name, mime);
        if (!saved) break;
      }
      return saved;
    }
    return await channel.invokeMethod<bool>('save', {
          'files': [
            for (final f in files) {'path': f.path, 'name': f.name},
          ],
          'mime': mime,
        }) ??
        false;
  }

  /// Like [saveFiles] for one file.
  static Future<bool> saveFile(String path, String name, String mime) =>
      saveFiles([(path: path, name: name)], mime);

  /// iOS only: puts a picture or video straight into the Photos library.
  static Future<bool> saveToPhotos(
    Uint8List bytes,
    String name,
    String mime,
  ) async =>
      await channel.invokeMethod<bool>('saveToPhotos', {
        'bytes': bytes,
        'name': name,
        'mime': mime,
      }) ??
      false;

  /// [saveToPhotos] for a file on disk (e.g. from `JarvisTransport.downloadTo`), so a large video is never read whole.
  static Future<bool> saveToPhotosFile(
    String path,
    String name,
    String mime,
  ) async =>
      await channel.invokeMethod<bool>('saveToPhotos', {
        'path': path,
        'name': name,
        'mime': mime,
      }) ??
      false;
  static Future<bool> share(Uint8List bytes, String name, String mime) async =>
      await channel.invokeMethod<bool>('share', {
        'bytes': bytes,
        'name': name,
        'mime': mime,
      }) ??
      false;

  /// [share] for a file on disk.
  static Future<bool> shareFile(String path, String name, String mime) async =>
      await channel.invokeMethod<bool>('share', {
        'path': path,
        'name': name,
        'mime': mime,
      }) ??
      false;

  /// iOS only: the system photo picker (needs no Photos permission: the app only receives what the person picks).
  /// Empty when cancelled. Pictures arrive as the picker's most compatible format (JPEG/PNG), named after the photo.
  static Future<List<PickedFile>> pickPhotos(int limit) async => _pictures(
    await channel.invokeMethod<List<Object?>>('pickPhotos', {'limit': limit}),
  );

  /// iOS only: takes one picture with the camera. Empty when cancelled.
  static Future<List<PickedFile>> takePhoto() async =>
      _pictures(await channel.invokeMethod<List<Object?>>('takePhoto'));

  /// One entry per picture in the order picked; one the system could not load arrives as `{error}` so the rest still count.
  static List<PickedFile> _pictures(List<Object?>? raw) => [
    for (final item in raw ?? const <Object?>[])
      if (item is Map)
        if (item['error'] is String)
          PickedFile.failed(item['error'] as String)
        else if (item['bytes'] is Uint8List)
          PickedFile(
            item['name'] as String? ?? 'photo.jpg',
            item['bytes'] as Uint8List,
            isImage: true,
          ),
  ];

  /// A fresh path in the transfer folder (emptied on sign-out) for a download that is about to be saved or shared.
  /// The caller deletes the file when done.
  static Future<File> transferFile(String extension) async {
    final folder = await tempFolder('jarvis-transfer').create(recursive: true);
    return File(
      '${folder.path}/${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
  }
}

/// Whether the attach button offers photos and the camera next to files (the system file picker of iOS does not
/// reach the photo library).
bool get attachesPhotos => defaultTargetPlatform == TargetPlatform.iOS;

void _requireImageInput(JarvisController controller) {
  final model = controller.models
      .where((m) => m.id == controller.model && m.kind == 'chat')
      .firstOrNull;
  if (model?.imageInput != true) {
    throw const JarvisException('当前模型不支持图片输入');
  }
}

int _roomForAttachments(JarvisController controller) {
  final room = 4 - controller.current.pendingAttachments.length;
  if (room <= 0) throw const JarvisException('每条消息最多4个附件');
  return room;
}

/// Pictures from the photo library (iOS). The composer shows the loading state while the system picker (and any iCloud
/// download behind it) runs, and sending waits for it.
Future<void> choosePhotos(JarvisController controller) async {
  final owner = controller.current;
  final room = _roomForAttachments(controller);
  _requireImageInput(controller);
  controller.beginAttachment(owner);
  try {
    final photos = await NativeFiles.pickPhotos(room);
    await attachFiles(controller, owner, _inMemory(photos));
  } finally {
    controller.endAttachment(owner);
  }
}

/// One picture from the camera (iOS).
Future<void> takePhotoAttachment(JarvisController controller) async {
  final owner = controller.current;
  _roomForAttachments(controller);
  _requireImageInput(controller);
  controller.beginAttachment(owner);
  try {
    final photos = await NativeFiles.takePhoto();
    await attachFiles(controller, owner, _inMemory(photos));
  } finally {
    controller.endAttachment(owner);
  }
}

Future<void> chooseAttachments(JarvisController controller) async {
  final owner = controller.current;
  _roomForAttachments(controller);
  final files = await openFiles(
    acceptedTypeGroups: [
      XTypeGroup(
        label: '图片、PDF与文本',
        extensions: [
          'jpg',
          'jpeg',
          'png',
          'webp',
          if (defaultTargetPlatform == TargetPlatform.iOS) ...['heic', 'heif'],
          'pdf',
          'txt',
          'md',
          'csv',
          'json',
          'log',
          'py',
          'js',
          'ts',
          'css',
          'html',
          'xml',
          'yaml',
          'yml',
          'sql',
          'sh',
          'ini',
          'toml',
        ],
        // iOS pickers ignore extensions and MIME types and only honour UTIs.
        uniformTypeIdentifiers: [
          'public.image',
          'com.adobe.pdf',
          'public.text',
          'public.json',
          'public.xml',
          'public.source-code',
          'public.yaml',
        ],
        mimeTypes: [
          'image/jpeg',
          'image/png',
          'image/webp',
          'application/pdf',
          'text/*',
          'application/json',
        ],
      ),
    ],
  );
  await attachFiles(controller, owner, [
    for (final file in files)
      (
        name: file.name,
        length: file.length,
        read: file.readAsBytes,
        isImage: false,
      ),
  ]);
}

Iterable<AttachmentSource> _inMemory(List<PickedFile> files) => [
  for (final file in files)
    (
      name: file.name,
      // A picture the system could not load fails here, like any other file that does not pass its checks.
      length: () async => file.error != null
          ? throw JarvisException(file.error!)
          : file.bytes.length,
      read: () async => file.bytes,
      isImage: file.isImage,
    ),
];

/// Something the person picked: read only once it has passed the size checks. [isImage]: it comes from a picture picker,
/// so the system image decoder (not the file name) decides whether it is usable.
typedef AttachmentSource = ({
  String name,
  Future<int> Function() length,
  Future<Uint8List> Function() read,
  bool isImage,
});

/// Checks, converts and adds what the person picked to [owner]'s message (up to four, 20 MB each). One file that fails
/// does not stop the others; when any failed, a single [JarvisException] says how many and why (the file's own message
/// when only one was picked).
Future<void> attachFiles(
  JarvisController controller,
  Conversation owner,
  Iterable<AttachmentSource> files,
) async {
  var total = 0;
  final failures = <({Object error, bool isImage})>[];
  for (final file in files) {
    if (!controller.conversations.contains(owner)) return;
    total++;
    try {
      await _attachOne(controller, owner, file);
    } on JarvisException catch (e) {
      if (e.unauthorized) rethrow;
      failures.add((error: e, isImage: file.isImage));
    } catch (e) {
      failures.add((error: e, isImage: file.isImage));
    }
  }
  if (failures.isEmpty) return;
  if (total == 1) throw failures.single.error;
  final first = failures.first.error;
  final unit = failures.every((f) => f.isImage) ? '张' : '个';
  throw JarvisException(
    '${failures.length} $unit未能添加：${first is JarvisException ? first.message : '文件无法读取'}',
  );
}

Future<void> _attachOne(
  JarvisController controller,
  Conversation owner,
  AttachmentSource file,
) async {
  if (owner.pendingAttachments.length >= 4) {
    throw const JarvisException('每条消息最多4个附件');
  }
  final bytesCount = await file.length();
  if (bytesCount > 20 * 1024 * 1024) {
    throw const JarvisException('单个附件不能超过20MB');
  }
  controller.beginAttachment(owner);
  try {
    final model = controller.models
        .where((m) => m.id == controller.model && m.kind == 'chat')
        .firstOrNull;
    final ext = file.name.toLowerCase().split('.').last;
    var bytes = await file.read();
    String? text;
    var mime = 'text/plain', kind = 'document';
    if (file.isImage ||
        [
          'jpg',
          'jpeg',
          'png',
          'webp',
          if (defaultTargetPlatform == TargetPlatform.iOS) ...['heic', 'heif'],
        ].contains(ext)) {
      if (model?.imageInput != true) {
        throw const JarvisException('当前模型不支持图片输入');
      }
      bytes = await NativeFiles.normalizeImage(bytes);
      mime = 'image/jpeg';
      kind = 'image';
    } else if (ext == 'pdf') {
      if (model?.pdfInput != true) {
        throw const JarvisException('当前入口未开放PDF文字提取');
      }
      mime = 'application/pdf';
      text = await controller.api.extractPdf(bytes);
    } else {
      if (![
        'txt',
        'md',
        'csv',
        'json',
        'log',
        'py',
        'js',
        'ts',
        'css',
        'html',
        'xml',
        'yaml',
        'yml',
        'sql',
        'sh',
        'ini',
        'toml',
      ].contains(ext)) {
        throw const JarvisException('不支持此附件格式');
      }
      if (bytes.length > 1024 * 1024) {
        throw const JarvisException('文本文件最大1MB');
      }
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        throw const JarvisException('文本文件需为UTF-8编码');
      }
      if (text.contains('\u0000')) {
        throw const JarvisException('此文件不是可读取的文本');
      }
    }
    if (text != null && (text.trim().isEmpty || text.length > 100000)) {
      throw const JarvisException('文件需有文字且不超过10万字符');
    }
    final item = Attachment(
      id: 'file_${DateTime.now().microsecondsSinceEpoch}',
      name: file.name,
      mime: mime,
      kind: kind,
      text: text,
      size: bytes.length,
    );
    await controller.addAttachment(owner, item, bytes);
  } finally {
    controller.endAttachment(owner);
  }
}

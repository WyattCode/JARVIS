import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import '../model/media.dart';
import '../net/jarvis_api.dart';
import 'jarvis_controller.dart';

/// Keep expected validation errors readable without exposing platform internals.
String attachmentErrorMessage(Object error) =>
    error is JarvisException ? error.message : '无法添加附件，请重试';

class NativeFiles {
  static const channel = MethodChannel('cc.odn.jarvis/files');
  static Future<Uint8List> normalizeImage(Uint8List bytes) async {
    final result = await channel.invokeMethod<Uint8List>(
      'normalizeImage',
      bytes,
    );
    if (result == null) throw const JarvisException('图片无法读取');
    return result;
  }

  static Future<bool> save(Uint8List bytes, String name, String mime) async =>
      await channel.invokeMethod<bool>('save', {
        'bytes': bytes,
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
}

Future<void> chooseAttachments(JarvisController controller) async {
  final owner = controller.current;
  final files = await openFiles(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: '图片、PDF与文本',
        extensions: [
          'jpg',
          'jpeg',
          'png',
          'webp',
          'heic',
          'heif',
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
  for (final file in files) {
    if (!controller.conversations.contains(owner)) return;
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
      var bytes = await file.readAsBytes();
      String? text;
      var mime = 'text/plain', kind = 'document';
      if (['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'].contains(ext)) {
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
        if (text.contains('\u0000')) throw const JarvisException('此文件不是可读取的文本');
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
}

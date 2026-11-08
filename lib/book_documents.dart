import 'dart:io';
import 'package:flutter/services.dart';

class BookDocumentSelection {
  const BookDocumentSelection({
    required this.name,
    this.path,
    this.error,
  }) : assert((path == null) != (error == null));

  final String name;
  final String? path, error;
}

class BookDocuments {
  BookDocuments();

  static const channel = MethodChannel('org.mewx.wenku8/book_documents');

  Future<BookDocumentSelection?> pickImage() async {
    final value = await channel.invokeMapMethod<String, dynamic>('pickImage');
    return value == null
        ? null
        : BookDocumentSelection(
            name: value['name'] as String,
            path: value['path'] as String,
          );
  }

  Future<BookDocumentSelection?> pickFont() async {
    final value = await channel.invokeMapMethod<String, dynamic>('pickFont');
    return value == null
        ? null
        : BookDocumentSelection(
            name: value['name'] as String,
            path: value['path'] as String,
          );
  }

  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    final paths = books
        .map((book) => book.path)
        .whereType<String>()
        .toSet()
        .toList();
    if (paths.isEmpty) return;
    await channel.invokeMethod<void>('releaseBooks', {'paths': paths});
  }

  Future<Map<String, dynamic>?> connect({required bool create}) => channel
      .invokeMapMethod<String, dynamic>(create ? 'createSync' : 'openSync');

  Future<Map<String, dynamic>?> info() =>
      channel.invokeMapMethod<String, dynamic>('syncInfo');

  Future<({File before, File output})> read() async {
    final value = await channel.invokeMapMethod<String, dynamic>('readSync');
    if (value == null) throw const FormatException('无法读取云同步文件');
    return (before: File(value['path']), output: File(value['outputPath']));
  }

  Future<void> write(File before, File next) => channel.invokeMethod<void>(
    'writeSync',
    {'path': next.path, 'expectedPath': before.path},
  );

  Future<void> disconnect() => channel.invokeMethod<void>('disconnectSync');

  Future<File?> recovery(String which) async {
    final path = await channel.invokeMethod<String>('recoverSync', {
      'which': which,
    });
    return path == null ? null : File(path);
  }
}

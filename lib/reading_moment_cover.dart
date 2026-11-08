import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import 'reading_moments.dart';

const _directoryName = 'reading-moment-covers-v1';
const _maxSnapshotBytes = 4 * 1024 * 1024;
const _maxWidth = 500;
const _maxHeight = 1000;

String _reference(int bookId, DateTime completedAt) =>
    '$_directoryName/completion-$bookId-${completedAt.millisecondsSinceEpoch}.png';

Future<Directory> _directory() async => Directory(
  '${(await getApplicationSupportDirectory()).path}/$_directoryName',
);

/// Reads only this event's immutable owned file. Missing historical covers are
/// not reconstructed from a current book, local source, cache or remote URL.
Future<Uint8List?> loadReadingMomentCover(
  ReadingCompletionSnapshot completion,
) async {
  try {
    final file = await _storedFile(completion);
    return file == null ? null : await _readSnapshot(file);
  } catch (_) {
    return null;
  }
}

/// Resolves a readable owned file, not its pixels. Native image decoding keeps
/// its existing failure path; repeated widget publications need no Dart decode.
Future<String?> resolveReadingMomentCoverPath(
  ReadingCompletionSnapshot completion,
) async {
  try {
    final file = await _storedFile(completion);
    if (file == null ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return null;
    }
    final stat = await file.stat();
    return stat.size > 0 && stat.size <= _maxSnapshotBytes ? file.path : null;
  } catch (_) {
    return null;
  }
}

bool isReadingMomentCoverReference(String? path) =>
    path?.startsWith('$_directoryName/') ?? false;

Future<File?> _storedFile(ReadingCompletionSnapshot completion) async {
  return _storedFileFor(
    bookId: completion.bookId,
    completedAt: completion.completedAt,
    path: completion.coverPath,
  );
}

Future<File?> _storedFileFor({
  required int bookId,
  required DateTime completedAt,
  required String? path,
}) async {
  if (path == null || path.isEmpty) return null;
  final reference = _reference(bookId, completedAt);
  // Reject unrelated files before even asking the platform for its root.
  if (path != reference && !path.endsWith('/$reference')) return null;
  final directory = await _directory();
  final file = File('${directory.parent.path}/$reference');
  // Retain compatibility with a previously saved absolute owned path, but do
  // not follow arbitrary external roots or traversal aliases from imports.
  if (path != reference && path != file.path) return null;
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return null;
  }
  return file;
}

Future<Uint8List?> _readSnapshot(File file) async {
  if (await FileSystemEntity.type(file.parent.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() > _maxSnapshotBytes) {
    return null;
  }
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width > _maxWidth || descriptor.height > _maxHeight) {
        return null;
      }
      final codec = await descriptor.instantiateCodec();
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  return bytes;
}

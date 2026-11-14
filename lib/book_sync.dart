import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_documents.dart';
import 'book_import_limits.dart';
import 'catalog.dart';
import 'cloud_sources.dart';
import 'library_backup.dart';
import 'library_state.dart';
import 'local_library.dart';

/// S3 implements the same read/merge/conditional-write boundary as a system
/// document. Recovery files remain local and contain no connection secrets.
class S3BookDocuments extends BookDocuments {
  S3BookDocuments({
    required this.connection,
    required this.directory,
    S3SyncObjectClient? client,
  }) : client = client ?? S3SyncObjectClient(connection);

  final S3SyncConnection connection;
  final Directory directory;
  final S3SyncObjectClient client;
  S3ObjectRevision? _revision;
  File? _before;
  File _file(String name) => File('${directory.path}/$name');
  String get identity => jsonEncode([
    connection.config.address,
    connection.config.bucket,
    connection.config.pathStyle,
    connection.objectKey,
  ]);

  @override
  Future<Map<String, dynamic>> info() async => {
    'provider': 'S3',
    'name': '${connection.config.bucket}/${connection.objectKey}',
    // A missing object is a valid initial state. An existing empty object is
    // rejected by the bounded S3 download instead of being overwritten.
    'created': true,
  };

  @override
  Future<({File before, File output})> read() async {
    await directory.create(recursive: true);
    _revision = null;
    _before = null;
    final pending = _file('incoming');
    final revision = await client.read(pending);
    final before = await pending.rename(_file('before').path);
    await _file('before-target').writeAsString(identity, flush: true);
    _revision = revision;
    _before = before;
    return (before: before, output: _file('next'));
  }

  @override
  Future<void> write(File before, File next) async {
    final revision = _revision;
    if (revision == null || before.path != _before?.path) {
      throw const FormatException('请先重新读取云端，再合并同步');
    }
    // Invalidate before sending: even an unconfirmed request cannot be resent
    // from the old snapshot. The next sync must GET and merge again.
    _revision = null;
    await _file('next-target').writeAsString(identity, flush: true);
    await client.write(next, revision);
  }

  @override
  Future<File?> recovery(String which) async {
    if (which != 'before' && which != 'next') return null;
    final file = _file(which);
    final target = _file('$which-target');
    if (!await file.exists() ||
        !await target.exists() ||
        await target.readAsString() != identity) {
      return null;
    }
    return file;
  }

  void close() => client.close();
}

class LocalBookInput {
  const LocalBookInput(this.name, this.bytes, {this.text});
  final String name;
  final Uint8List bytes;
  final String? text;
}

class BookSyncBundle {
  const BookSyncBundle(
    this.backup,
    this.books, {
    this.organization,
    this.bookMetadata,
    this.series,
  });
  final String backup;
  final List<LocalBookInput> books;
  final Map<String, dynamic>? organization;
  final Map<String, dynamic>? bookMetadata;
  final Map<String, dynamic>? series;
}

Uint8List encodeBookSync(BookSyncBundle bundle) {
  const maxUncompressedBytes = 512 * 1024 * 1024;
  final zip = Archive();
  final books = <Map<String, Object>>[];
  var totalUncompressed = 0;
  void addCheckedFile(String name, List<int> data) {
    totalUncompressed += data.length;
    if (totalUncompressed > maxUncompressedBytes) {
      throw const FormatException('同步内容展开大小超过 512 MiB 上限，请减少同步书籍后重试');
    }
    zip.addFile(ArchiveFile(name, data.length, data));
  }

  for (final (i, book) in bundle.books.indexed) {
    final path = 'books/$i/original';
    addCheckedFile(path, book.bytes);
    books.add({
      'name': book.name,
      'path': path,
      if (book.text != null) 'text': 'books/$i/decoded.txt',
    });
    if (book.text case final text?) {
      final bytes = utf8.encode(text);
      addCheckedFile('books/$i/decoded.txt', bytes);
    }
  }
  final metadata = utf8.encode(
    jsonEncode({
      'format': 'wenku8-book-sync',
      'version': 1,
      'books': books,
      if (bundle.organization != null) 'organization': bundle.organization,
      if (bundle.series != null) 'series': bundle.series,
    }),
  );
  final backup = utf8.encode(bundle.backup);
  if (metadata.length > LibraryBackup.maxBytes) {
    throw const FormatException('同步书目超过 4 MiB，请减少单次同步的书目与分卷');
  }
  addCheckedFile('manifest.json', metadata);
  if (bundle.bookMetadata != null) {
    final edits = utf8.encode(jsonEncode(bundle.bookMetadata));
    if (edits.length > LibraryBackup.maxBytes) {
      throw const FormatException('书籍信息超过同步大小限制');
    }
    addCheckedFile('book-info.json', edits);
  }
  addCheckedFile('library.json', backup);
  final bytes = ZipEncoder().encode(zip);
  if (bytes.length > 256 * 1024 * 1024) {
    throw const FormatException('同步文件超过 256 MB，请减少本地书籍后重试');
  }
  return Uint8List.fromList(bytes);
}

Archive boundedZip(
  Uint8List bytes, {
  int maxSize = 160 * 1024 * 1024,
  int maxEntrySize = 40 * 1024 * 1024,
}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  var total = 0;
  for (final file in archive) {
    if (!file.isFile) continue;
    if (file.size < 0 || file.size > maxEntrySize) {
      throw const FormatException('压缩包条目过大');
    }
    total += file.size;
    if (total > maxSize) {
      throw const FormatException('压缩包展开大小超过上限');
    }
  }
  return archive;
}

BookSyncBundle decodeBookSync(Uint8List bytes) {
  if (bytes.length > 256 * 1024 * 1024) throw const FormatException('同步文件过大');
  final zip = boundedZip(
    bytes,
    maxSize: 512 * 1024 * 1024,
    maxEntrySize: maxLocalEpubBytes,
  );
  final files = {
    for (final f in zip)
      if (f.isFile) f.name: f,
  };
  String text(String name, int max) {
    final file = files[name];
    if (file == null || file.size > max) throw const FormatException('同步文件不完整');
    return utf8.decode(file.readBytes()!);
  }

  final manifest = jsonDecode(text('manifest.json', LibraryBackup.maxBytes));
  if (manifest is! Map ||
      manifest['format'] != 'wenku8-book-sync' ||
      ![1, 2].contains(manifest['version']) ||
      manifest['books'] is! List ||
      manifest['books'].length > 200) {
    throw const FormatException('请选择文库生成的 .wenku8sync 同步文件');
  }
  final books = <LocalBookInput>[];
  final paths = <String>{};
  for (final value in manifest['books']) {
    if (value is! Map ||
        value['name'] is! String ||
        value['path'] is! String ||
        (value['name'] as String).length > 2048 ||
        !paths.add(value['path'])) {
      throw const FormatException('同步书籍信息有误');
    }
    final file = files[value['path']];
    if (file == null || file.size > localBookByteLimit(value['name'])) {
      throw const FormatException('同步原书不存在或过大');
    }
    books.add(
      LocalBookInput(
        value['name'],
        file.readBytes()!,
        text: value['text'] is String
            ? text(value['text'], maxLocalTextBytes)
            : null,
      ),
    );
  }
  return BookSyncBundle(
    text('library.json', LibraryBackup.maxBytes),
    books,
    organization: manifest['organization'] is Map
        ? Map<String, dynamic>.from(manifest['organization'] as Map)
        : null,
    bookMetadata: files.containsKey('book-info.json')
        ? Map<String, dynamic>.from(
            jsonDecode(text('book-info.json', LibraryBackup.maxBytes)) as Map,
          )
        : null,
    series: manifest['series'] is Map
        ? Map<String, dynamic>.from(manifest['series'] as Map)
        : null,
  );
}

class BookSync extends ChangeNotifier {
  BookSync({
    required this.state,
    required this.preferences,
    LocalLibraryStore? books,
    BookDocuments? documents,
    this.cloudSources,
    this.s3ClientFactory,
    Directory? syncDirectory,
  }) : books = books ?? state.localLibrary,
       documents = documents ?? BookDocuments(),
       _syncDirectory = syncDirectory {
    cloudSources?.addListener(_notify);
  }

  final LocalLibraryStore? books;
  final LibraryState state;
  final SharedPreferences preferences;
  final BookDocuments documents;
  final CloudSourceSettings? cloudSources;
  final S3SyncObjectClient Function(S3SyncConnection)? s3ClientFactory;
  final Directory? _syncDirectory;

  bool get usingS3 => preferredProvider == 'S3';
  S3SyncConnection? get s3Connection => cloudSources?.s3Sync;
  bool get connected => usingS3 ? s3Connection != null : connection != null;
  bool get syncOriginals => preferences.getBool('bookSyncOriginals') ?? true;
  bool get syncReading => preferences.getBool('bookSyncReading') ?? true;
  bool get syncCategories => preferences.getBool('bookSyncCategories') ?? true;
  String get preferredProvider =>
      preferences.getString('bookSyncProvider') ?? 'S3';
  String get providerLabel {
    if (usingS3) return 'S3';
    final authority = '${connection?['authority'] ?? ''}'.toLowerCase();
    if (authority.contains('microsoft') ||
        authority.contains('skydrive') ||
        authority.contains('onedrive')) {
      return 'OneDrive';
    }
    if (authority.contains('com.google.android')) return 'Google Drive';
    return connection?['provider'] as String? ?? '系统文档';
  }

  Future<void> configure({
    bool? originals,
    bool? reading,
    bool? categories,
    String? provider,
  }) async {
    if (busy) return;
    for (final entry in {
      'bookSyncOriginals': originals,
      'bookSyncReading': reading,
      'bookSyncCategories': categories,
    }.entries) {
      if (entry.value != null &&
          !await preferences.setBool(entry.key, entry.value!)) {
        throw const FormatException('同步设置保存失败');
      }
    }
    if (provider != null &&
        !await preferences.setString('bookSyncProvider', provider)) {
      throw const FormatException('同步设置保存失败');
    }
    if (provider != null) {
      error = null;
      status = null;
    }
    _notify();
  }

  static BookSync? _activeOperation;
  Map<String, dynamic>? connection;
  bool busy = false;
  String? error, status;
  bool _disposed = false;

  int? get lastSync => usingS3
      ? preferences.getString('bookSyncS3Target') == _s3Identity
            ? preferences.getInt('bookSyncS3At')
            : null
      : preferences.getInt('bookSyncAt');

  String? get _s3Identity {
    final value = s3Connection;
    return value == null
        ? null
        : jsonEncode([
            value.config.address,
            value.config.bucket,
            value.config.pathStyle,
            value.objectKey,
          ]);
  }

  Future<BookDocuments> _adapter() async {
    if (!usingS3) return documents;
    final value = s3Connection;
    if (value == null) throw const FormatException('请先保存 S3 同步连接');
    final baseDir =
        _syncDirectory ??
        books?.directory ??
        await getApplicationSupportDirectory();
    return S3BookDocuments(
      connection: value,
      directory: Directory('${baseDir.path}/sync-s3'),
      client: s3ClientFactory?.call(value),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _begin() {
    if (_disposed || busy) return false;
    if (_activeOperation != null) {
      error = null;
      status = '正在完成上一次云端同步，请稍后重试';
      _notify();
      return false;
    }
    _activeOperation = this;
    busy = true;
    error = null;
    status = null;
    return true;
  }

  void _end() {
    if (identical(_activeOperation, this)) _activeOperation = null;
    busy = false;
    _notify();
  }

  Future<void> load() async {
    try {
      connection = await documents.info();
    } catch (failure) {
      if (!usingS3) error = _describe(failure);
    }
    _notify();
  }

  Future<void> connect({required bool create}) async {
    if (usingS3) return;
    if (!_begin()) return;
    _notify();
    try {
      final value = await documents.connect(create: create);
      if (value != null) {
        connection = value;
        status = '已连接，点按立即同步开始合并';
      }
    } catch (failure) {
      error = _describe(failure);
    } finally {
      _end();
    }
  }

  Future<void> disconnect() async {
    if (!_begin()) return;
    _notify();
    try {
      if (usingS3) {
        await cloudSources?.saveS3Sync(null);
      } else {
        await documents.disconnect();
        connection = null;
      }
      status = null;
      error = null;
    } catch (failure) {
      error = _describe(failure);
    } finally {
      _end();
    }
  }

  Future<void> _merge(BookSyncBundle bundle) async {
    final backup = await LibraryBackup.parse(bundle.backup);
    final localStore = books ?? state.localLibrary;
    final importedNovels = <Novel>[];
    if (syncOriginals && localStore != null && bundle.books.isNotEmpty) {
      final tempDir = await Directory.systemTemp.createTemp('wenku8_sync_in_');
      try {
        for (final (i, input) in bundle.books.indexed) {
          final tempFile = File('${tempDir.path}/sync_$i');
          await tempFile.writeAsBytes(input.bytes, flush: true);
          final novel = await localStore.importCloudFile(
            input.name,
            tempFile.path,
            decodedText: input.text,
          );
          importedNovels.add(novel);
        }
      } finally {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    }
    if (syncReading) {
      await state.restoreBackup(backup, importTags: syncCategories);
    } else {
      if (importedNovels.isNotEmpty) {
        await state.addShelfBooks(importedNovels);
      }
      if (syncCategories) {
        await state.restoreBackupTagsOnly(backup);
      }
    }
  }

  Future<void> sync() async {
    if (!connected || !_begin()) return;
    status = '正在读取云端';
    _notify();
    BookDocuments? adapter;
    try {
      adapter = await _adapter();
      final selectedConnection = adapter is S3BookDocuments
          ? await adapter.info()
          : connection!;
      final files = await adapter.read();
      final size = await files.before.length();
      BookSyncBundle? remote;
      if (size > 0) {
        final incoming = await compute<Uint8List, BookSyncBundle>(
          decodeBookSync,
          await files.before.readAsBytes(),
        );
        remote = incoming;
        await _merge(incoming);
      } else if (selectedConnection['created'] != true) {
        throw const FormatException('所选文件为空，请新建文库同步文件');
      }
      status = '正在合并书籍与阅读记录';
      _notify();
      final backup = await state.createSyncBackup(
        syncReading: syncReading,
        syncCategories: syncCategories,
        remote: remote != null ? await LibraryBackup.parse(remote.backup) : null,
      );
      final encodedBackup = await backup.encode();
      final originals = <LocalBookInput>[];
      var total =
          utf8.encode(encodedBackup).length +
          (remote?.organization == null
              ? 0
              : utf8.encode(jsonEncode(remote!.organization)).length) +
          (remote?.bookMetadata == null
              ? 0
              : utf8.encode(jsonEncode(remote!.bookMetadata)).length) +
          (remote?.series == null
              ? 0
              : utf8.encode(jsonEncode(remote!.series)).length) +
          64 * 1024;
      if (!syncOriginals) originals.addAll(remote?.books ?? const []);
      final localStore = books ?? state.localLibrary;
      if (syncOriginals && localStore != null) {
        for (final book in localStore.books) {
          final exported = await localStore.exportSyncOriginal(book.id);
          if (exported == null) continue;
          final textBytes = exported.text == null
              ? 0
              : utf8.encode(exported.text!).length;
          total += exported.bytes.length + textBytes;
          if (originals.length >= 200 || total > 512 * 1024 * 1024) {
            throw const FormatException('一次最多同步 200 本、512 MB 原书，请整理本地书库');
          }
          originals.add(
            LocalBookInput(
              exported.name,
              exported.bytes,
              text: exported.text,
            ),
          );
        }
      }
      final bytes = await compute(
        encodeBookSync,
        BookSyncBundle(
          encodedBackup,
          originals,
          organization: remote?.organization,
          bookMetadata: remote?.bookMetadata,
          series: remote?.series,
        ),
      );
      await files.output.writeAsBytes(bytes, flush: true);
      status = '正在写入并确认云端';
      _notify();
      await adapter.write(files.before, files.output);
      await preferences.setInt(
        adapter is S3BookDocuments ? 'bookSyncS3At' : 'bookSyncAt',
        DateTime.now().millisecondsSinceEpoch,
      );
      if (adapter is S3BookDocuments) {
        await preferences.setString('bookSyncS3Target', adapter.identity);
      } else {
        connection = {...connection!, 'created': false};
      }
      final localCount = localStore?.books.length ?? 0;
      status = '同步完成 · $localCount 本本地书籍';
    } catch (failure) {
      error = _describe(failure);
      status = null;
    } finally {
      if (adapter is S3BookDocuments) adapter.close();
      _end();
    }
  }

  Future<void> recover(String which) async {
    if (!_begin()) return;
    status = '正在恢复同步副本';
    _notify();
    BookDocuments? adapter;
    try {
      adapter = await _adapter();
      final file = await adapter.recovery(which);
      if (file == null || await file.length() == 0) {
        throw const FormatException('暂无可恢复的同步副本');
      }
      await _merge(await compute(decodeBookSync, await file.readAsBytes()));
      status = '已合并恢复副本到本机，再次同步会先读取云端最新内容';
    } catch (failure) {
      error = _describe(failure);
      status = null;
    } finally {
      if (adapter is S3BookDocuments) adapter.close();
      _end();
    }
  }

  static String _describe(Object error) => error is FormatException
      ? error.message
      : error is CloudSourceFailure
      ? error.message
      : error is PlatformException
      ? error.message ?? '云文档操作失败，请重新选择文件'
      : '同步未完成，本地书籍与阅读记录已保留，请重试';

  @override
  void dispose() {
    _disposed = true;
    cloudSources?.removeListener(_notify);
    super.dispose();
  }
}

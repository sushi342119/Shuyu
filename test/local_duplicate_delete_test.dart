import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/local_duplicates.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/local_platform.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late LocalLibraryStore store;
  late PathProviderPlatform previousPaths;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    root = await Directory.systemTemp.createTemp('shuyu-duplicates-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    await TagStore.load();
    store = await LocalLibraryStore.load();
    final folder = Directory(await store.appFolderPath);
    await folder.create(recursive: true);
    for (final name in ['原本.txt', '副本.txt', '另一份.txt']) {
      await File('${folder.path}/$name').writeAsString('第一章 起点\n相同的小说正文。\n');
    }
    await store.scanAppFolder();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    store.dispose();
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  test(
    'deletes two copies, retains one source and keeps index correct after reload/scan',
    () async {
      final group = findLocalDuplicates(store.books).content.single;
      final keeper = group.books.first;
      for (final copy in group.books.skip(1)) {
        await store.deleteDuplicateBookFile(copy, keeper: keeper);
        expect(await File.fromUri(Uri.parse(copy.fileUri)).exists(), isFalse);
      }
      expect(store.books.map((b) => b.id), [keeper.id]);
      expect(await File.fromUri(Uri.parse(keeper.fileUri)).exists(), isTrue);
      final pending = await store.peekAssociatedCleanupIds();
      expect(pending, hasLength(2));
      store.dispose();
      store = await LocalLibraryStore.load();
      await store.scanAppFolder();
      expect(store.books.map((b) => b.id), [keeper.id]);
    },
  );

  test(
    'never allows the selected book to serve as its own retained copy',
    () async {
      final book = store.books.first;
      await expectLater(
        store.deleteDuplicateBookFile(book, keeper: book),
        throwsStateError,
      );
      expect(store.books, hasLength(3));
    },
  );

  test('rejects snapshots after rescan and keeps all source files', () async {
    final copy = store.books.first;
    final keeper = store.books.last;
    await File.fromUri(Uri.parse(copy.fileUri)).writeAsString('不同的内容。');
    await store.scanAppFolder(force: true);
    await expectLater(
      store.deleteDuplicateBookFile(copy, keeper: keeper),
      throwsStateError,
    );
    expect(store.books, hasLength(3));
    expect(await File.fromUri(Uri.parse(copy.fileUri)).exists(), isTrue);
  });

  test(
    'detects external source edits even with same size and restored modified time',
    () async {
      final copy = store.books.first;
      final keeper = store.books.last;
      final file = File.fromUri(Uri.parse(copy.fileUri));
      final stat = await file.stat();
      await file.writeAsString('第一章 起点\n改动的小说正文。\n');
      await file.setLastModified(stat.modified);
      await expectLater(
        store.deleteDuplicateBookFile(copy, keeper: keeper),
        throwsStateError,
      );
      expect(await file.exists(), isTrue);
      expect(store.books, hasLength(3));
    },
  );

  test(
    'refuses deletion when keeper is gone or changed outside the app',
    () async {
      final copy = store.books.first;
      final keeper = store.books.last;
      final retainedFile = File.fromUri(Uri.parse(keeper.fileUri));
      await retainedFile.writeAsString('已替换的其他小说');
      await expectLater(
        store.deleteDuplicateBookFile(copy, keeper: keeper),
        throwsStateError,
      );
      await retainedFile.delete();
      await expectLater(
        store.deleteDuplicateBookFile(copy, keeper: keeper),
        throwsA(anything),
      );
      expect(await File.fromUri(Uri.parse(copy.fileUri)).exists(), isTrue);
      expect(store.books, hasLength(3));
    },
  );

  test(
    'aliases pointing at one file never delete the retained source',
    () async {
      final books = store.books;
      final copy = books.first;
      final keeper = books.last;
      final alias = keeper.copyWith(
        fileUri: copy.fileUri,
        sourceKey: copy.sourceKey,
      );
      store.dispose();
      final index = File('${root.path}/local_books/index.json');
      await index.writeAsString(
        jsonEncode({
          'books': [copy.toJson(), alias.toJson()],
        }),
      );
      store = await LocalLibraryStore.load();
      await expectLater(
        store.deleteDuplicateBookFile(
          store.books.first,
          keeper: store.books.last,
        ),
        throwsStateError,
      );
      expect(await File.fromUri(Uri.parse(copy.fileUri)).exists(), isTrue);
    },
  );
  test('SAF provider rejection preserves the book record for retry', () async {
    final originals = store.books;
    final documents = [
      for (var i = 0; i < 2; i++)
        originals[i].copyWith(
          fileUri: 'content://provider/tree/root/document/book$i',
          sourceKey: 'content://provider/tree/root/document/book$i',
          sourceId: 'saf:content://provider/tree/root',
        ),
    ];
    store.dispose();
    await File('${root.path}/local_books/index.json').writeAsString(
      jsonEncode({'books': documents.map((b) => b.toJson()).toList()}),
    );
    var deleteCalls = 0;
    messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      if (call.method == 'fingerprintLocalText') {
        return documents.first.sourceFingerprint;
      }
      if (call.method == 'deleteLocalDocument') {
        deleteCalls++;
        return {'deleted': false, 'code': 'permission'};
      }
      throw MissingPluginException(call.method);
    });
    store = await LocalLibraryStore.load();
    await expectLater(
      store.deleteDuplicateBookFile(
        store.books.first,
        keeper: store.books.last,
      ),
      throwsA(isA<LocalDeleteException>()),
    );
    expect(deleteCalls, 1);
    expect(store.books, hasLength(2));
    expect(await store.peekAssociatedCleanupIds(), isEmpty);
  });

  test(
    'SAF aliases through different tree URIs still protect one document',
    () async {
      final originals = store.books;
      final documents = [
        for (var i = 0; i < 2; i++)
          originals[i].copyWith(
            fileUri: 'content://provider/tree/root$i/document/shared%2Fbook',
            sourceKey: 'content://provider/tree/root$i/document/shared%2Fbook',
            sourceId: 'saf:content://provider/tree/root$i',
          ),
      ];
      store.dispose();
      await File('${root.path}/local_books/index.json').writeAsString(
        jsonEncode({'books': documents.map((b) => b.toJson()).toList()}),
      );
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
        fail('Shared document must not be read or deleted: ${call.method}');
      });
      store = await LocalLibraryStore.load();
      await expectLater(
        store.deleteDuplicateBookFile(
          store.books.first,
          keeper: store.books.last,
        ),
        throwsStateError,
      );
      expect(store.books, hasLength(2));
    },
  );
}

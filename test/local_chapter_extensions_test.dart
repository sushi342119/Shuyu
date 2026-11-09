import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/chapter_splitter.dart' show splitLocalChapters;
import 'package:shuyu/library_state.dart';
import 'package:shuyu/listening/models.dart';
import 'package:shuyu/listening/store.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/reader_underline.dart';

const _text =
    '无标题开场😀\n第一章 开始\n甲正文。\n\n简介\n独立目标😀段落。\n\n随后还有第二段。\n第二章 结束\n末尾正文。';

Uint8List _mobiBytes(String magic) {
  final text = utf8.encode(_text);
  const headerOffset = 78 + 2 * 8;
  const textOffset = headerOffset + 16;
  final bytes = Uint8List(textOffset + text.length);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(60, 68, ascii.encode(magic));
  data.setUint16(76, 2);
  data.setUint32(78, headerOffset);
  data.setUint32(86, textOffset);
  data.setUint16(headerOffset, 1);
  data.setUint32(headerOffset + 4, text.length);
  data.setUint16(headerOffset + 8, 1);
  data.setUint16(headerOffset + 10, 4096);
  bytes.setRange(textOffset, bytes.length, text);
  return bytes;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  final previousPaths = PathProviderPlatform.instance;
  final stores = <LocalLibraryStore>[];
  final states = <LibraryState>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chapter-extensions-');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
  });
  tearDown(() async {
    for (final state in states) {
      state.dispose();
    }
    for (final store in stores) {
      store.dispose();
    }
    states.clear();
    stores.clear();
    messenger.setMockMethodCallHandler(paths, null);
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  Future<LocalLibraryStore> load(bool enabled) async {
    final store = await LocalLibraryStore.load(
      enableChapterExtensions: enabled,
    );
    stores.add(store);
    return store;
  }

  Future<LibraryState> bind(LocalLibraryStore store) async {
    final state = await LibraryState.load();
    states.add(state);
    state.bindLocalChapters(store);
    return state;
  }

  for (final enabled in [false, true]) {
    for (final magic in ['BOOKMOBI', 'TEXtREAd']) {
      for (final fileName in ['book.epub', 'book.mobi']) {
        test(
          'MOBI $magic import as $fileName stays ready with extensions=$enabled',
          () async {
            var store = await load(enabled);
            await store.directory.create(recursive: true);
            final bytes = _mobiBytes(magic);
            await File(
              '${await store.appFolderPath}/$fileName',
            ).writeAsBytes(bytes);
            final scan = await store.scanAppFolder();
            expect(scan.added, 1, reason: scan.failures.toString());
            expect(scan.failures, isEmpty);
            final book = store.books.single;
            expect(book.kind, LocalBookKind.txt);
            expect(book.fileName, fileName);
            expect(book.chapterSplitVersion, 5);
            expect(
              book.chapterSplitVersion,
              store.chapterSplitVersionForTest(book),
            );
            expect(book.isMobiSource, fileName == 'book.epub');
            expect(
              book.copyWith(title: 'renamed').isMobiSource,
              book.isMobiSource,
            );
            expect(
              book.chapters.map((chapter) => chapter.toJson()),
              extractMobiBook(
                bytes,
              ).chapters.map((chapter) => chapter.toJson()),
            );
            final migrations = <LocalChapterRemap>[];
            store.migrateProgress = (task) async => migrations.add(task);
            await store.ensureReady(book.id);
            expect(store.books.single, same(book));
            expect(store.pendingChapterRemaps, isEmpty);
            expect(migrations, isEmpty);
            for (final nextEnabled in [enabled, !enabled]) {
              store.dispose();
              store = await load(nextEnabled);
              store.migrateProgress = (task) async => migrations.add(task);
              final restored = store.books.single;
              expect(restored.toJson(), book.toJson());
              expect(
                restored.chapterSplitVersion,
                store.chapterSplitVersionForTest(restored),
              );
              await store.ensureReady(book.id);
              expect(store.books.single, same(restored));
              expect(store.pendingChapterRemaps, isEmpty);
              expect(migrations, isEmpty);
              expect((await store.scanAppFolder()).refreshed, 0);
            }
          },
        );
      }
    }

    for (final fileName in ['book.epub', 'book.txt']) {
      test(
        'TXT import as $fileName stays ready with extensions=$enabled',
        () async {
          var store = await load(enabled);
          await File(
            '${await store.appFolderPath}/$fileName',
          ).writeAsString(_text);
          final scan = await store.scanAppFolder();
          expect(scan.added, 1);
          expect(scan.failures, isEmpty);
          final book = store.books.single;
          expect(book.kind, LocalBookKind.txt);
          expect(book.fileName, fileName);
          expect(book.isMobiSource, isFalse);
          expect(book.chapterSplitVersion, enabled ? 6 : 5);
          expect(
            book.chapterSplitVersion,
            store.chapterSplitVersionForTest(book),
          );
          expect(
            book.chapters.map((chapter) => chapter.toJson()),
            splitLocalChapters(
              _text,
              enableChapterExtensions: enabled,
            ).map((chapter) => chapter.toJson()),
          );
          final migrations = <LocalChapterRemap>[];
          store.migrateProgress = (task) async => migrations.add(task);
          await store.ensureReady(book.id);
          expect(store.books.single, same(book));
          expect(store.pendingChapterRemaps, isEmpty);
          expect(migrations, isEmpty);
          store.dispose();
          store = await load(enabled);
          store.migrateProgress = (task) async => migrations.add(task);
          final restored = store.books.single;
          expect(restored.toJson(), book.toJson());
          expect(
            restored.chapterSplitVersion,
            store.chapterSplitVersionForTest(restored),
          );
          await store.ensureReady(book.id);
          expect(store.books.single, same(restored));
          expect(store.pendingChapterRemaps, isEmpty);
          expect(migrations, isEmpty);
          expect((await store.scanAppFolder()).refreshed, 0);
        },
      );
    }

    for (final storedVersion in [3, 4, 5, 6]) {
      test(
        'stored v$storedVersion converges once with extensions=$enabled',
        () async {
          var store = await load(storedVersion == 4 || storedVersion == 6);
          await File(
            '${await store.appFolderPath}/book.txt',
          ).writeAsString(_text);
          expect((await store.scanAppFolder()).failures, isEmpty);
          final original = store.books.single.copyWith(
            chapterSplitVersion: storedVersion,
          );
          store.dispose();
          await File('${root.path}/local_books/index.json').writeAsString(
            jsonEncode({
              'books': [original.toJson()],
            }),
          );
          store = await load(enabled);
          final migrations = <LocalChapterRemap>[];
          store.migrateProgress = (task) async => migrations.add(task);
          await store.ensureReady(original.id);
          final targetVersion = enabled ? 6 : 5;
          final updated = store.books.single;
          expect(updated.chapterSplitVersion, targetVersion);
          expect(
            updated.chapters.map((chapter) => chapter.toJson()),
            splitLocalChapters(
              _text,
              enableChapterExtensions: enabled,
            ).map((chapter) => chapter.toJson()),
          );
          expect(migrations, hasLength(storedVersion == targetVersion ? 0 : 1));
          expect(store.pendingChapterRemaps, isEmpty);
          await store.ensureReady(original.id);
          expect(store.books.single, same(updated));
          expect((await store.scanAppFolder()).refreshed, 0);
          store.dispose();
          store = await load(enabled);
          store.migrateProgress = (task) async => migrations.add(task);
          await store.ensureReady(original.id);
          expect(store.books.single.revision, updated.revision);
          expect(migrations, hasLength(storedVersion == targetVersion ? 0 : 1));
        },
      );
    }

    test(
      'custom TXT resplit keeps policy version with extensions=$enabled',
      () async {
        final store = await load(enabled);
        await File(
          '${await store.appFolderPath}/book.txt',
        ).writeAsString(_text);
        expect((await store.scanAppFolder()).failures, isEmpty);
        final book = store.books.single;
        final novel = await store.resplitTxtChapters(book.id);
        expect(novel, isNotNull);
        final updated = store.books.single;
        expect(updated.chapterSplitVersion, enabled ? 6 : 5);
        expect(updated.revision, book.revision);
        await store.ensureReady(book.id);
        expect(store.books.single, same(updated));
        expect(store.pendingChapterRemaps, isEmpty);
      },
    );
  }

  test(
    'repeated policy changes rebuild indexes and migrate every reading consumer',
    () async {
      var store = await load(false);
      final source = await File(
        '${await store.appFolderPath}/book.txt',
      ).writeAsString(_text);
      expect((await store.scanAppFolder()).failures, isEmpty);
      final legacy = store.books.single;
      expect(legacy.chapterSplitVersion, 5);
      var state = await bind(store);
      var chapters = await store.chapters(legacy.id);
      final novel = store.toNovel(legacy).withChapters(chapters);
      final body = await store.chapterContent(legacy.id, chapters[1]);
      await state.savePosition(
        novel: novel,
        chapter: 1,
        offset: 0,
        maximum: 100,
        width: 400,
        paragraphIndex: 1,
        textOffset: body.indexOf('目标'),
      );
      final note = await state.saveAnnotation(
        novel: novel,
        position: state.positionFor(legacy.id)!,
        ranges: [
          ReaderUnderlineRange(
            chapterId: 1,
            startParagraph: 1,
            startOffset: 5,
            endParagraph: 1,
            endOffset: 9,
            contentRevision: legacy.revision,
          ),
        ],
        quote: '目标😀',
        note: '不可丢失的批注',
        style: ReaderMarkStyle.highlight,
        color: ReaderMarkColor.amber,
      );
      await state.categorizeBookmark(legacy.id, note.id, '重要');
      final originalMark = state.bookmarksFor(legacy.id).single;
      final prefs = await SharedPreferences.getInstance();
      await ListeningStore(prefs).saveCursor(
        ListeningCursor(
          novelId: legacy.id,
          chapterId: 1,
          chapter: 1,
          paragraph: 1,
          start: 5,
          positionMs: 700,
          segmentHash: 'before',
          revision: legacy.revision,
          textOffset: body.indexOf('目标'),
        ),
      );
      final migrations = <String>{};
      var positionTarget = '目标';
      for (final enabled in [true, false, true]) {
        state.dispose();
        states.remove(state);
        store.dispose();
        store = await load(enabled);
        state = await bind(store);
        expect(store.acceptsChapter(legacy.id, chapters[1]), isFalse);
        await expectLater(
          store.chapterContent(legacy.id, chapters[1]),
          throwsA(isA<StaleLocalChapterException>()),
        );
        final scan = await store.scanAppFolder();
        expect(scan.failures, isEmpty);
        expect(scan.chapterRemaps, hasLength(1));
        final task = scan.chapterRemaps.single;
        expect(migrations.add(task.migrationId), isTrue);
        expect(task.oldTextPath, task.newTextPath);
        chapters = await store.chapters(legacy.id);
        final book = store.books.single;
        final targetChapter = enabled ? 2 : 1;
        expect(book.chapterSplitVersion, enabled ? 6 : 5);
        expect(book.textFingerprint, legacy.textFingerprint);
        expect(
          book.chapters.map((chapter) => chapter.title),
          enabled
              ? ['前言', '第一章 开始', '简介', '第二章 结束']
              : ['前言', '第一章 开始', '第二章 结束'],
        );
        expect(await File(store.textPathFor(book)).readAsString(), _text);
        expect(await source.readAsString(), _text);
        final position = state.positionFor(book.id)!;
        final migratedBody = await store.chapterContent(
          book.id,
          chapters[targetChapter],
        );
        expect(position.chapter, targetChapter);
        expect(position.revision, book.revision);
        expect(
          migratedBody.substring(position.textOffset!),
          startsWith(positionTarget),
        );
        final mark = state.bookmarksFor(book.id).single;
        expect(mark.id, originalMark.id);
        expect(mark.quote, originalMark.quote);
        expect(mark.annotation, originalMark.annotation);
        expect(mark.category, originalMark.category);
        expect(mark.categoryAt, originalMark.categoryAt);
        expect(mark.createdAt, originalMark.createdAt);
        expect(mark.rangeUpdatedAt, originalMark.rangeUpdatedAt);
        expect(mark.position.chapter, targetChapter);
        expect(mark.underlineRanges.single.chapterId, targetChapter);
        expect(mark.underlineRanges.single.contentRevision, book.revision);
        expect(mark.underlineRanges.single.startOffset, enabled ? 2 : 5);
        final cursor = ListeningStore(prefs).cursor(book.id)!;
        expect(cursor.chapter, targetChapter);
        expect(cursor.revision, book.revision);
        expect(migratedBody.substring(cursor.textOffset!), startsWith('目标'));
        expect(cursor.positionMs, 0);
        expect(store.pendingChapterRemaps, isEmpty);
        expect((await store.scanAppFolder()).refreshed, 0);
        if (!enabled) {
          expect(book.revision, legacy.revision);
          positionTarget = '第二段';
          await state.savePosition(
            novel: store.toNovel(book).withChapters(chapters),
            chapter: targetChapter,
            offset: 0,
            maximum: 100,
            width: 400,
            paragraphIndex: 2,
            textOffset: migratedBody.indexOf(positionTarget),
          );
        }
      }
      expect(migrations, hasLength(3));
    },
  );

  test(
    'failed rollback migration remains durable and retries after restart',
    () async {
      var store = await load(true);
      await File('${await store.appFolderPath}/book.txt').writeAsString(_text);
      await store.scanAppFolder();
      final book = store.books.single;
      store.dispose();
      store = await load(false);
      store.migrateProgress = (_) async => throw StateError('migration failed');
      await expectLater(store.ensureReady(book.id), throwsStateError);
      final task = store.pendingChapterRemaps.single;
      expect(store.books.single.chapterSplitVersion, 5);
      store.dispose();
      store = await load(false);
      expect(store.pendingChapterRemaps.single.migrationId, task.migrationId);
      await bind(store);
      await store.ensureReady(book.id);
      expect(store.pendingChapterRemaps, isEmpty);
      expect(store.books.single.chapterSplitVersion, 5);
    },
  );

  test(
    'turning off before the upgrade migrates drains both journal steps',
    () async {
      var store = await load(false);
      await File('${await store.appFolderPath}/book.txt').writeAsString(_text);
      await store.scanAppFolder();
      final original = store.books.single;
      store.dispose();
      store = await load(true);
      await expectLater(store.ensureReady(original.id), throwsStateError);
      expect(store.pendingChapterRemaps, hasLength(1));
      store.dispose();
      store = await load(false);
      final visited = <String>[];
      final state = await bind(store);
      store.migrateProgress = (task) async {
        visited.add(task.migrationId);
        await state.migrateLocalChapterTask(task);
      };
      await store.ensureReady(original.id);
      expect(visited, hasLength(2));
      expect(store.books.single.revision, original.revision);
      expect(store.pendingChapterRemaps, isEmpty);
    },
  );

  test(
    'missing snapshot plus changed source never restores a stale chapter table',
    () async {
      var store = await load(true);
      final source = await File(
        '${await store.appFolderPath}/book.txt',
      ).writeAsString(_text);
      await store.scanAppFolder();
      final original = store.books.single;
      await File(store.textPathFor(original)).delete();
      await source.writeAsString(_text.replaceAll('目标', '改变'));
      store.dispose();
      store = await load(false);
      await expectLater(store.ensureReady(original.id), throwsStateError);
      expect(store.books.single.revision, original.revision);
      expect(store.books.single.chapterSplitVersion, 6);
      expect(store.pendingChapterRemaps, isEmpty);
      await bind(store);
      final scan = await store.scanAppFolder();
      expect(scan.failures, isEmpty);
      await store.ensureReady(original.id);
      expect(store.books.single.chapterSplitVersion, 5);
      expect(
        store.books.single.textFingerprint,
        isNot(original.textFingerprint),
      );
    },
  );

  test(
    'unavailable source retries policy changes after the source returns',
    () async {
      for (final enabled in [true, false]) {
        var store = await load(!enabled);
        final source = await File(
          '${await store.appFolderPath}/book.txt',
        ).writeAsString(_text);
        await store.scanAppFolder();
        final original = store.books.single;
        await File(store.textPathFor(original)).delete();
        await source.delete();
        store.dispose();
        store = await load(enabled);
        await store.ensureReady(original.id);
        expect(store.books.single.revision, original.revision);
        expect(store.books.single.chapterSplitVersion, enabled ? 5 : 6);
        expect(store.pendingChapterRemaps, isEmpty);
        store.dispose();
        store = await load(enabled);
        await store.ensureReady(original.id);
        expect(store.books.single.revision, original.revision);
        expect(store.books.single.chapterSplitVersion, enabled ? 5 : 6);
        await source.writeAsString(_text);
        final state = await bind(store);
        final visited = <LocalChapterRemap>[];
        store.migrateProgress = (task) async {
          visited.add(task);
          await state.migrateLocalChapterTask(task);
        };
        await store.ensureReady(original.id);
        expect(store.books.single.chapterSplitVersion, enabled ? 6 : 5);
        expect(visited, hasLength(1));
        expect(store.pendingChapterRemaps, isEmpty);
        store.dispose();
      }
    },
  );

  test(
    'rebuild output failures do not count as an unavailable source',
    () async {
      for (final missingSnapshot in [false, true]) {
        var store = await load(false);
        await File(
          '${await store.appFolderPath}/book.txt',
        ).writeAsString(_text);
        await store.scanAppFolder();
        final original = store.books.single;
        if (missingSnapshot) {
          await File(store.textPathFor(original)).delete();
        }
        final operation = missingSnapshot ? 'staging' : 'upgrading';
        final blockedOutput = await Directory(
          '${store.directory.path}/book_${original.id}.$operation.importing',
        ).create();
        store.dispose();
        store = await load(true);
        await expectLater(store.ensureReady(original.id), throwsStateError);
        expect(store.books.single.revision, original.revision);
        expect(store.books.single.chapterSplitVersion, 5);
        expect(store.pendingChapterRemaps, isEmpty);
        await blockedOutput.delete();
        store.dispose();
      }
    },
  );

  test('empty recovered source still rejects a policy change', () async {
    var store = await load(false);
    final source = await File(
      '${await store.appFolderPath}/book.txt',
    ).writeAsString(_text);
    await store.scanAppFolder();
    final original = store.books.single;
    await File(store.textPathFor(original)).delete();
    await source.writeAsString('');
    store.dispose();
    store = await load(true);
    await expectLater(store.ensureReady(original.id), throwsStateError);
    expect(store.books.single.revision, original.revision);
    expect(store.books.single.chapterSplitVersion, 5);
    expect(store.pendingChapterRemaps, isEmpty);
  });

  test(
    'unchanged source can recover a missing snapshot then rebuild v5',
    () async {
      var store = await load(true);
      await File('${await store.appFolderPath}/book.txt').writeAsString(_text);
      await store.scanAppFolder();
      final original = store.books.single;
      await File(store.textPathFor(original)).delete();
      store.dispose();
      store = await load(false);
      await bind(store);
      await store.ensureReady(original.id);
      final rebuilt = store.books.single;
      expect(rebuilt.chapterSplitVersion, 5);
      expect(rebuilt.textFingerprint, original.textFingerprint);
      expect(
        rebuilt.chapters.map((chapter) => chapter.toJson()),
        splitLocalChapters(
          _text,
          enableChapterExtensions: false,
        ).map((chapter) => chapter.toJson()),
      );
      expect(rebuilt.chapters.map((chapter) => chapter.title), [
        '前言',
        '第一章 开始',
        '第二章 结束',
      ]);
      expect(await File(store.textPathFor(rebuilt)).readAsString(), _text);
    },
  );

  test(
    'policy change alone invalidates a table even if chapter ranges do not change',
    () async {
      var store = await load(false);
      await File(
        '${await store.appFolderPath}/book.txt',
      ).writeAsString('第一章 开场\n独立正文。');
      await store.scanAppFolder();
      final original = store.books.single;
      store.dispose();
      store = await load(true);
      await bind(store);
      await store.ensureReady(original.id);
      final updated = store.books.single;
      expect(
        jsonEncode(
          updated.chapters.map((chapter) => chapter.toJson()).toList(),
        ),
        jsonEncode(
          original.chapters.map((chapter) => chapter.toJson()).toList(),
        ),
      );
      expect(updated.revision, isNot(original.revision));
      expect(updated.chapterSplitVersion, 6);
      expect(store.pendingChapterRemaps, isEmpty);
    },
  );

  test(
    'worker normalizes CRLF across reads without changing body characters',
    () async {
      final store = await load(true);
      final raw =
          '\uFEFF${'a' * 65532}\r\n扉页\r\n作者😀\r\n'
          '简介：远行😀\r\n　完整正文😀。\r\n第一章起点\r\n尾部正文。';
      final source = await File(
        '${await store.appFolderPath}/boundary.txt',
      ).writeAsString(raw);
      final bytes = await source.readAsBytes();
      expect((await store.scanAppFolder()).failures, isEmpty);
      final book = store.books.single;
      final normalized = raw.substring(1).replaceAll('\r\n', '\n');
      expect(await File(store.textPathFor(book)).readAsString(), normalized);
      expect(await source.readAsBytes(), bytes);
      expect(
        book.chapters.map((chapter) => chapter.toJson()),
        splitLocalChapters(normalized).map((chapter) => chapter.toJson()),
      );
      final chapters = await store.chapters(book.id);
      expect(chapters.map((chapter) => chapter.title), [
        '前言',
        '扉页',
        '简介：远行😀',
        '第一章起点',
      ]);
      expect(await store.chapterContent(book.id, chapters[2]), '完整正文😀。');
    },
  );

  test(
    'extended headings stay streamed through an over 48 MiB worker import',
    () async {
      final store = await load(true);
      final source = File('${await store.appFolderPath}/large.txt');
      final output = await source.open(mode: FileMode.write);
      final body = '${'甲😀乙。' * 2000}\n';
      try {
        for (var chapter = 0; chapter < 2300; chapter++) {
          final title = chapter % 100 == 0
              ? '简介：远行$chapter'
              : '第${chapter + 1}章 测试';
          await output.writeString('$title\n$body');
        }
      } finally {
        await output.close();
      }
      expect(await source.length(), greaterThan(48 * 1024 * 1024));
      expect((await store.scanAppFolder()).failures, isEmpty);
      final book = store.books.single;
      expect(book.chapters, hasLength(2300));
      final chapters = await store.chapters(book.id);
      for (final chapter in [0, 100, 2200, 2299]) {
        expect(
          await store.chapterContent(book.id, chapters[chapter]),
          body.trim(),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

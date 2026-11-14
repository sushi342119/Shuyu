import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_palette.dart';
import 'package:shuyu/backup_page.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/library_backup.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/offline_cache.dart';
import 'package:shuyu/offline_repository.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/reader_purification.dart';
import 'package:shuyu/reader_underline.dart';
import 'package:shuyu/reading_moments.dart';
import 'package:shuyu/recovery_archive.dart';

import 'support/offline_fixture.dart';

class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.root);

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

  late Directory tempDir;
  late PathProviderPlatform previousPaths;

  setUp(() async {
    previousPaths = PathProviderPlatform.instance;
    tempDir = await Directory.systemTemp.createTemp('shuyu-batch1-test-');
    PathProviderPlatform.instance = _TempPaths(tempDir.path);
    SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
    TagStore.resetForTesting();
    LibraryFilter.shared.resetForTesting();
    await TagStore.load();
    ReaderPurificationStore.shared.resetForTesting();
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPaths;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'offlineRepositoryOf and offlineRepositoryForBook unwrap CompositeNovelRepository only for online books',
    () async {
      final cache = OfflineCacheStore(Directory('${tempDir.path}/offline'));
      final remote = OfflineFixtureRepository();
      final offline = OfflineNovelRepository(remote: remote, cache: cache);
      final local = await LocalLibraryStore.load();
      addTearDown(() {
        offline.dispose();
        local.dispose();
      });
      final composite = CompositeNovelRepository(local: local, remote: offline);

      expect(offlineRepositoryOf(composite), same(offline));
      expect(offlineRepositoryForBook(composite, 71), same(offline));
      expect(offlineRepositoryForBook(composite, 0), isNull);
      expect(offlineRepositoryForBook(composite, -5), isNull);
      expect(offlineRepositoryForBook(composite, localNovelIdBase), isNull);
      expect(offlineRepositoryForBook(composite, localNovelIdBase + 42), isNull);
    },
  );

  test(
    'downloadable and custom fonts round-trip through ReadingPosition, savePosition, createBackup, and restoreBackup',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final novel = offlineFixtureBook(71);

      final parsed = ReadingPosition.fromJson({
        'chapter': 1,
        'chapterId': novel.chapters[1].id,
        'offset': 120.0,
        'fraction': 0.25,
        'fontSize': 20.0,
        'width': 390.0,
        'updatedAt': 1000,
        'typeface': 'lxgwWenKai',
      });
      expect(parsed.typeface, 'lxgwWenKai');

      final customParsed = ReadingPosition.fromJson({
        'chapter': 0,
        'chapterId': novel.chapters[0].id,
        'offset': 0.0,
        'fraction': 0.0,
        'fontSize': 19.0,
        'width': 390.0,
        'updatedAt': 1000,
        'typeface': 'font_custom-serif',
      });
      expect(customParsed.typeface, 'font_custom-serif');

      await state.savePosition(
        novel: novel,
        chapter: 1,
        offset: 400,
        maximum: 1600,
        width: 390,
        typeface: 'lxgwWenKai',
      );
      await state.addBookmark(novel: novel, position: state.positionFor(71)!);

      final backup = await state.createBackup();
      final encoded = await backup.encode();
      final decoded = await LibraryBackup.parse(encoded);

      SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
      await TagStore.load();
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      await restored.restoreBackup(decoded, importPreferences: true);

      expect(restored.positionFor(71)?.typeface, 'lxgwWenKai');
      expect(
        restored.bookmarksFor(71).single.position.typeface,
        'lxgwWenKai',
      );
    },
  );

  test(
    'allowedLibraryPreferenceKeys in LocalTools.kt covers all backup preference/purification/stats keys and journal recovery succeeds',
    () async {
      final kotlin = File(
        'android/app/src/main/kotlin/app/shuyu/reader/LocalTools.kt',
      ).readAsStringSync();
      final allKeys = {
        ...backupPreferenceKeys,
        ...backupPurificationKeys,
        ...backupReadingStatsKeys,
      };
      for (final key in allKeys) {
        expect(
          kotlin.contains('"$key"'),
          isTrue,
          reason: 'Missing $key in LocalTools.kt',
        );
      }

      SharedPreferences.setMockInitialValues({
        'readerTypeface': 'lxgwWenKai',
        AppPalettePreferences.key: jsonEncode(
          const AppPalettePreferences().toJson(),
        ),
        'localTxtEncoding': 'gb18030',
        restoreJournalKey: jsonEncode({
          'readerTypeface': 'follow',
          AppPalettePreferences.key: null,
          'localTxtEncoding': 'auto',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final ok = await recoverLibraryRestore(prefs);
      expect(ok, isTrue);
      expect(prefs.get(restoreJournalKey), isNull);
      expect(prefs.getString('readerTypeface'), 'follow');
      expect(prefs.getString('localTxtEncoding'), 'auto');
      expect(prefs.get(AppPalettePreferences.key), isNull);

      for (var i = 0; i < 25; i++) {
        await archiveRecoveryRecord(
          prefs,
          'bounded_test_archive_v1',
          '${'x' * (8 * 1024)}_$i',
          reason: 'unit_test',
        );
      }
      final archived = prefs.getStringList('bounded_test_archive_v1')!;
      expect(archived.length, lessThanOrEqualTo(maxRecoveryArchiveEntries));

      await archiveRecoveryRecord(
        prefs,
        'huge_raw_archive_v1',
        '汉' * (maxRecoveryRawChars + 500),
        reason: 'oversized_payload',
      );
      final hugeEntry =
          jsonDecode(prefs.getStringList('huge_raw_archive_v1')!.single)
              as Map<String, dynamic>;
      expect(hugeEntry['truncated'], isTrue);
      expect(
        (hugeEntry['raw'] as String).length,
        lessThanOrEqualTo(maxRecoveryRawChars),
      );
    },
  );

  test(
    'LibraryBackupOptions selectively packs and restores preferences, purification rules/edits, and reading stats',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);

      await state.setTheme(ThemeMode.dark);
      await ReaderPurificationStore.shared.addCustomRule(
        name: '去水印',
        pattern: '水印广告',
        replacement: '',
        isRegex: false,
      );
      await ReaderPurificationStore.shared.setParagraphEdit(
        bookId: 71,
        chapterIndex: 0,
        paragraphIndex: 2,
        editedText: '纠错后的正文段落',
      );
      await state.readingActivity.recordInterval(
        bookId: 71,
        startedAt: DateTime.utc(2026, 10, 1, 10),
        elapsed: const Duration(minutes: 6),
      );
      await state.readingMoments.mergeRecord(
        jsonEncode({
          'version': 1,
          'activity': state.readingActivity.encode(),
          'moments': [
            ReadingMoment(
              id: 'first_day',
              kind: ReadingMomentKind.firstDay,
              earnedAt: DateTime.utc(2026, 10, 1, 12),
              value: 1,
            ).toJson(),
          ],
          'presented': ['first_day'],
          'preferences': const ReadingMomentsPreferences().toJson(),
        }),
      );

      final minimal = await state.createBackup(
        options: const LibraryBackupOptions(
          includePreferences: false,
          includePurification: false,
          includeReadingStats: false,
        ),
      );
      expect(minimal.hasPreferences, isFalse);
      expect(minimal.hasPurification, isFalse);
      expect(minimal.hasReadingStats, isFalse);

      final full = await state.createBackup(options: LibraryBackupOptions.all);
      expect(full.hasPreferences, isTrue);
      expect(full.hasPurification, isTrue);
      expect(full.hasReadingStats, isTrue);
      final fullDecoded = await LibraryBackup.parse(await full.encode());

      SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
      await TagStore.load();
      ReaderPurificationStore.shared.resetForTesting();
      final target = await LibraryState.load();
      addTearDown(target.dispose);

      await target.restoreBackup(
        fullDecoded,
        importPreferences: false,
        importPurification: true,
        importReadingStats: true,
      );

      expect(target.theme, ThemeMode.system);
      expect(
        ReaderPurificationStore.shared.rules.any((r) => r.name == '去水印'),
        isTrue,
      );
      expect(
        ReaderPurificationStore.shared.paragraphEditFor(71, 0, 2),
        '纠错后的正文段落',
      );
      expect(
        target.readingActivity.daysForBook(71).fold<int>(
          0,
          (sum, day) => sum + day.seconds,
        ),
        360,
      );
      expect(
        target.readingMoments.moments.any(
          (m) => m.kind == ReadingMomentKind.firstDay,
        ),
        isTrue,
      );
    },
  );

  test(
    'bookmark merge preserves multiple underlines in the same paragraph and merges newer notes/categories',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final novel = offlineFixtureBook(71);
      final cid = novel.chapters[0].id;

      ReadingPosition pos({int updated = 100, required int textOffset}) =>
          ReadingPosition(
            chapter: 0,
            chapterId: cid,
            offset: 120,
            fraction: 0.1,
            fontSize: 19,
            width: 390,
            updatedAt: updated,
            paragraphIndex: 2,
            textOffset: textOffset,
          );

      final firstUnderline = ReaderBookmark(
        id: 'u1',
        chapterTitle: '第 1 章',
        position: pos(updated: 100, textOffset: 0),
        quote: '第一处划线',
        underlineRanges: [
          ReaderUnderlineRange(
            chapterId: cid,
            startParagraph: 2,
            startOffset: 0,
            endParagraph: 2,
            endOffset: 5,
          ),
        ],
        annotation: const ReaderAnnotationData(
          note: '旧笔记',
          updatedAt: 100,
        ),
        createdAt: DateTime.utc(2026, 10, 1, 12),
      );
      final secondUnderlineSameParagraph = ReaderBookmark(
        id: 'u2',
        chapterTitle: '第 1 章',
        position: pos(updated: 110, textOffset: 10),
        quote: '第二处划线',
        underlineRanges: [
          ReaderUnderlineRange(
            chapterId: cid,
            startParagraph: 2,
            startOffset: 10,
            endParagraph: 2,
            endOffset: 15,
          ),
        ],
        annotation: const ReaderAnnotationData(
          note: '同段另一处',
          updatedAt: 110,
        ),
        createdAt: DateTime.utc(2026, 10, 1, 12, 1),
      );
      final updatedFirstUnderline = ReaderBookmark(
        id: 'u1',
        chapterTitle: '第 1 章',
        position: pos(updated: 200, textOffset: 0),
        quote: '第一处划线',
        category: '重点',
        categoryAt: 250,
        underlineRanges: [
          ReaderUnderlineRange(
            chapterId: cid,
            startParagraph: 2,
            startOffset: 0,
            endParagraph: 2,
            endOffset: 5,
          ),
        ],
        annotation: const ReaderAnnotationData(
          note: '跨设备更新后的新笔记',
          color: ReaderMarkColor.amber,
          updatedAt: 260,
        ),
        createdAt: DateTime.utc(2026, 10, 1, 12),
      );

      final seedBackup = await LibraryBackup.fromRecords({
        'novel_meta_71': jsonEncode(novel.toSnapshot()),
        'reader_bookmarks_71': jsonEncode([firstUnderline.toJson()]),
      });
      await state.restoreBackup(seedBackup);
      expect(state.bookmarksFor(71), hasLength(1));

      final incomingBackup = await LibraryBackup.fromRecords({
        'novel_meta_71': jsonEncode(novel.toSnapshot()),
        'reader_bookmarks_71': jsonEncode([
          updatedFirstUnderline.toJson(),
          secondUnderlineSameParagraph.toJson(),
        ]),
      });
      await state.restoreBackup(incomingBackup);

      final marks = state.bookmarksFor(71);
      expect(marks, hasLength(2));
      final mergedFirst = marks.singleWhere((m) => m.id == 'u1');
      expect(mergedFirst.note, '跨设备更新后的新笔记');
      expect(mergedFirst.category, '重点');
      expect(mergedFirst.annotation.color, ReaderMarkColor.amber);
      expect(marks.any((m) => m.quote == '第二处划线'), isTrue);
    },
  );

  testWidgets(
    'ShelfPage supports progress/chapters sorts and marks local TXT, PDF, and online books finished',
    (tester) async {
      late LocalLibraryStore local;
      late LibraryState state;
      const txtId = localNovelIdBase + 1;
      const pdfId = localNovelIdBase + 2;

      await tester.runAsync(() async {
        final booksDir = Directory('${tempDir.path}/local_books')
          ..createSync(recursive: true);
        const txtContent = '第一章 起始\n本地测试正文第一段。\n\n第二章 终章\n本地测试正文最后一段。\n';
        final txtBytes = utf8.encode(txtContent);
        final txtHash = sha256.convert(txtBytes).toString();
        File('${booksDir.path}/book_${txtId}_$txtHash.txt').writeAsBytesSync(
          txtBytes,
        );
        const ch1Offset = 0;
        final ch2CharStart = txtContent.indexOf('第二章');
        final ch1ByteLen =
            utf8.encode(txtContent.substring(0, ch2CharStart)).length;
        final ch2ByteLen = txtBytes.length - ch1ByteLen;
        final indexEntries = [
          LocalBook(
            id: txtId,
            title: '本地测试TXT',
            author: '本地作者',
            fileUri: '${booksDir.path}/origin.txt',
            fileName: '本地测试TXT.txt',
            kind: LocalBookKind.txt,
            size: txtBytes.length,
            modified: 1700000000000,
            pageCount: 0,
            chapterSplitVersion: 6,
            textFingerprint: txtHash,
            sourceFingerprint: txtHash,
            chapters: [
              LocalChapterIndex(
                '第一章 起始',
                ch1Offset,
                ch2CharStart,
                byteOffset: 0,
                byteLength: ch1ByteLen,
              ),
              LocalChapterIndex(
                '第二章 终章',
                ch2CharStart,
                txtContent.length - ch2CharStart,
                byteOffset: ch1ByteLen,
                byteLength: ch2ByteLen,
              ),
            ],
          ).toJson(),
          const LocalBook(
            id: pdfId,
            title: '本地测试PDF',
            author: 'PDF作者',
            fileUri: 'content://test/doc.pdf',
            fileName: '本地测试PDF.pdf',
            kind: LocalBookKind.pdf,
            size: 4096,
            modified: 1700000000000,
            chapters: [],
            pageCount: 12,
          ).toJson(),
        ];
        File('${booksDir.path}/index.json').writeAsStringSync(
          jsonEncode({'books': indexEntries}),
        );

        local = await LocalLibraryStore.load();
        state = await LibraryState.load();
        state.bindLocalChapters(local);

        await state.setShelfView(sort: 'progress');
        expect(state.shelfSort, 'progress');
        await state.setShelfView(sort: 'chapters');
        expect(state.shelfSort, 'chapters');
      });

      final remote = OfflineFixtureRepository();
      final repo = CompositeNovelRepository(local: local, remote: remote);
      final onlineBook = offlineFixtureBook(71);
      final txtNovel = local.toNovel(local.bookFor(txtId)!);
      final pdfNovel = local.toNovel(local.bookFor(pdfId)!);

      await tester.runAsync(() async {
        await state.toggleShelf(txtId, novel: txtNovel);
        await state.toggleShelf(pdfId, novel: pdfNovel);
        await state.toggleShelf(71, novel: onlineBook);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShelfPage(
              books: [onlineBook, txtNovel, pdfNovel],
              state: state,
              repository: repo,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('本地测试TXT').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地测试PDF').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线作品 71').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shelf-batch-finish')));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      expect(state.finishedReading(txtNovel), isTrue);
      expect(state.finishedReading(pdfNovel), isTrue);
      expect(state.finishedReading(onlineBook), isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      local.dispose();
    },
  );

  testWidgets(
    'ReaderPage initialBookmark lands on bookmarked chapter without clobbering newer reading progress on exit',
    (tester) async {
      final remote = OfflineFixtureRepository();
      late LocalLibraryStore local;
      late LibraryState state;
      await tester.runAsync(() async {
        local = await LocalLibraryStore.load();
        state = await LibraryState.load();
        state.bindLocalChapters(local);
      });
      final repo = CompositeNovelRepository(local: local, remote: remote);

      final novel = offlineFixtureBook(71, chapters: 3);
      await tester.runAsync(() async {
        await state.savePosition(
          novel: novel,
          chapter: 2,
          offset: 600,
          maximum: 1200,
          width: 390,
          paragraphIndex: 5,
        );
      });
      expect(state.positionFor(71)?.chapter, 2);

      final bookmark = ReaderBookmark(
        id: 'bm-ch0',
        chapterTitle: novel.chapters[0].title,
        position: ReadingPosition(
          chapter: 0,
          chapterId: novel.chapters[0].id,
          offset: 100,
          fraction: 0.1,
          fontSize: 19,
          width: 390,
          updatedAt: 50,
          paragraphIndex: 3,
        ),
        quote: '段落 3',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderPage(
                      novel: novel,
                      initialChapter: bookmark.position.chapter,
                      initialBookmark: bookmark,
                      state: state,
                      repository: repo,
                    ),
                  ),
                ),
                child: const Text('打开书签'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开书签'));
      await tester.pumpAndSettle();

      expect(find.text('第 1 章'), findsWidgets);
      expect(find.textContaining('正文 71-1', findRichText: true), findsWidgets);
      expect(find.byKey(const ValueKey('bookmark-landing-3')), findsOneWidget);
      expect(state.positionFor(71)?.chapter, 2);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(
        state.positionFor(71)?.chapter,
        2,
        reason:
            'Inspecting an earlier bookmark and exiting must not overwrite chapter 2 progress',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      local.dispose();
    },
  );

  testWidgets(
    'LibraryBackupPage renders selectable backup scope switches',
    (tester) async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);

      await tester.pumpWidget(MaterialApp(home: LibraryBackupPage(state: state)));
      await tester.pumpAndSettle();

      final prefSwitch = find.byKey(const ValueKey('backup-option-preferences'));
      final purSwitch = find.byKey(const ValueKey('backup-option-purification'));
      final statsSwitch = find.byKey(const ValueKey('backup-option-stats'));
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('backup-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(purSwitch, 120, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(prefSwitch, findsOneWidget);
      expect(purSwitch, findsOneWidget);
      expect(statsSwitch, findsOneWidget);

      await tester.tap(purSwitch);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

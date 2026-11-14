import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/chapter_splitter.dart'
    show
        splitLocalChapters,
        splitLocalChaptersCustom,
        subdivideOversizedChapters;
import 'package:shuyu/gbk_codec.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_annotation_remap.dart';
import 'package:shuyu/local_duplicates.dart';
import 'package:shuyu/local_epub.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/reader_content.dart';
import 'package:shuyu/reader_find.dart';
import 'package:shuyu/reader_paging.dart';
import 'package:shuyu/reader_purification.dart';
import 'package:shuyu/reader_underline.dart';

class _Batch2Paths extends PathProviderPlatform {
  _Batch2Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';

  @override
  Future<String?> getExternalStoragePath() async => root;
}

Uint8List _buildMobiWithEncoding({
  required Uint8List textBytes,
  required int textEncoding,
  int encryptionType = 0,
}) {
  // Minimal PDB (2 records) + PalmDOC (16 bytes) + MOBI header (232 bytes).
  const numRecords = 2;
  const headerOffset = 78 + numRecords * 8;
  const mobiHeaderLen = 232;
  const record0Len = 16 + mobiHeaderLen;
  const textOffset = headerOffset + record0Len;
  final bytes = Uint8List(textOffset + textBytes.length);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 8, ascii.encode('TestBook'));
  bytes.setRange(60, 68, ascii.encode('BOOKMOBI'));
  data.setUint16(76, numRecords);
  data.setUint32(78, headerOffset);
  data.setUint32(86, textOffset);
  // PalmDOC header at headerOffset
  data.setUint16(headerOffset, 1); // uncompressed
  data.setUint32(headerOffset + 4, textBytes.length);
  data.setUint16(headerOffset + 8, 1); // 1 text record
  data.setUint16(headerOffset + 10, 4096);
  data.setUint16(headerOffset + 12, encryptionType);
  // MOBI header at headerOffset + 16
  final mobiStart = headerOffset + 16;
  bytes.setRange(mobiStart, mobiStart + 4, ascii.encode('MOBI'));
  data.setUint32(mobiStart + 4, mobiHeaderLen);
  data.setUint32(mobiStart + 8, 2); // Mobi book type
  data.setUint32(mobiStart + 12, textEncoding);
  data.setUint32(mobiStart + 80, 0xFFFFFFFF); // firstNonBookIndex
  bytes.setRange(textOffset, bytes.length, textBytes);
  return bytes;
}

Uint8List _zipEntries(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.addFile(ArchiveFile(name, content.length, content));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
  const localChannel = MethodChannel('org.mewx.wenku8/local_tools');
  const controlsChannel = MethodChannel('org.mewx.wenku8/reader_controls');

  late Directory root;
  final previousPaths = PathProviderPlatform.instance;
  final stores = <LocalLibraryStore>[];
  final states = <LibraryState>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audit-batch2-');
    await Directory('${root.path}/cache').create(recursive: true);
    await Directory('${root.path}/tmp').create(recursive: true);
    PathProviderPlatform.instance = _Batch2Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(pathsChannel, (_) async => root.path);
    ReaderPurificationStore.shared.resetForTesting();
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
    messenger.setMockMethodCallHandler(pathsChannel, null);
    messenger.setMockMethodCallHandler(localChannel, null);
    messenger.setMockMethodCallHandler(controlsChannel, null);
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = previousPaths;
    ReaderPurificationStore.shared.resetForTesting();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<LocalLibraryStore> loadStore({bool extensions = true}) async {
    final store = await LocalLibraryStore.load(
      enableChapterExtensions: extensions,
    );
    stores.add(store);
    return store;
  }

  Future<LibraryState> bindState(LocalLibraryStore store) async {
    final state = await LibraryState.load();
    state.bindLocalChapters(store);
    states.add(state);
    return state;
  }

  group('P0-7 ReaderPurification coordinate projection & regex safety', () {
    test(
      'maps raw <-> purified offsets accurately across regex deletions and backslash rules',
      () async {
        final store = ReaderPurificationStore.shared;
        await store.ensureLoaded();
        await store.addCustomRule(
          name: '去广告与反斜杠',
          pattern: r'【广告】|\\',
          replacement: '',
          isRegex: true,
          applyToTitle: true,
        );
        const raw = r'前文【广告】目标高亮\后文';
        final purified = store.purifyParagraphWithMap(
          raw,
          paragraphIndex: 0,
          bookId: 100,
        );
        expect(purified.text, '前文目标高亮后文');

        // Raw highlight on '目标高亮' (raw indices 6..10) projects to purified 2..6.
        final rawStart = raw.indexOf('目标高亮');
        final rawEnd = rawStart + '目标高亮'.length;
        final mapped = store.mapAnnotationsToPurified(
          [
            ReaderAnnotationRange(
              ReaderUnderlineRange(
                chapterId: 0,
                startParagraph: 0,
                startOffset: rawStart,
                endParagraph: 0,
                endOffset: rawEnd,
              ),
              ReaderMarkStyle.highlight,
              ReaderMarkColor.amber,
              bookmarkId: 'bm-1',
            ),
          ],
          resolveParagraph: (_) => purified,
        );
        expect(mapped, hasLength(1));
        expect(
          purified.text.substring(
            mapped.single.range.startOffset,
            mapped.single.range.endOffset,
          ),
          '目标高亮',
        );

        // Selecting '目标高亮' in purified text (2..6) maps back to exact raw 6..10.
        final projectedBack = purified.rawRangeFor(2, 6);
        expect(projectedBack, (rawStart, rawEnd));
        expect(raw.substring(projectedBack.$1, projectedBack.$2), '目标高亮');

        // Chapter title purification works when applyToTitle is enabled.
        expect(
          store.purifyTitle('第一章 【广告】序幕', bookId: 100),
          '第一章 序幕',
        );
      },
    );

    test('detectUnsafeRegexPattern blocks ReDoS while allowing safe TOC rules', () {
      expect(detectUnsafeRegexPattern('(a+)+'), isNotNull);
      expect(detectUnsafeRegexPattern('(a|aa)+'), isNotNull);
      expect(detectUnsafeRegexPattern('.*.*foo'), isNotNull);
      expect(
        detectUnsafeRegexPattern(r'^第[0-9一二三四五六七八九十百千万]+[章节回][\s　]*.*$'),
        isNull,
      );
    });
  });

  group('P0-8 & P0-9 Custom TXT resplit & single-newline annotation remap', () {
    test(
      'remapLocalUnderlineRanges preserves highlights on single-newline TXT chapters',
      () async {
        const oldChapterText = '第一行引子\n第二行铺垫\n第三行包含重要批注😀结尾';
        const newChapterText = '新插入导语\n第一行引子\n第二行铺垫\n第三行包含重要批注😀结尾';
        final oldFile = await File(
          '${root.path}/old_single.txt',
        ).writeAsString(oldChapterText);
        final newFile = await File(
          '${root.path}/new_single.txt',
        ).writeAsString(newChapterText);
        final oldAnchor = await FileTextAnchor.open(oldFile.path);
        final newAnchor = await FileTextAnchor.open(newFile.path);
        // In ReaderContent.parse, single-newline lines become paragraphs 0, 1, 2.
        const quote = '重要批注😀';
        final para2Start = '第三行包含'.length;
        final para2End = para2Start + quote.length;

        final remapped = await remapLocalUnderlineRanges(
          ranges: [
            ReaderUnderlineRange(
              chapterId: 0,
              startParagraph: 2,
              startOffset: para2Start,
              endParagraph: 2,
              endOffset: para2End,
              contentRevision: 'rev-old',
            ),
          ],
          oldText: oldAnchor,
          newText: newAnchor,
          oldChapters: const [(offset: 0, length: oldChapterText.length)],
          newChapters: const [
            LocalChapterIndex('第一章', 0, newChapterText.length),
          ],
          oldRevision: 'rev-old',
          newRevision: 'rev-new',
          quote: quote,
        );
        expect(remapped, hasLength(1));
        expect(remapped.single.startParagraph, 3);
        expect(remapped.single.endParagraph, 3);
        expect(remapped.single.startOffset, para2Start);
        expect(remapped.single.endOffset, para2End);
        expect(remapped.single.contentRevision, 'rev-new');
      },
    );

    test(
      'resplitTxtChapters persists custom rule, migrates highlights, and rejects ReDoS',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          final store = await loadStore();
          final state = await bindState(store);
          const content =
              '@@1 Opening\nOpening line one\nOpening line two\n'
              '@@2 Target\nFirst single line\nSecond line with magic-quote here\n'
              '@@3 Finale\nClosing line';
          final txtFile = File('${await store.appFolderPath}/custom.txt');
          await txtFile.writeAsString(content);
          expect((await store.scanAppFolder()).added, 1);

          // Initially no built-in heading -> 1 chapter covering whole text.
          final initialBook = store.books.single;
          expect(initialBook.chapters, hasLength(1));

          final chaptersBefore = await store.chapters(initialBook.id);
          final novelBefore = store
              .toNovel(initialBook)
              .withChapters(chaptersBefore);
          const quote = 'magic-quote';
          const line5 = 'Second line with magic-quote here';
          final quoteStart = line5.indexOf(quote);
          await state.savePosition(
            novel: novelBefore,
            chapter: 0,
            offset: 0,
            maximum: 100,
            width: 400,
            paragraphIndex: 5,
            textOffset: content.indexOf(quote),
          );
          await state.saveAnnotation(
            novel: novelBefore,
            position: state.positionFor(initialBook.id)!,
            ranges: [
              ReaderUnderlineRange(
                chapterId: 0,
                startParagraph: 5,
                startOffset: quoteStart,
                endParagraph: 5,
                endOffset: quoteStart + quote.length,
                contentRevision: initialBook.revision,
              ),
            ],
            quote: quote,
            note: '跨切分保留',
            style: ReaderMarkStyle.highlight,
            color: ReaderMarkColor.amber,
          );

          // Unsafe regex must throw FormatException immediately.
          await expectLater(
            store.resplitTxtChapters(initialBook.id, customPattern: '(a+)+'),
            throwsA(isA<FormatException>()),
          );

          // Custom split into 3 chapters ('@@1...', '@@2...', '@@3...').
          final resplitNovel = await store.resplitTxtChapters(
            initialBook.id,
            customPattern: r'^@@\d+ .+$',
          );
          expect(resplitNovel, isNotNull);
          expect(resplitNovel!.chapters, hasLength(3));

          final updatedBook = store.books.single;
          expect(updatedBook.customTocPattern, r'^@@\d+ .+$');
          expect(store.pendingChapterRemaps, isEmpty);

          // Reading position & single-newline highlight migrated to chapter 1!
          final migratedPos = state.positionFor(updatedBook.id)!;
          expect(migratedPos.chapter, 1);
          final migratedMark = state.bookmarksFor(updatedBook.id).single;
          expect(migratedMark.position.chapter, 1);
          expect(migratedMark.underlineRanges.single.chapterId, 1);
          expect(migratedMark.underlineRanges.single.startParagraph, 1);
          expect(migratedMark.underlineRanges.single.startOffset, quoteStart);

          // Appending text and re-scanning preserves customTocPattern!
          await txtFile.writeAsString('$content\n@@4 Epilogue\nBonus line');
          await store.scanAppFolder(force: true);
          expect(store.books.single.chapters, hasLength(4));
          expect(store.books.single.customTocPattern, r'^@@\d+ .+$');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('P1-10, P1-11, P1-13, P1-14 MOBI/EPUB/Cloud/Splitter fixes', () {
    test('extractMobiBook decodes CP936/GBK and rejects DRM', () {
      // GBK bytes for "第一章 序章\n你好世界"
      final gbkBytes = Uint8List.fromList([
        0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, 0xD0, 0xF2, 0xD5, 0xC2, 0x0A,
        0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7,
      ]);
      expect(decodeGbkBytes(gbkBytes), '第一章 序章\n你好世界');

      final mobi = extractMobiBook(
        _buildMobiWithEncoding(textBytes: gbkBytes, textEncoding: 936),
        fallbackTitle: 'GBK测试',
      );
      expect(mobi.text, contains('你好世界'));
      expect(mobi.chapters.first.title, contains('第一章 序章'));

      expect(
        () => extractMobiBook(
          _buildMobiWithEncoding(
            textBytes: gbkBytes,
            textEncoding: 65001,
            encryptionType: 2,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('lenient EPUB caps nested .epub recursion depth', () async {
      var nested = _zipEntries({
        'chapter1.xhtml': utf8.encode('<html><body><p>最内层正文</p></body></html>'),
      });
      for (var d = 0; d < 4; d++) {
        nested = _zipEntries({
          'inner_$d.epub': nested,
          if (d == 3)
            'outer_fallback.xhtml': utf8.encode(
              '<html><body><p>外层兜底正文</p></body></html>',
            ),
        });
      }
      final epubFile = File('${root.path}/nested.epub');
      await epubFile.writeAsBytes(nested, flush: true);
      final pkg = await EpubPackage.open(epubFile.path, lenient: true);
      try {
        expect(pkg.chapters, isNotEmpty);
      } finally {
        await pkg.close();
      }
    });

    test(
      'cloud-imported MOBI preserves format, supports editBookFile rename, and cleans up disk',
      () async {
        final store = await loadStore();
        final mobiTemp = File('${root.path}/tmp/cloud_sample.mobi');
        await mobiTemp.writeAsBytes(
          _buildMobiWithEncoding(
            textBytes: Uint8List.fromList(utf8.encode('第一章 云端\n云端正文内容。')),
            textEncoding: 65001,
          ),
          flush: true,
        );
        final importedMobi = await store.importCloudFile(
          'cloud_sample.mobi',
          mobiTemp.path,
        );
        final mobiBook = store.bookFor(importedMobi.id)!;
        expect(isMobiFileName(mobiBook.fileName), isTrue);
        expect(mobiBook.fileName, 'cloud_sample.mobi');

        final renamed = await store.editBookFile(
          mobiBook.id,
          title: '重命名云端书',
          author: '新作者',
        );
        expect(renamed.fileName, '重命名云端书.mobi');
        expect(renamed.displayAuthor, '新作者');
        final onDisk = File(renamed.sourceKey);
        expect(await onDisk.exists(), isTrue);
        expect(
          RegExp(r'^[0-9a-f]{16}_重命名云端书\.mobi$').hasMatch(
            onDisk.uri.pathSegments.last,
          ),
          isTrue,
        );

        await store.removeBook(renamed.id);
        expect(await onDisk.exists(), isFalse);
      },
    );

    test(
      'chapter_splitter preserves exact UTF-8 byte offsets and surrogate boundaries',
      () {
        const glued = '  第一章 标题：紧贴正文😀内容\n第二行正文。';
        final split1 = splitLocalChapters(glued);
        final utf8Glued = utf8.encode(glued);
        expect(
          split1.last.byteOffset + split1.last.byteLength,
          utf8Glued.length,
        );
        for (final ch in split1) {
          final slice = utf8.decode(
            utf8Glued.sublist(ch.byteOffset, ch.byteOffset + ch.byteLength),
          );
          expect(slice, glued.substring(ch.offset, ch.offset + ch.length));
        }

        const customNoTrailingNl = 'Sec 1\n第一段😀内容\nSec 2\n末尾无换行😀';
        final split2 = splitLocalChaptersCustom(
          customNoTrailingNl,
          customPattern: r'^Sec \d+$',
        );
        final utf8Custom = utf8.encode(customNoTrailingNl);
        expect(
          split2.last.byteOffset + split2.last.byteLength,
          utf8Custom.length,
        );
        for (final ch in split2) {
          final slice = utf8.decode(
            utf8Custom.sublist(ch.byteOffset, ch.byteOffset + ch.byteLength),
          );
          expect(
            slice,
            customNoTrailingNl.substring(ch.offset, ch.offset + ch.length),
          );
        }

        // Oversized chapter subdivision never cuts inside a surrogate pair.
        final emojiWall = List.filled(1600, '😀').join();
        final subdivided = subdivideOversizedChapters(
          emojiWall,
          [
            LocalChapterIndex(
              '超长章',
              0,
              emojiWall.length,
              byteOffset: 0,
              byteLength: utf8.encode(emojiWall).length,
            ),
          ],
          maxChapterChars: 1201, // Odd code-unit target lands mid-surrogate!
        );
        expect(subdivided.length, greaterThan(1));
        for (final part in subdivided) {
          expect(part.offset.isEven, isTrue);
          expect(part.length.isEven, isTrue);
        }
      },
    );
  });

  group('P1-12 Duplicate detection precision & PDF duplicate deletion', () {
    LocalBook makeBook({
      required int id,
      required String name,
      String title = '',
      String author = '',
      LocalBookKind kind = LocalBookKind.txt,
      int size = 1000,
      int pageCount = 0,
      String sourceFingerprint = 'fp',
      String uri = '',
    }) => LocalBook(
      id: id,
      title: title.isEmpty ? name : title,
      author: author,
      fileUri: uri.isEmpty ? 'content://tree/primary%3ABooks/document/$id' : uri,
      fileName: name,
      kind: kind,
      size: size,
      modified: 1,
      chapters: const [],
      pageCount: pageCount,
      sourceId: 'saf:content://tree/primary%3ABooks',
      sourceKey: 'content://tree/primary%3ABooks/document/$id',
      sourceFingerprint: sourceFingerprint,
    );

    test('does not merge distinct books sharing (1) suffix or conflicting authors', () {
      final report = findLocalDuplicates([
        makeBook(
          id: localNovelIdBase + 1,
          name: '星海漫游 (1).txt',
          title: '星海漫游 (1)',
          sourceFingerprint: 'fp-a',
        ),
        makeBook(
          id: localNovelIdBase + 2,
          name: '深渊回响 (1).txt',
          title: '深渊回响 (1)',
          sourceFingerprint: 'fp-b',
        ),
        makeBook(
          id: localNovelIdBase + 3,
          name: '迷雾 - 张三.txt',
          title: '迷雾',
          author: '张三',
          sourceFingerprint: 'fp-c',
        ),
        makeBook(
          id: localNovelIdBase + 4,
          name: '迷雾 - 李四.txt',
          title: '迷雾',
          author: '李四',
          sourceFingerprint: 'fp-d',
        ),
      ]);
      expect(report.content, isEmpty);
      expect(report.title, isEmpty);

      // Same stem with (1) copy suffix DOES merge!
      final validCopyReport = findLocalDuplicates([
        makeBook(
          id: localNovelIdBase + 5,
          name: '三体.txt',
          title: '三体',
          sourceFingerprint: 'fp-1',
        ),
        makeBook(
          id: localNovelIdBase + 6,
          name: '三体 (1).txt',
          title: '三体 (1)',
          sourceFingerprint: 'fp-2',
        ),
      ]);
      expect(validCopyReport.title, hasLength(1));

      // Keeper recommendation prefers copy with annotations.
      final group = validCopyReport.title.single;
      final b2 = group.books[1];
      final keeper = recommendedDuplicateKeeper(
        group.books,
        hasRead: (_) => false,
        lastReadAt: (_) => 0,
        annotationCount: (id) => id == b2.id ? 3 : 0,
      );
      expect(keeper.id, b2.id);
    });

    test('deleteDuplicateBookFile supports SAF PDFs without sourceFingerprint', () async {
      var deletedUri = '';
      messenger.setMockMethodCallHandler(localChannel, (call) async {
        if (call.method == 'scanLocalFolder') {
          return {
            'complete': true,
            'entries': [
              {
                'uri':
                    'content://com.android.externalstorage.documents/tree/primary%3ABooks/document/primary%3ABooks%2Fa.pdf',
                'name': '手册.pdf',
                'size': 2048,
                'modified': 10,
              },
              {
                'uri':
                    'content://com.android.externalstorage.documents/tree/primary%3ABooks/document/primary%3ABooks%2Fb.pdf',
                'name': '手册 (1).pdf',
                'size': 2048,
                'modified': 10,
              },
            ],
          };
        }
        if (call.method == 'pdfPageCount') return 12;
        if (call.method == 'deleteLocalDocument') {
          deletedUri = (call.arguments as Map)['docUri'] as String;
          return {'deleted': true, 'outcome': 'deleted'};
        }
        if (call.method == 'clearPdfCache') return null;
        return null;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'local_library_folder',
        'content://com.android.externalstorage.documents/tree/primary%3ABooks',
      );
      final store = await loadStore();
      final scan = await store.scan();
      expect(scan.added, 2);
      final keeper = store.books[0];
      final dup = store.books[1];
      expect(keeper.sourceFingerprint, isEmpty);
      await store.deleteDuplicateBookFile(dup, keeper: keeper);
      expect(deletedUri, dup.fileUri);
      expect(store.books.map((b) => b.id), [keeper.id]);
    });
  });

  group('P2-1 & P2-3 ReaderVolumePaging owner stack & find snippet surrogate safety', () {
    testWidgets(
      'ReaderVolumePaging keeps volumePaging active until all owners dispose and omits brightness/statusBar',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final calls = <Map<Object?, Object?>>[];
          messenger.setMockMethodCallHandler(controlsChannel, (call) async {
            if (call.method == 'apply') {
              calls.add(Map<Object?, Object?>.from(call.arguments as Map));
            }
            return null;
          });

          await tester.pumpWidget(
            MaterialApp(
              home: ReaderVolumePaging(
                enabled: true,
                onPage: (_) {},
                child: ReaderVolumePaging(
                  enabled: true,
                  onPage: (_) {},
                  child: const SizedBox(),
                ),
              ),
            ),
          );
          expect(calls, [
            {'volumePaging': true},
          ]);

          // Unmount inner ReaderVolumePaging -> outer is still active, no false sent!
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderVolumePaging(
                enabled: true,
                onPage: (_) {},
                child: const SizedBox(),
              ),
            ),
          );
          expect(calls, [
            {'volumePaging': true},
          ]);

          // Unmount outer ReaderVolumePaging -> now volumePaging: false is sent without brightness/hideStatusBar!
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          expect(calls, [
            {'volumePaging': true},
            {'volumePaging': false},
          ]);
          for (final args in calls) {
            expect(args.containsKey('brightness'), isFalse);
            expect(args.containsKey('hideStatusBar'), isFalse);
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'ReaderFindPanel renders snippets around emoji without splitting UTF-16 surrogates',
      (tester) async {
        // Place emoji right at match.start - 24 and match.end + 56 boundaries!
        final prefix = '${'甲' * 10}😀${'乙' * 23}';
        final suffix = '${'丙' * 55}😀${'丁' * 10}';
        final paragraph = '$prefix关键词$suffix';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderFindPanel(
                content: ReaderContent([paragraph]),
              ),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('reader-find-field')),
          '关键词',
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('reader-find-result-0')), findsOneWidget);

        // Verify no U+FFFD replacement character appears in any rendered RichText!
        for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
          expect(widget.text.toPlainText().contains('\uFFFD'), isFalse);
        }
      },
    );
  });
}

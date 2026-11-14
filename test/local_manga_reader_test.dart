import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_backup.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/local_library_page.dart';
import 'package:shuyu/local_manga_reader.dart';
import 'package:shuyu/local_platform.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/reader_preferences.dart';

class _MangaTestPaths extends PathProviderPlatform {
  _MangaTestPaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getExternalStoragePath() async => root;
}

Future<Uint8List> _testMangaPng({
  int width = 80,
  int height = 120,
  Color color = const Color(0xFF3A5F7D),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    Rect.fromLTWH(8, 12, width - 16.0, height - 24.0),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final bytes = Uint8List.fromList(data.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return bytes;
}

Uint8List _zipEntries(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _buildRgbaWithBorder({
  required int width,
  required int height,
  required int marginLeft,
  required int marginTop,
  required int marginRight,
  required int marginBottom,
  required List<int> borderRgba,
  required List<int> contentRgba,
}) {
  final buf = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final inY = y >= marginTop && y < height - marginBottom;
    for (var x = 0; x < width; x++) {
      final inX = x >= marginLeft && x < width - marginRight;
      final src = (inX && inY) ? contentRgba : borderRgba;
      final idx = (y * width + x) * 4;
      buf[idx] = src[0];
      buf[idx + 1] = src[1];
      buf[idx + 2] = src[2];
      buf[idx + 3] = src[3];
    }
  }
  return buf;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildMangaSpreads 双页拼合算法', () {
    test('单页模式下每页独立成屏', () {
      final spreads = buildMangaSpreads(
        pageCount: 4,
        spreadEnabled: false,
        coverOffset: true,
        knownPageSizes: const {},
      );
      expect(spreads.map((s) => s.pages).toList(), [
        [0],
        [1],
        [2],
        [3],
      ]);
    });

    test('双页模式开启首页单页偏移时封面独立、后续成对拼合', () {
      final spreads = buildMangaSpreads(
        pageCount: 5,
        spreadEnabled: true,
        coverOffset: true,
        knownPageSizes: const {},
      );
      expect(spreads.map((s) => s.pages).toList(), [
        [0],
        [1, 2],
        [3, 4],
      ]);
    });

    test('双页模式关闭首页单页偏移时从第 0 页起成对拼合', () {
      final spreads = buildMangaSpreads(
        pageCount: 5,
        spreadEnabled: true,
        coverOffset: false,
        knownPageSizes: const {},
      );
      expect(spreads.map((s) => s.pages).toList(), [
        [0, 1],
        [2, 3],
        [4],
      ]);
    });

    test('宽幅跨页原图自动独占一屏且不破坏前后单页对齐', () {
      final spreads = buildMangaSpreads(
        pageCount: 6,
        spreadEnabled: true,
        coverOffset: true,
        knownPageSizes: const {
          0: Size(800, 1200),
          1: Size(800, 1200),
          // 第 2 页是宽幅跨页原图 -> 第 1 页保持单页，第 2 页独占，第 3、4 页恢复成对
          2: Size(1600, 1200),
          3: Size(800, 1200),
          4: Size(800, 1200),
          5: Size(800, 1200),
        },
      );
      expect(spreads.map((s) => s.pages).toList(), [
        [0],
        [1],
        [2],
        [3, 4],
        [5],
      ]);
    });

    test('新话起始页不会与上一话末尾页合并跨页', () {
      final spreads = buildMangaSpreads(
        pageCount: 6,
        spreadEnabled: true,
        coverOffset: false,
        knownPageSizes: const {},
        chapterStartPages: const {3},
      );
      expect(spreads.map((s) => s.pages).toList(), [
        [0, 1],
        [2],
        [3, 4],
        [5],
      ]);
    });
  });

  group('detectMangaContentRect 四周白边黑边自动裁切', () {
    test('准确识别四周纯白留白并保留微距呼吸边距', () {
      final rgba = _buildRgbaWithBorder(
        width: 100,
        height: 100,
        marginLeft: 10,
        marginTop: 12,
        marginRight: 10,
        marginBottom: 12,
        borderRgba: const [255, 255, 255, 255],
        contentRgba: const [30, 30, 30, 255],
      );
      final rect = detectMangaContentRect(rgba, 100, 100);
      expect(rect.left, closeTo(0.09, 0.02));
      expect(rect.top, closeTo(0.11, 0.02));
      expect(rect.right, closeTo(0.91, 0.02));
      expect(rect.bottom, closeTo(0.89, 0.02));
    });

    test('准确识别四周纯黑留白', () {
      final rgba = _buildRgbaWithBorder(
        width: 100,
        height: 100,
        marginLeft: 8,
        marginTop: 10,
        marginRight: 8,
        marginBottom: 10,
        borderRgba: const [5, 5, 5, 255],
        contentRgba: const [220, 220, 220, 255],
      );
      final rect = detectMangaContentRect(rgba, 100, 100);
      expect(rect.left, greaterThan(0.05));
      expect(rect.top, greaterThan(0.07));
      expect(rect.right, lessThan(0.95));
      expect(rect.bottom, lessThan(0.93));
    });

    test('满版彩色无统一边框时不误裁切', () {
      final buf = Uint8List(64 * 64 * 4);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final idx = (y * 64 + x) * 4;
          buf[idx] = (x * 4) & 0xFF;
          buf[idx + 1] = (y * 4) & 0xFF;
          buf[idx + 2] = 128;
          buf[idx + 3] = 255;
        }
      }
      expect(
        detectMangaContentRect(buf, 64, 64),
        const Rect.fromLTWH(0, 0, 1, 1),
      );
    });

    test('大面积空白页每侧裁切不超过 18% 上限', () {
      final rgba = _buildRgbaWithBorder(
        width: 100,
        height: 100,
        marginLeft: 40,
        marginTop: 40,
        marginRight: 40,
        marginBottom: 40,
        borderRgba: const [255, 255, 255, 255],
        contentRgba: const [20, 20, 20, 255],
      );
      final rect = detectMangaContentRect(rgba, 100, 100);
      expect(rect.left, lessThanOrEqualTo(0.18));
      expect(rect.top, lessThanOrEqualTo(0.18));
      expect(rect.right, greaterThanOrEqualTo(0.82));
      expect(rect.bottom, greaterThanOrEqualTo(0.82));
    });
  });

  group('偏好序列化、单书模式覆盖与书架漫画筛选', () {
    test('默认 ReaderPreferences.toJson 不写入多余键，自定义漫画偏好完整往返', () {
      expect(const ReaderPreferences().toJson().containsKey('mangaMode'), isFalse);
      const custom = ReaderPreferences(
        mangaMode: MangaReadingMode.webtoon,
        mangaSpread: MangaSpreadMode.autoLandscape,
        mangaCoverOffset: false,
        mangaCropMargins: true,
        mangaDarkCanvas: false,
        mangaNightDim: 0.35,
        mangaInvert: true,
      );
      final decoded = ReaderPreferences.fromJson(custom.toJson());
      expect(decoded.mangaMode, MangaReadingMode.webtoon);
      expect(decoded.mangaSpread, MangaSpreadMode.autoLandscape);
      expect(decoded.mangaCoverOffset, isFalse);
      expect(decoded.mangaCropMargins, isTrue);
      expect(decoded.mangaDarkCanvas, isFalse);
      expect(decoded.mangaNightDim, closeTo(0.35, 1e-6));
      expect(decoded.mangaInvert, isTrue);
      expect(decoded.toJson(), custom.toJson());
    });

    test('单书漫画模式覆盖支持备份恢复与清理，且参与书架「漫画」筛选', () async {
      final temp = await Directory.systemTemp.createTemp('shuyu_manga_pref_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final prevPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _MangaTestPaths(temp.path);
      addTearDown(() => PathProviderPlatform.instance = prevPaths);

      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      LibraryFilter.shared.resetForTesting();
      addTearDown(LibraryFilter.shared.resetForTesting);

      final store = await LocalLibraryStore.load();
      addTearDown(store.dispose);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);

      final p1 = await _testMangaPng();
      final p2 = await _testMangaPng();
      final cbzFile = File('${temp.path}/bocchi.cbz');
      await cbzFile.writeAsBytes(_zipEntries({'01.png': p1, '02.png': p2}));
      final epubFile = File('${temp.path}/novel.epub');
      await epubFile.writeAsBytes(
        _zipEntries({
          'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
          'OEBPS/content.opf': utf8.encode('''
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>普通轻小说</dc:title>
  </metadata>
  <manifest>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>'''),
          'OEBPS/c1.xhtml': utf8.encode(
            '<html><body><h1>第一章</h1><p>${'普通文字段落内容。' * 120}</p></body></html>',
          ),
        }),
      );

      final cbzNovel = await store.importCloudFile('bocchi.cbz', cbzFile.path);
      final cbz = store.bookFor(cbzNovel.id)!;
      final epubNovel = await store.importCloudFile('novel.epub', epubFile.path);
      final epub = store.bookFor(epubNovel.id)!;
      expect(epub.isComicEpub, isFalse);

      LibraryFilter.shared.toggleFormat(BookFormatFilter.comic);
      expect(
        LibraryFilter.shared.matchesFormat(cbz.id, store, state: state),
        isTrue,
      );
      expect(
        LibraryFilter.shared.matchesFormat(epub.id, store, state: state),
        isFalse,
      );

      // 手动开启单书漫画模式后，常规 EPUB 也会响应「漫画」筛选
      await state.setBookMangaModeOverride(epub.id, 'manga');
      expect(
        LibraryFilter.shared.matchesFormat(epub.id, store, state: state),
        isTrue,
      );
      await state.setBookMangaModeOverride(epub.id, null);

      const pdfBookId = localNovelIdBase + 777;
      await state.setBookMangaModeOverride(pdfBookId, 'manga');
      expect(state.bookMangaModeOverride(pdfBookId), 'manga');
      expect(state.isMangaModeForBook(pdfBookId), isTrue);

      final backup = await LibraryBackup.parse(
        await (await state.createBackup()).encode(),
      );
      await state.setBookMangaModeOverride(pdfBookId, null);
      expect(state.bookMangaModeOverride(pdfBookId), isNull);

      await state.restoreBackup(backup, importPreferences: true);
      expect(state.bookMangaModeOverride(pdfBookId), 'manga');

      await state.clearBookProgress(pdfBookId);
      expect(state.bookMangaModeOverride(pdfBookId), isNull);

      // 跨设备恢复时，按源文件指纹自动将旧本地书籍 ID 的漫画模式覆盖重映射到当前 ID
      const remoteEpubId = localNovelIdBase + 8888;
      final remoteSnap = store.toNovel(epub).toSnapshot()
        ..['id'] = remoteEpubId;
      final crossDeviceBackup = await LibraryBackup.fromRecords({
        'novel_meta_$remoteEpubId': jsonEncode(remoteSnap),
        'mangaBookModes': jsonEncode({
          '$remoteEpubId': 'manga',
        }),
      });
      await state.restoreBackup(crossDeviceBackup, importPreferences: true);
      expect(state.bookMangaModeOverride(epub.id), 'manga');
    });
  });

  group('LocalMangaReaderPage 阅读交互与进度书签', () {
    Future<void> pumpManga(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 260));
    }

    testWidgets('支持日漫右翻点击翻页、阅读进度保存、读完判定、页码书签与条漫切换', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 840);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late Directory temp;
      late PathProviderPlatform prevPaths;
      late LocalLibraryStore store;
      late LibraryState state;
      late LocalBook comic;

      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('shuyu_manga_widget_');
        prevPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _MangaTestPaths(temp.path);
        SharedPreferences.setMockInitialValues({});
        await TagStore.load();
        store = await LocalLibraryStore.load();
        state = await LibraryState.load();
        state.bindLocalChapters(store);

        final p1 = await _testMangaPng(color: const Color(0xFFAA3344));
        final p2 = await _testMangaPng(color: const Color(0xFF33AA55));
        final p3 = await _testMangaPng(color: const Color(0xFF3355AA));
        final cbzFile = File('${temp.path}/dungeon_meshi.cbz');
        await cbzFile.writeAsBytes(
          _zipEntries({'001.png': p1, '002.png': p2, '003.png': p3}),
        );
        final comicNovel = await store.importCloudFile(
          '迷宫饭.cbz',
          cbzFile.path,
        );
        comic = store.bookFor(comicNovel.id)!;
      });
      addTearDown(() async {
        state.dispose();
        store.dispose();
        PathProviderPlatform.instance = prevPaths;
        await tester.runAsync(() async {
          if (await temp.exists()) await temp.delete(recursive: true);
        });
      });

      final novel = store.toNovel(comic);
      final routed = readerPageFor(
        novel: novel,
        state: state,
        repository: store,
        chapter: 0,
      );
      expect(routed, isA<LocalMangaReaderPage>());

      await tester.pumpWidget(
        MaterialApp(
          home: LocalMangaReaderPage(
            novel: novel,
            state: state,
            local: store,
          ),
        ),
      );
      await pumpManga(tester);

      expect(find.textContaining('第 1 / 3 页'), findsOneWidget);
      expect(state.chapterForNovel(novel), 0);
      expect(state.finishedReading(novel), isFalse);
      expect(state.lastReadAt(novel.id), greaterThan(0));

      // 默认日漫右翻模式：点击屏幕左侧区域翻到第 2 页
      await tester.tapAt(const Offset(40, 420));
      await pumpManga(tester);
      expect(find.textContaining('第 2 / 3 页'), findsOneWidget);
      expect(state.chapterForNovel(novel), 1);

      // 菜单栏初始展开：直接添加当前页书签
      await tester.tap(find.byKey(const ValueKey('manga-quick-bookmark-entry')));
      await pumpManga(tester);
      expect(state.bookmarksFor(novel.id), hasLength(1));
      expect(state.bookmarksFor(novel.id).single.position.chapter, 1);

      // 点击中央区域收起菜单栏 -> 沉浸右下角页码胶囊显示；再次点击中央呼出菜单栏
      await tester.tapAt(const Offset(210, 420));
      await pumpManga(tester);
      expect(find.byKey(const ValueKey('manga-page-hud')), findsOneWidget);
      await tester.tapAt(const Offset(210, 420));
      await pumpManga(tester);

      // 继续点击左侧翻到第 3 页（末页） -> 判定为已读完
      await tester.tapAt(const Offset(40, 420));
      await pumpManga(tester);
      expect(find.textContaining('第 3 / 3 页'), findsOneWidget);
      expect(state.chapterForNovel(novel), 2);
      expect(state.finishedReading(novel), isTrue);

      // 打开模式面板切换为「条漫下拉」
      await tester.tap(find.byKey(const ValueKey('manga-mode-entry')));
      await pumpManga(tester);
      expect(find.byKey(const ValueKey('manga-mode-sheet')), findsOneWidget);
      await tester.tap(find.text('条漫下拉'));
      await pumpManga(tester);
      expect(state.readerPreferences.mangaMode, MangaReadingMode.webtoon);
      Navigator.of(tester.element(find.byType(LocalMangaReaderPage))).pop();
      await pumpManga(tester);
      expect(find.byKey(const ValueKey('manga-webtoon-list')), findsOneWidget);

      // 开启夜间降亮护眼遮罩
      await state.setReaderPreferences(
        state.readerPreferences.copyWith(mangaNightDim: 0.4),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('manga-night-dim-overlay')),
        findsOneWidget,
      );
    });

    testWidgets(
      '夜间模式下 PDF 分卷漫画不跟随常规 PDF 反色，且进度条按分卷定位并支持上/下一卷切换',
      (tester) async {
        tester.view.physicalSize = const Size(420, 840);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const mangaTree =
            'content://com.android.externalstorage.documents/tree/primary%3AManga';
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        late Directory temp;
        late PathProviderPlatform prevPaths;
        late LocalLibraryStore store;
        late LibraryState state;
        late LocalBook seriesBook;

        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('shuyu_manga_series_');
          prevPaths = PathProviderPlatform.instance;
          PathProviderPlatform.instance = _MangaTestPaths(temp.path);
          final pagePng = await _testMangaPng(color: const Color(0xFFD96B43));
          final renderedPage = File('${temp.path}/rendered_series_page.png');
          await renderedPage.writeAsBytes(pagePng);

          messenger.setMockMethodCallHandler(LocalPlatform.channel, (
            call,
          ) async {
            switch (call.method) {
              case 'scanLocalFolder':
                return {
                  'complete': true,
                  'rootName': 'Manga',
                  'dirUris': {'迷宫饭': '$mangaTree/document/mgf_dir'},
                  'entries': [
                    {
                      'uri': '$mangaTree/document/mgf_02.pdf',
                      'name': 'Mgf_02.pdf',
                      'relPath': '迷宫饭/Mgf_02.pdf',
                      'size': 120 * 1024 * 1024,
                      'modified': 2000,
                    },
                    {
                      'uri': '$mangaTree/document/mgf_01.pdf',
                      'name': 'Mgf_01.pdf',
                      'relPath': '迷宫饭/Mgf_01.pdf',
                      'size': 120 * 1024 * 1024,
                      'modified': 2000,
                    },
                  ],
                };
              case 'pdfPageCount':
                final uri = (call.arguments as Map)['docUri'] as String;
                return uri.endsWith('mgf_01.pdf') ? 3 : 4;
              case 'renderPdfPage':
                return renderedPage.path;
              case 'clearPdfCache':
                return null;
            }
            throw MissingPluginException(call.method);
          });

          SharedPreferences.setMockInitialValues({
            'local_library_manga_folder': mangaTree,
            'reduce_motion': true,
          });
          await TagStore.load();
          store = await LocalLibraryStore.load();
          state = await LibraryState.load();
          state.bindLocalChapters(store);
          await state.setPdfNightInvert(true);
          await store.scan();
          seriesBook = store.books.single;
        });
        addTearDown(() async {
          messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
          state.dispose();
          store.dispose();
          PathProviderPlatform.instance = prevPaths;
          await tester.runAsync(() async {
            if (await temp.exists()) await temp.delete(recursive: true);
          });
        });

        expect(seriesBook.isComicSeries, isTrue);
        expect(seriesBook.isIntrinsicManga, isTrue);
        expect(state.pdfNightInvert, isTrue);
        expect(state.readerPreferences.mangaInvert, isFalse);

        final novel = store.toNovel(seriesBook);
        // 无需手动切换，默认直接进入漫画阅读器
        final routed = readerPageFor(
          novel: novel,
          state: state,
          repository: store,
          chapter: 0,
        );
        expect(routed, isA<LocalMangaReaderPage>());

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            darkTheme: ThemeData.dark(),
            themeMode: ThemeMode.dark,
            home: LocalMangaReaderPage(
              novel: novel,
              state: state,
              local: store,
            ),
          ),
        );
        await pumpManga(tester);

        // 暗色模式下即便 pdfNightInvert 为 true，漫画页面也绝不自动反色变蓝/负片
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.byKey(const ValueKey('manga-color-invert-0')),
          findsNothing,
        );
        // 多卷状态文案与当前卷滑杆范围（第 1 卷共 3 页 -> max = 2.0）
        expect(
          find.textContaining('Mgf_01 · 第 1 / 3 页 · 全书 14%'),
          findsOneWidget,
        );
        expect(tester.widget<Slider>(find.byType(Slider)).max, 2.0);

        // 日漫右翻模式下左侧按钮为「下一卷」：点击切换到 Mgf_02（共 4 页 -> max = 3.0）
        await tester.tap(find.byKey(const ValueKey('manga-prev-chapter')));
        await pumpManga(tester);
        expect(
          find.textContaining('Mgf_02 · 第 1 / 4 页 · 全书 57%'),
          findsOneWidget,
        );
        expect(tester.widget<Slider>(find.byType(Slider)).max, 3.0);
        expect(state.chapterForNovel(novel), 3);

        // 仅当用户主动开启漫画专属反色开关时才施加 ColorFiltered
        await state.setReaderPreferences(
          state.readerPreferences.copyWith(mangaInvert: true),
        );
        await pumpManga(tester);
        expect(
          find.byKey(const ValueKey('manga-color-invert-3')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '漫画徽标标识、小说/漫画格式筛选、详情页分卷展示与双文件夹独立入口渲染正确',
      (tester) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const novelTree =
            'content://com.android.externalstorage.documents/tree/primary%3ANovels';
        const mangaTree =
            'content://com.android.externalstorage.documents/tree/primary%3AManga';
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        late Directory temp;
        late PathProviderPlatform prevPaths;
        late LocalLibraryStore store;
        late LibraryState state;
        late LocalBook txtBook;
        late LocalBook seriesBook;
        late LocalBook singlePdfManga;
        late Novel loadedSeriesNovel;

        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('shuyu_manga_ui_');
          prevPaths = PathProviderPlatform.instance;
          PathProviderPlatform.instance = _MangaTestPaths(temp.path);
          LibraryFilter.shared.resetForTesting();

          final pagePng = await _testMangaPng(color: const Color(0xFF457B9D));
          final renderedPage = File('${temp.path}/rendered_ui_page.png');
          await renderedPage.writeAsBytes(pagePng);
          final txtSource = File('${temp.path}/santi.txt');
          await txtSource.writeAsString(
            '第一章 科学边界\n叶文洁抬头望向红岸基地的天空。\n' * 30,
          );

          messenger.setMockMethodCallHandler(LocalPlatform.channel, (
            call,
          ) async {
            switch (call.method) {
              case 'scanLocalFolder':
                final treeUri = (call.arguments as Map)['treeUri'] as String;
                if (treeUri == novelTree) {
                  return {
                    'complete': true,
                    'rootName': 'Novels',
                    'entries': [
                      {
                        'uri': '$novelTree/document/santi.txt',
                        'name': '三体.txt',
                        'relPath': '三体.txt',
                        'size': await txtSource.length(),
                        'modified': 1000,
                      },
                    ],
                  };
                }
                return {
                  'complete': true,
                  'rootName': 'Manga',
                  'dirUris': {'迷宫饭': '$mangaTree/document/mgf_dir'},
                  'entries': [
                    {
                      'uri': '$mangaTree/document/mgf_01.pdf',
                      'name': 'Mgf_01.pdf',
                      'relPath': '迷宫饭/Mgf_01.pdf',
                      'size': 100 * 1024 * 1024,
                      'modified': 2000,
                    },
                    {
                      'uri': '$mangaTree/document/mgf_02.pdf',
                      'name': 'Mgf_02.pdf',
                      'relPath': '迷宫饭/Mgf_02.pdf',
                      'size': 100 * 1024 * 1024,
                      'modified': 2000,
                    },
                    {
                      'uri': '$mangaTree/document/oneshot.pdf',
                      'name': '短篇集.pdf',
                      'relPath': '短篇集.pdf',
                      'size': 30 * 1024 * 1024,
                      'modified': 2100,
                    },
                  ],
                };
              case 'prepareLocalText':
                final copy = File(
                  '${temp.path}/prepared_${DateTime.now().microsecondsSinceEpoch}.txt',
                );
                await txtSource.copy(copy.path);
                return {
                  'path': copy.path,
                  'fingerprint': 'santi_sha256',
                };
              case 'pdfPageCount':
                final uri = (call.arguments as Map)['docUri'] as String;
                if (uri.endsWith('mgf_01.pdf')) return 3;
                if (uri.endsWith('mgf_02.pdf')) return 4;
                return 5;
              case 'renderPdfPage':
                return renderedPage.path;
              case 'clearPdfCache':
                return null;
            }
            throw MissingPluginException(call.method);
          });

          SharedPreferences.setMockInitialValues({
            'local_library_folder': novelTree,
            'local_library_manga_folder': mangaTree,
            'reduce_motion': true,
          });
          await TagStore.load();
          store = await LocalLibraryStore.load();
          state = await LibraryState.load();
          state.bindLocalChapters(store);
          await store.scan();

          txtBook = store.books.firstWhere((b) => b.displayTitle == '三体');
          seriesBook = store.books.firstWhere((b) => b.displayTitle == '迷宫饭');
          singlePdfManga = store.books.firstWhere(
            (b) => b.displayTitle == '短篇集',
          );
          final chapters = await store.chapters(seriesBook.id);
          loadedSeriesNovel = store
              .toNovel(seriesBook)
              .withChapters(chapters);
        });
        addTearDown(() async {
          LibraryFilter.shared.resetForTesting();
          messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
          state.dispose();
          store.dispose();
          PathProviderPlatform.instance = prevPaths;
          await tester.runAsync(() async {
            if (await temp.exists()) await temp.delete(recursive: true);
          });
        });

        // 1. 漫画徽标文案区分普通小说、单册漫画与多卷漫画
        expect(
          mangaBadgeLabelForBook(
            txtBook,
            isMangaMode: state.isMangaModeForBook(txtBook.id, book: txtBook),
          ),
          isNull,
        );
        expect(
          mangaBadgeLabelForBook(
            singlePdfManga,
            isMangaMode: state.isMangaModeForBook(
              singlePdfManga.id,
              book: singlePdfManga,
            ),
          ),
          '漫画',
        );
        expect(
          mangaBadgeLabelForBook(
            seriesBook,
            isMangaMode: state.isMangaModeForBook(
              seriesBook.id,
              book: seriesBook,
            ),
          ),
          '漫画 · 2 卷',
        );

        // 2. 书架筛选器：「漫画」与「小说」互不干扰
        LibraryFilter.shared.toggleFormat(BookFormatFilter.comic);
        expect(
          LibraryFilter.shared.matchesFormat(
            seriesBook.id,
            store,
            state: state,
          ),
          isTrue,
        );
        expect(
          LibraryFilter.shared.matchesFormat(
            singlePdfManga.id,
            store,
            state: state,
          ),
          isTrue,
        );
        expect(
          LibraryFilter.shared.matchesFormat(txtBook.id, store, state: state),
          isFalse,
        );

        LibraryFilter.shared.resetForTesting();
        LibraryFilter.shared.toggleFormat(BookFormatFilter.novel);
        expect(
          LibraryFilter.shared.matchesFormat(txtBook.id, store, state: state),
          isTrue,
        );
        expect(
          LibraryFilter.shared.matchesFormat(
            seriesBook.id,
            store,
            state: state,
          ),
          isFalse,
        );
        expect(
          LibraryFilter.shared.matchesFormat(
            singlePdfManga.id,
            store,
            state: state,
          ),
          isFalse,
        );
        LibraryFilter.shared.resetForTesting();

        // 3. 详情页展示「漫画 · 2 卷」徽标、「共 2 卷 · 7 页」目录头与「开始阅读 · Mgf_01（第1页）」
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              novel: loadedSeriesNovel,
              state: state,
              repository: store,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(ValueKey('detail-manga-badge-${seriesBook.id}')),
          findsOneWidget,
        );
        expect(find.widgetWithText(MangaBadge, '漫画 · 2 卷'), findsOneWidget);
        expect(find.text('共 2 卷 · 7 页'), findsOneWidget);
        expect(find.text('开始阅读 · Mgf_01（第1页）'), findsOneWidget);

        // 4. 本地书库页同时展示独立的「小说文件夹」与「漫画文件夹」授权卡片
        await tester.pumpWidget(
          MaterialApp(
            home: LocalLibraryPage(
              local: store,
              state: state,
              repository: store,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('local-library-novel-folder')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('local-library-manga-folder')),
          findsOneWidget,
        );
        expect(find.text('小说文件夹'), findsOneWidget);
        expect(find.text('漫画文件夹'), findsOneWidget);
        expect(find.text('已授权，点击可更换 · 同目录分卷自动合并'), findsOneWidget);
      },
    );
  });
}


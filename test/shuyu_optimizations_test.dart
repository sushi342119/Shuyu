import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/chapter_splitter.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_epub.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/novel_random_pick_section.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/reader_catalogue.dart';
import 'package:shuyu/reader_paged_view.dart';
import 'package:shuyu/reader_preferences.dart';

import 'support/offline_fixture.dart';
import 'support/pump_storage.dart';

class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getExternalStoragePath() async => path;
}

Future<String> _writeEpub(
  Directory dir,
  String name,
  Map<String, String> files,
) async {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile.noCompress(entry.key, bytes.length, bytes));
  }
  final encoded = ZipEncoder().encode(archive, modified: DateTime(2026));
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(encoded);
  return file.path;
}

Uint8List _buildMinimalMobi(String htmlText, {String title = '测试MOBI'}) {
  final textBytes = utf8.encode(htmlText);
  final titleBytes = utf8.encode(title);

  const mobiHeaderLen = 232;
  const fullNameOffset = 16 + mobiHeaderLen;
  final rec0Len = fullNameOffset + titleBytes.length;
  final rec0 = ByteData(rec0Len);
  rec0.setUint16(0, 1); // compression = 1 (uncompressed)
  rec0.setUint32(4, textBytes.length);
  rec0.setUint16(8, 1); // 1 text record
  rec0.setUint16(10, 4096);
  final rec0Bytes = rec0.buffer.asUint8List();
  rec0Bytes.setRange(16, 20, ascii.encode('MOBI'));
  rec0.setUint32(20, mobiHeaderLen);
  rec0.setUint32(24, 2); // book type
  rec0.setUint32(28, 65001); // UTF-8
  rec0.setUint32(84, fullNameOffset);
  rec0.setUint32(88, titleBytes.length);
  rec0Bytes.setRange(fullNameOffset, rec0Len, titleBytes);

  const headerSize = 78 + 16;
  const rec0Offset = headerSize;
  final rec1Offset = rec0Offset + rec0Bytes.length;
  final total = ByteData(rec1Offset + textBytes.length);
  final out = total.buffer.asUint8List();
  final pdbName = ascii.encode('test-mobi');
  out.setRange(0, pdbName.length, pdbName);
  out.setRange(60, 68, ascii.encode('BOOKMOBI'));
  total.setUint16(76, 2); // 2 records
  total.setUint32(78, rec0Offset);
  total.setUint32(86, rec1Offset);
  out.setRange(rec0Offset, rec1Offset, rec0Bytes);
  out.setRange(rec1Offset, out.length, textBytes);
  return out;
}

class _ShelfTestRepository extends DemoNovelRepository {
  _ShelfTestRepository(this.items);
  final Map<int, Novel> items;

  @override
  Future<Novel?> find(int id) async => items[id];

  @override
  Future<Novel> detail(Novel novel, {bool refresh = false}) async =>
      items[novel.id] ?? novel;
}

Novel _sampleNovel(int id, {int chapters = 3}) => Novel(
  id: id,
  title: '藏书样本 $id',
  author: '作者甲',
  genre: '奇幻',
  summary: '样本简介',
  colors: const [Color(0xFF3E4A59), Color(0xFF1F2630)],
  chapters: List.generate(
    chapters,
    (index) => NovelChapter(
      '第${index + 1}章 标题${index + 1}',
      '这里是第${index + 1}章的测试正文内容，用于验证目录与进度。' * 4,
      id: index + 1,
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EPUB 与 MOBI 目录切分与排序回归', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('shuyu-epub-mobi-');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('NCX 多卷各自重置 playOrder 且父卷共享首章路径时保留真实章节标题与顺序', () async {
      final path = await _writeEpub(tempDir, 'reset_playorder.epub', {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
        'OEBPS/content.opf': '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>多卷重置序号测试</dc:title>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="v1c1" href="v1c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="v1c2" href="v1c2.xhtml" media-type="application/xhtml+xml"/>
    <item id="v2c1" href="v2c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="v2c2" href="v2c2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="v1c1"/>
    <itemref idref="v1c2"/>
    <itemref idref="v2c1"/>
    <itemref idref="v2c2"/>
  </spine>
</package>''',
        'OEBPS/toc.ncx': '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="v1" playOrder="1">
      <navLabel><text>第一卷</text></navLabel>
      <content src="v1c1.xhtml"/>
      <navPoint id="v1-1" playOrder="1">
        <navLabel><text>第一卷 第一章</text></navLabel>
        <content src="v1c1.xhtml"/>
      </navPoint>
      <navPoint id="v1-2" playOrder="2">
        <navLabel><text>第一卷 第二章</text></navLabel>
        <content src="v1c2.xhtml"/>
      </navPoint>
    </navPoint>
    <navPoint id="v2" playOrder="1">
      <navLabel><text>第二卷</text></navLabel>
      <content src="v2c1.xhtml"/>
      <navPoint id="v2-1" playOrder="1">
        <navLabel><text>第二卷 第一章</text></navLabel>
        <content src="v2c1.xhtml"/>
      </navPoint>
      <navPoint id="v2-2" playOrder="2">
        <navLabel><text>第二卷 第二章</text></navLabel>
        <content src="v2c2.xhtml"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>''',
        for (final entry in [
          ('v1c1.xhtml', '第一卷第一章正文内容。'),
          ('v1c2.xhtml', '第一卷第二章正文内容。'),
          ('v2c1.xhtml', '第二卷第一章正文内容。'),
          ('v2c2.xhtml', '第二卷第二章正文内容。'),
        ])
          'OEBPS/${entry.$1}':
              '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>${entry.$2}</p></body></html>',
      });

      final pkg = await EpubPackage.open(path);
      try {
        expect(pkg.chapters.map((c) => c.title).toList(), [
          '第一卷 第一章',
          '第一卷 第二章',
          '第二卷 第一章',
          '第二卷 第二章',
        ]);
      } finally {
        await pkg.close();
      }
    });

    test('单 XHTML 文件内多锚点目录即使 NCX 顺序颠倒也能按 DOM 锚点准确拆章', () async {
      final path = await _writeEpub(tempDir, 'anchor_split.epub', {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
        'OEBPS/content.opf': '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>单文件锚点拆章</dc:title>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="all" href="all.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="all"/>
  </spine>
</package>''',
        'OEBPS/toc.ncx': '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n3" playOrder="1">
      <navLabel><text>第三章 终局</text></navLabel>
      <content src="all.xhtml#ch3"/>
    </navPoint>
    <navPoint id="n1" playOrder="2">
      <navLabel><text>第一章 启程</text></navLabel>
      <content src="all.xhtml#ch1"/>
    </navPoint>
    <navPoint id="n2" playOrder="3">
      <navLabel><text>第二章 中途</text></navLabel>
      <content src="all.xhtml#ch2"/>
    </navPoint>
  </navMap>
</ncx>''',
        'OEBPS/all.xhtml': '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<body>
  <h2 id="ch1">第一章 启程</h2>
  <p>这是第一章独立正文段落。</p>
  <h2 id="ch2">第二章 中途</h2>
  <p>这是第二章独立正文段落。</p>
  <h2 id="ch3">第三章 终局</h2>
  <p>这是第三章独立正文段落。</p>
</body>
</html>''',
      });

      final pkg = await EpubPackage.open(path);
      try {
        expect(pkg.chapters.map((c) => c.title).toList(), [
          '第一章 启程',
          '第二章 中途',
          '第三章 终局',
        ]);
        final ch0 = (await pkg.chapterBlocks(0)).map((b) => b.text).join('\n');
        final ch1 = (await pkg.chapterBlocks(1)).map((b) => b.text).join('\n');
        final ch2 = (await pkg.chapterBlocks(2)).map((b) => b.text).join('\n');
        expect(ch0, contains('第一章独立正文段落'));
        expect(ch0, isNot(contains('第二章独立正文段落')));
        expect(ch1, contains('第二章独立正文段落'));
        expect(ch2, contains('第三章独立正文段落'));
      } finally {
        await pkg.close();
      }
    });

    test('无 OPF 的宽松 EPUB 归档对前导零章节名保持确定性自然序', () async {
      final path = await _writeEpub(tempDir, 'no_opf_order.epub', {
        '02.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第2章</title></head><body><p>正文二</p></body></html>',
        '1.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第1章A</title></head><body><p>正文一A</p></body></html>',
        '01.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第1章B</title></head><body><p>正文一B</p></body></html>',
        '10.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第10章</title></head><body><p>正文十</p></body></html>',
      });

      final pkg = await EpubPackage.open(path, lenient: true);
      try {
        expect(pkg.chapters.map((c) => c.title).toList(), [
          '第1章A',
          '第1章B',
          '第2章',
          '第10章',
        ]);
      } finally {
        await pkg.close();
      }
    });

    test('MOBI 相邻块级标签自动换行，章节标题不再与正文粘连成单章', () {
      const html =
          '<html><body>'
          '<div>第一章 风起青萍</div>'
          '<div>这一段是第一章的正文内容，长度足够建立独立章节证据。</div>'
          '<div>第二章 夜半钟声</div>'
          '<div>这一段是第二章的正文内容，同样长度充足且独立成段。</div>'
          '</body></html>';
      final mobi = extractMobiBook(_buildMinimalMobi(html));
      expect(mobi.title, '测试MOBI');
      expect(mobi.chapters.map((c) => c.title).toList(), [
        '第一章 风起青萍',
        '第二章 夜半钟声',
      ]);
      final firstBody = mobi.text
          .substring(
            mobi.chapters[0].offset,
            mobi.chapters[0].offset + mobi.chapters[0].length,
          )
          .trim();
      expect(firstBody, '这一段是第一章的正文内容，长度足够建立独立章节证据。');
    });
  });

  group('大体积 TXT 字节切片直读与自定义书名检索', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previousPaths = PathProviderPlatform.instance;
    late Directory root;
    late LocalLibraryStore store;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      root = await Directory.systemTemp.createTemp('shuyu-slice-test-');
      PathProviderPlatform.instance = _TempPaths(root.path);
      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      store = await LocalLibraryStore.load();
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      store.dispose();
      TagStore.resetForTesting();
      PathProviderPlatform.instance = previousPaths;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await root.delete(recursive: true);
    });

    test('> 64 KiB UTF-8 小说通过字节偏移精准读取各章并支持重命名与原文件名搜索', () async {
      final appFolder = await store.appFolderPath;
      final txtFile = File('$appFolder/剑来珍藏版.txt');
      final sb = StringBuffer();
      for (var i = 1; i <= 40; i++) {
        sb.writeln('第$i章 远游记😀_$i');
        sb.writeln('${'山巅云海翻涌，少年负剑远行。' * 60}【章尾标记_$i】');
      }
      await txtFile.writeAsString(sb.toString());
      expect(await txtFile.length(), greaterThan(70 * 1024));

      await _writeEpub(Directory(appFolder), '原文件名诡秘.epub', {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
        'OEBPS/content.opf': '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>内部元数据书名</dc:title>
  </metadata>
  <manifest>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>''',
        'OEBPS/c1.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>正文</p></body></html>',
      });

      final scan = await store.scanAppFolder();
      expect(scan.added, 2);
      final txtBook = store.books.firstWhere(
        (b) => b.kind == LocalBookKind.txt,
      );
      final epubBook = store.books.firstWhere(
        (b) => b.kind == LocalBookKind.epub,
      );
      final chapters = await store.chapters(txtBook.id);
      expect(chapters, hasLength(40));

      // Verify byte-slice direct read and subsequent LRU slice cache hit.
      final ch1 = await store.chapterContent(txtBook.id, chapters[0]);
      final ch25 = await store.chapterContent(txtBook.id, chapters[24]);
      final ch25Cached = await store.chapterContent(
        txtBook.id,
        chapters[24],
      );
      final ch40 = await store.chapterContent(txtBook.id, chapters[39]);
      expect(ch1, contains('【章尾标记_1】'));
      expect(ch1, isNot(contains('【章尾标记_2】')));
      expect(ch25, contains('【章尾标记_25】'));
      expect(ch25Cached, ch25);
      expect(ch40, contains('【章尾标记_40】'));

      // Verify fileName search when metadata title differs, plus customTitle search.
      expect(
        (await store.search('原文件名诡秘')).map((n) => n.id),
        contains(epubBook.id),
      );
      await store.editBookFile(
        txtBook.id,
        title: '骊珠洞天手札',
        author: '烽火戏诸侯',
      );
      expect((await store.search('骊珠洞天')).map((n) => n.id), [txtBook.id]);
    });
  });

  group('目录正倒序、新矢量图标、千本速滑与筛选增强 UI', () {
    setUp(() {
      TagStore.resetForTesting();
    });

    tearDown(() {
      TagStore.resetForTesting();
    });

    testWidgets('新矢量图标映射齐备且 GlassIconButton 在 2x 字号下保持正圆不变形', (
      tester,
    ) async {
      expect(ArchiveIconSymbols.legacy[CupertinoIcons.tag], ArchiveSymbol.tag);
      expect(
        ArchiveIconSymbols.legacy[CupertinoIcons.chart_bar],
        ArchiveSymbol.chart,
      );
      expect(
        ArchiveIconSymbols.legacy[CupertinoIcons.paintbrush],
        ArchiveSymbol.palette,
      );
      expect(
        ArchiveIconSymbols.legacy[CupertinoIcons.circle_fill],
        ArchiveSymbol.dot,
      );
      expect(
        ArchiveIconSymbols.legacy[CupertinoIcons.shuffle],
        ArchiveSymbol.shuffle,
      );
      expect(
        ArchiveIconSymbols.legacy[CupertinoIcons.arrow_up_arrow_down],
        ArchiveSymbol.sort,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    key: const ValueKey('scaled-glass-btn'),
                    icon: CupertinoIcons.arrow_up_arrow_down,
                    label: '切换倒序',
                    onPressed: () {},
                  ),
                  Wrap(
                    children: [
                      for (final symbol in [
                        ArchiveSymbol.tag,
                        ArchiveSymbol.chart,
                        ArchiveSymbol.palette,
                        ArchiveSymbol.dot,
                        ArchiveSymbol.shuffle,
                        ArchiveSymbol.sort,
                      ])
                        ArchiveIcon.symbol(symbol, size: 20),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final size = tester.getSize(
        find.byKey(const ValueKey('scaled-glass-btn')),
      );
      expect(size.width, closeTo(size.height, 0.01));
      expect(size.width, greaterThanOrEqualTo(40));
    });

    testWidgets('ReaderCatalogue 与 DetailPage 支持目录正序 / 倒序一键切换', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpStorage(tester, TagStore.load);
      final state = await pumpStorage(tester, LibraryState.load);
      addTearDown(state.dispose);
      final novel = _sampleNovel(801, chapters: 4);
      final repo = _ShelfTestRepository({novel.id: novel});

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              height: 640,
              child: ReaderCatalogue(novel: novel, currentChapter: 0),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('reader-chapter-0'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('reader-chapter-3'))).dy,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('reader-catalogue-sort-order')),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('reader-chapter-3'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('reader-chapter-0'))).dy,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: DetailPage(novel: novel, state: state, repository: repo),
        ),
      );
      await tester.pumpAndSettle();

      final sortFinder = find.byKey(const ValueKey('detail-directory-sort'));
      await tester.ensureVisible(sortFinder);
      await tester.pumpAndSettle();
      await tester.tap(sortFinder);
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('detail-chapter-3'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('detail-chapter-0'))).dy,
        ),
      );
    });

    testWidgets('ShelfPage 在多书场景展示快速定位条并支持批量标为已读', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final books = [for (var i = 1; i <= 45; i++) _sampleNovel(1000 + i)];
      SharedPreferences.setMockInitialValues({
        'shelf': [for (final b in books) '${b.id}'],
      });
      await pumpStorage(tester, TagStore.load);
      final state = await pumpStorage(tester, LibraryState.load);
      addTearDown(state.dispose);

      final repo = _ShelfTestRepository({for (final b in books) b.id: b});

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: ShelfPage(books: books, state: state, repository: repo),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));

      // >= 40 books renders the right-edge fast scroller.
      expect(find.byKey(const ValueKey('shelf-fast-scroller')), findsOneWidget);

      // Long-press the first visible book to enter multi-selection and mark finished.
      final targetBook = books.first;
      final selectFinder = find.byKey(ValueKey('shelf-select-${targetBook.id}'));
      await tester.longPress(selectFinder);
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const ValueKey('shelf-batch-finish')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shelf-batch-finish')));
      await pumpUntil(tester, () => state.finishedReading(targetBook));

      expect(state.finishedReading(targetBook), isTrue);
    });

    testWidgets('首页随机抽书支持“仅未读”过滤，馆藏概览支持“未设标签”一键筛选', (
      tester,
    ) async {
      final readBook = _sampleNovel(2001, chapters: 2);
      final unreadBook1 = _sampleNovel(2002, chapters: 2);
      final unreadBook2 = _sampleNovel(2003, chapters: 2);
      final allBooks = [readBook, unreadBook1, unreadBook2];
      SharedPreferences.setMockInitialValues({
        'shelf': [for (final b in allBooks) '${b.id}'],
      });
      await pumpStorage(tester, TagStore.load);
      final state = await pumpStorage(tester, LibraryState.load);
      addTearDown(state.dispose);

      await pumpStorage(
        tester,
        () => state.savePosition(
          novel: readBook,
          chapter: 1,
          offset: 1,
          maximum: 1,
          width: 390,
        ),
      );
      expect(state.finishedReading(readBook), isTrue);
      expect(state.finishedReading(unreadBook1), isFalse);

      final tagId = await pumpStorage(
        tester,
        () => TagStore.shared.createTag('仙侠'),
      );
      await pumpStorage(
        tester,
        () => TagStore.shared.setTagsForBook(readBook.id, [tagId]),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  NovelRandomPickSection(
                    books: allBooks,
                    state: state,
                    onOpenDetail: (_) {},
                  ),
                  DiscoverLibraryOverview(
                    books: allBooks,
                    state: state,
                    repository: _ShelfTestRepository({
                      for (final b in allBooks) b.id: b,
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await pumpUntil(tester, () => find.text('抽阅一本').evaluate().isNotEmpty);

      // Toggle '仅未读' in random pick and verify drawing picks only an unread book.
      final unreadChip = find.byKey(const ValueKey('random-pick-unread-only'));
      expect(unreadChip, findsOneWidget);
      await tester.tap(unreadChip);
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('抽阅一本'));
      await tester.pumpAndSettle();
      expect(find.text(readBook.title), findsNothing);
      expect(
        find.text(unreadBook1.title).evaluate().isNotEmpty ||
            find.text(unreadBook2.title).evaluate().isNotEmpty,
        isTrue,
      );

      // Tap '未设标签' row in DiscoverLibraryOverview to toggle untaggedOnly filter.
      final untaggedRow = find.byKey(
        const ValueKey('discover-tag-stat-untagged'),
      );
      expect(untaggedRow, findsOneWidget);
      await tester.ensureVisible(untaggedRow);
      await tester.pumpAndSettle();
      await tester.tap(untaggedRow);
      await tester.pump(const Duration(milliseconds: 200));
      expect(LibraryFilter.shared.untaggedOnly, isTrue);
    });

    test('headingOrdinal 兼容卷章同行标题，混合章/节序号续接正常工作', () {
      expect(headingOrdinal('第12章 风起'), 12);
      expect(headingOrdinal('第十三回 伏笔'), 13);
      expect(headingOrdinal('第一卷 第13节 插曲'), 13);
      expect(headingOrdinal('第二卷 第十四回 转折'), 14);
    });
  });

  group('Issue #11 阅读界面底部重复重叠与上下状态栏分离回归', () {
    Future<void> flushReader(WidgetTester tester, {int rounds = 12}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 12)),
        );
        await tester.pump(const Duration(milliseconds: 45));
      }
      await tester.pump(const Duration(milliseconds: 160));
    }

    testWidgets('横排翻页隐藏控件时不重复绘制底部栏，长标题与页码时间左右分栏不重叠且随翻页更新', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
      final state = await pumpStorage(tester, LibraryState.load);
      addTearDown(state.dispose);
      await tester.runAsync(
        () => state.setReaderPreferences(
          state.readerPreferences.copyWith(
            mode: ReaderMode.paged,
            tapPaging: true,
            pageEffect: ReaderPageEffect.none,
          ),
        ),
      );

      final repository = OfflineFixtureRepository();
      final paragraphs = List.generate(
        60,
        (i) => '第 $i 段 · 横排翻页底栏去重与页码刷新测试正文内容。' * 3,
      );
      repository.books[91] = offlineFixtureBook(91).withChapters([
        NovelChapter(
          '第四十六章 关于长章节标题在横排翻页模式下与页码进度时间并排不重叠的回归测试',
          paragraphs.join('\n\n'),
          id: 91001,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NovelScrollBehavior(),
          theme: novelTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 36, bottom: 24),
              viewPadding: const EdgeInsets.only(top: 36, bottom: 24),
            ),
            child: child!,
          ),
          home: ReaderPage(
            novel: repository.books[91]!,
            state: state,
            repository: repository,
            initialChapter: 0,
          ),
        ),
      );
      await flushReader(tester);

      final pagedView = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(pagedView.controller.ready, isTrue);
      expect(pagedView.controller.pageCount, greaterThan(2));

      // Tap center to hide controls and enter immersive reading (chrome == 0).
      await tester.tapAt(const Offset(210, 450));
      await flushReader(tester, rounds: 6);

      // Paged view's own bottom location must be suppressed so only one footer renders.
      expect(find.byKey(const ValueKey('reader-bottom-location')), findsNothing);
      // Top safe paper mask stays off in paginated mode so page-turn sheets aren't clipped.
      expect(find.byKey(const ValueKey('reader-top-safe-band')), findsNothing);

      final statusRow = find.byKey(const ValueKey('reader-status-line'));
      expect(statusRow, findsOneWidget);

      final statusTexts = find.descendant(
        of: statusRow,
        matching: find.byType(Text),
      );
      expect(statusTexts, findsNWidgets(2));
      final leftRect = tester.getRect(statusTexts.at(0));
      final rightRect = tester.getRect(statusTexts.at(1));
      expect(leftRect.right, lessThanOrEqualTo(rightRect.left - 8));

      final pageOneTrailing = tester.widget<Text>(statusTexts.at(1)).data ?? '';
      expect(pageOneTrailing, contains('1/${pagedView.controller.pageCount}页'));

      // Turn to page 2 by tapping right tap-paging zone and verify footer updates.
      await tester.tapAt(const Offset(390, 450));
      await flushReader(tester, rounds: 6);
      final pageTwoTrailing = tester.widget<Text>(statusTexts.at(1)).data ?? '';
      expect(pageTwoTrailing, contains('2/${pagedView.controller.pageCount}页'));
    });

    testWidgets('上下滚动模式下顶部状态栏与底部信息带均有纸色隔离层且不引入模糊开销', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
      final state = await pumpStorage(tester, LibraryState.load);
      addTearDown(state.dispose);

      final repository = OfflineFixtureRepository();
      final paragraphs = List.generate(
        80,
        (i) => '第 $i 段 · 上下滚动顶部系统状态栏与底部章节时间隔离测试。' * 3,
      );
      repository.books[92] = offlineFixtureBook(92).withChapters([
        NovelChapter('第四十六章 滚动模式隔离测试', paragraphs.join('\n\n'), id: 92001),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NovelScrollBehavior(),
          theme: novelTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 36, bottom: 24),
              viewPadding: const EdgeInsets.only(top: 36, bottom: 24),
            ),
            child: child!,
          ),
          home: ReaderPage(
            novel: repository.books[92]!,
            state: state,
            repository: repository,
            initialChapter: 0,
          ),
        ),
      );
      await flushReader(tester);

      // Controls initially shown: both top and bottom paper scrims protect controls,
      // while the focus-only status band is hidden.
      expect(find.byKey(const ValueKey('reader-top-scrim')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-bottom-scrim')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-status-band')), findsNothing);

      // Hide controls -> immersive scroll reading.
      await tester.tapAt(const Offset(210, 450));
      await flushReader(tester, rounds: 6);

      expect(find.byKey(const ValueKey('reader-top-scrim')), findsNothing);
      expect(find.byKey(const ValueKey('reader-bottom-scrim')), findsNothing);

      final topBand = find.byKey(const ValueKey('reader-top-safe-band'));
      final bottomBand = find.byKey(const ValueKey('reader-status-band'));
      expect(topBand, findsOneWidget);
      expect(bottomBand, findsOneWidget);
      expect(tester.getSize(topBand).height, greaterThanOrEqualTo(36));
      expect(tester.getSize(bottomBand).height, greaterThanOrEqualTo(50));

      // Zero ProgressiveBlur during immersive reading preserves 120Hz scroll budget.
      expect(find.byType(ProgressiveBlur), findsNothing);
    });
  });
}

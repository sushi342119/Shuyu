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
import 'package:shuyu/book_import_limits.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/legacy_cover.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_comic.dart';
import 'package:shuyu/local_epub.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/local_platform.dart';
import 'package:shuyu/portable_book_prepare.dart';

class _ComicTestPaths extends PathProviderPlatform {
  _ComicTestPaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getExternalStoragePath() async => root;
}

Future<Uint8List> _solidPngBytes({
  int width = 60,
  int height = 90,
  Color color = const Color(0xFF3E6B89),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
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

Uint8List _buildZipBytes(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeTempDir() async {
    final dir = await Directory.systemTemp.createTemp('shuyu_comic_test_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  group('自然序与中文话数排序', () {
    test('阿拉伯数字与全角数字按数值升序排列', () {
      final list = ['page10.jpg', 'page2.jpg', 'page1.jpg', 'page２０.jpg'];
      list.sort(compareComicNaturalOrder);
      expect(list, ['page1.jpg', 'page2.jpg', 'page10.jpg', 'page２０.jpg']);
    });

    test('中文话数章节名按真实话数排序', () {
      final chapters = ['第十话', '第二话', '第一话', '第二十一话', '第十二话'];
      chapters.sort(compareComicNaturalOrder);
      expect(chapters, ['第一话', '第二话', '第十话', '第十二话', '第二十一话']);
    });

    test('路径按目录层级逐段自然排序', () {
      final paths = [
        '第10话/002.png',
        '第2话/010.png',
        '第2话/002.png',
        '第1话/001.png',
      ];
      paths.sort(compareComicEntryPaths);
      expect(paths, [
        '第1话/001.png',
        '第2话/002.png',
        '第2话/010.png',
        '第10话/002.png',
      ]);
    });
  });

  group('ComicInfo.xml 与归档格式校验', () {
    test('解析标题、系列、作者、阅读方向、封面页与书签页', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<ComicInfo>
  <Series>孤独摇滚</Series>
  <Number>3</Number>
  <Writer>滨路晶</Writer>
  <Summary>结束乐队的日常与演出。</Summary>
  <Manga>YesAndRightToLeft</Manga>
  <Genre>音乐, 日常</Genre>
  <Pages>
    <Page Image="0" Type="InnerCover" />
    <Page Image="1" Type="FrontCover" />
    <Page Image="4" Bookmark="Live 开场" />
  </Pages>
</ComicInfo>
''';
      final meta = ComicInfoMetadata.tryParseXml(xml);
      expect(meta, isNotNull);
      expect(meta!.series, '孤独摇滚');
      expect(meta.displayTitle, contains('孤独摇滚'));
      expect(meta.writer, '滨路晶');
      expect(meta.isMangaRtl, isTrue);
      expect(meta.frontCoverImageIndex, 1);
      expect(meta.pageBookmarks, {4: 'Live 开场'});
      expect(meta.genre, contains('音乐'));
      expect(meta.genre, contains('日常'));
    });

    test('RAR/CBR 与 7z/CB7 魔数抛出明确格式提示', () {
      final rarBytes = Uint8List.fromList([
        0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0x00,
      ]);
      final sevenZBytes = Uint8List.fromList([
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04,
      ]);
      expect(
        () => checkComicArchiveMagicBytes(rarBytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('RAR'),
          ),
        ),
      );
      expect(
        () => checkComicArchiveMagicBytes(sevenZBytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('7z'),
          ),
        ),
      );
    });

    test('导入后缀支持 .cbz / .zip 并对 .cbr / .cb7 返回友好提示', () async {
      expect(supportsBookImport('vol01.cbz'), isTrue);
      expect(supportsBookImport('vol01.zip'), isTrue);
      expect(supportsBookImport('vol01.cbr'), isFalse);
      expect(isUnsupportedComicArchiveFileName('vol01.cbr'), isTrue);
      expect(isUnsupportedComicArchiveFileName('vol01.cb7'), isTrue);
      expect(
        () => PortableBookPreparer.prepareFile('vol01.cbr', 'vol01.cbr'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CBR'),
          ),
        ),
      );
      expect(
        () => PortableBookPreparer.prepareFile('vol01.cb7', 'vol01.cb7'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CB7'),
          ),
        ),
      );
    });

    test('区分图片漫画 ZIP 与非漫画多书打包 ZIP', () async {
      final page = await _solidPngBytes();
      final comicZip = _buildZipBytes({
        '001.png': page,
        '002.png': page,
        'ComicInfo.xml': utf8.encode('<ComicInfo><Title>短篇</Title></ComicInfo>'),
      });
      final bundleZip = _buildZipBytes({
        '小说A.txt': utf8.encode('第一章 正文\n${'内容段落。' * 8000}'),
        'cover.png': page,
      });
      expect(isComicZipBytes(comicZip), isTrue);
      expect(isComicZipBytes(bundleZip), isFalse);
    });

    test('ComicArchivePackage 读取单话与多话子目录 CBZ 并忽略 __MACOSX', () async {
      final dir = await makeTempDir();
      final p1 = await _solidPngBytes(color: const Color(0xFFAA3344));
      final p2 = await _solidPngBytes(color: const Color(0xFF33AA55));
      final p3 = await _solidPngBytes(color: const Color(0xFF3355AA));
      final cbzBytes = _buildZipBytes({
        '__MACOSX/._001.png': [1, 2, 3],
        '第2话 启程/001.png': p3,
        '第1话 相遇/002.png': p2,
        '第1话 相遇/001.png': p1,
        'ComicInfo.xml': utf8.encode(
          '<ComicInfo><Title>葬送的旅途</Title><Writer>山田</Writer></ComicInfo>',
        ),
      });
      final cbzFile = File('${dir.path}/frieren.cbz');
      await cbzFile.writeAsBytes(cbzBytes);

      final pkg = await ComicArchivePackage.openFile(cbzFile.path);
      try {
        expect(pkg.pageCount, 3);
        expect(pkg.title, '葬送的旅途');
        expect(pkg.author, '山田');
        expect(pkg.chapters.map((c) => c.title).toList(), ['第1话 相遇', '第2话 启程']);
        expect(pkg.chapters[0].startPage, 0);
        expect(pkg.chapters[0].pageCount, 2);
        expect(pkg.chapters[1].startPage, 2);
        expect(pkg.chapters[1].pageCount, 1);
        expect(pkg.readPageSync(0), p1);
        expect(pkg.readPageSync(1), p2);
        expect(pkg.readPageSync(2), p3);
      } finally {
        await pkg.close();
      }
    });
  });

  group('图片文件夹漫画识别与分组', () {
    test('自动聚合单话目录、多话连载目录、分类父目录并忽略小说散图', () {
      final scanned = <ScannedFolderEntry>[
        // 根目录旁的小说及散落单张封面：必须忽略
        const ScannedFolderEntry(
          uri: 'u://cover',
          name: 'cover.jpg',
          relPath: 'cover.jpg',
          size: 100,
          modifiedMs: 10,
        ),
        // 分类目录 "漫画" 下两部独立单卷漫画（不应合并成一部叫 "漫画" 的书）
        for (var i = 1; i <= 3; i++)
          ScannedFolderEntry(
            uri: 'u://bocchi/$i',
            name: '00$i.jpg',
            relPath: '漫画/孤独摇滚/00$i.jpg',
            size: 200,
            modifiedMs: 20,
          ),
        for (var i = 1; i <= 3; i++)
          ScannedFolderEntry(
            uri: 'u://meshi/$i',
            name: '00$i.jpg',
            relPath: '漫画/迷宫饭/00$i.jpg',
            size: 200,
            modifiedMs: 30,
          ),
        // 多话连载目录（子目录以 第X话 命名 -> 聚合成一部多话漫画）
        for (var i = 1; i <= 3; i++)
          ScannedFolderEntry(
            uri: 'u://op/ch1/$i',
            name: '0$i.png',
            relPath: '漫画/海贼/第1话/0$i.png',
            size: 300,
            modifiedMs: 40,
          ),
        for (var i = 1; i <= 3; i++)
          ScannedFolderEntry(
            uri: 'u://op/ch2/$i',
            name: '0$i.png',
            relPath: '漫画/海贼/第2话/0$i.png',
            size: 300,
            modifiedMs: 50,
          ),
      ];
      final manifests = groupScannedComicFolders(
        entries: scanned,
        rootKeyPrefix: 'test_root',
        rootFolderUri: 'u://root',
        rootDisplayName: '书库',
        nonImageRelPaths: const ['小说.txt'],
      );
      final titles = manifests.map((m) => m.title).toList();
      expect(titles, containsAll(['孤独摇滚', '迷宫饭', '海贼']));
      expect(titles, isNot(contains('漫画')));
      expect(titles, isNot(contains('书库')));

      final multi = manifests.firstWhere((m) => m.title == '海贼');
      expect(multi.pages, hasLength(6));
      expect(multi.chapters.map((c) => c.title).toList(), ['第1话', '第2话']);
    });
  });

  group('LocalLibraryStore 漫画导入、封面与漫画 EPUB 检测', () {
    const tree = 'content://test/tree/comics';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory root;
    late PathProviderPlatform previousPaths;

    setUp(() async {
      root = await makeTempDir();
      previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _ComicTestPaths(root.path);
      SharedPreferences.setMockInitialValues({'local_library_folder': tree});
      await TagStore.load();
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
      PathProviderPlatform.instance = previousPaths;
    });

    test('SAF 扫描同时导入 CBZ 归档与图片文件夹漫画，并提取本地封面字节', () async {
      final p1 = await _solidPngBytes(color: const Color(0xFFD9534F));
      final p2 = await _solidPngBytes(color: const Color(0xFF5BC0DE));
      final p3 = await _solidPngBytes(color: const Color(0xFF5CB85C));
      final cbzBytes = _buildZipBytes({
        '01.png': p1,
        '02.png': p2,
        'ComicInfo.xml': utf8.encode(
          '<ComicInfo><Title>水星领航员</Title><Writer>天野梢</Writer></ComicInfo>',
        ),
      });

      const cbzUri = '$tree/document/aria.cbz';
      final folderUris = <String, Uint8List>{
        '$tree/document/yotsuba/1': p1,
        '$tree/document/yotsuba/2': p2,
        '$tree/document/yotsuba/3': p3,
      };

      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
        switch (call.method) {
          case 'scanLocalFolder':
            return {
              'complete': true,
              'rootName': 'Comics',
              'dirUris': {'四叶妹妹': '$tree/document/yotsuba'},
              'entries': [
                {
                  'uri': cbzUri,
                  'name': 'aria.cbz',
                  'relPath': 'aria.cbz',
                  'size': cbzBytes.length,
                  'modified': 1000,
                },
                {
                  'uri': '$tree/document/yotsuba/1',
                  'name': '001.png',
                  'relPath': '四叶妹妹/001.png',
                  'size': p1.length,
                  'modified': 1100,
                },
                {
                  'uri': '$tree/document/yotsuba/2',
                  'name': '002.png',
                  'relPath': '四叶妹妹/002.png',
                  'size': p2.length,
                  'modified': 1100,
                },
                {
                  'uri': '$tree/document/yotsuba/3',
                  'name': '003.png',
                  'relPath': '四叶妹妹/003.png',
                  'size': p3.length,
                  'modified': 1100,
                },
              ],
            };
          case 'copyDocumentToFile':
            final args = call.arguments as Map;
            expect(args['docUri'], cbzUri);
            final dest = args['destPath'] as String;
            await File(dest).writeAsBytes(cbzBytes);
            return dest;
          case 'readLocalBytes':
            final args = call.arguments as Map;
            final uri = args['docUri'] as String;
            return folderUris[uri];
        }
        throw MissingPluginException(call.method);
      });

      final store = await LocalLibraryStore.load();
      addTearDown(store.dispose);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);

      final result = await store.scan();
      expect(result.added, 2);
      expect(result.failures, isEmpty);
      expect(store.books, hasLength(2));

      final aria = store.books.firstWhere((b) => b.title == '水星领航员');
      final yotsuba = store.books.firstWhere((b) => b.title == '四叶妹妹');
      expect(aria.kind, LocalBookKind.comic);
      expect(aria.isComicFolder, isFalse);
      expect(aria.author, '天野梢');
      expect(aria.pageCount, 2);

      expect(yotsuba.kind, LocalBookKind.comic);
      expect(yotsuba.isComicFolder, isTrue);
      expect(yotsuba.pageCount, 3);

      expect(LegacyCover.hasLocalCover(aria.id), isTrue);
      final coverBytes = await LegacyCover.bytes(aria.id);
      expect(coverBytes, isNotNull);
      expect(coverBytes, isNotEmpty);

      final folderCover = await LegacyCover.bytes(yotsuba.id);
      expect(folderCover, p1);
    });

    test('云盘导入 CBZ 归档落盘到应用书库并可按页读取', () async {
      final p1 = await _solidPngBytes(color: const Color(0xFF6644AA));
      final p2 = await _solidPngBytes(color: const Color(0xFF44AA88));
      final cbzBytes = _buildZipBytes({
        '001.png': p1,
        '002.png': p2,
      });
      final cbzTemp = File('${root.path}/nichijou.cbz');
      await cbzTemp.writeAsBytes(cbzBytes);

      final prepared = await PortableBookPreparer.prepareFile(
        '日常 - 新井圭一.cbz',
        cbzTemp.path,
      );
      expect(prepared.single.cbzBytes, isNotNull);

      final store = await LocalLibraryStore.load();
      addTearDown(store.dispose);
      final novel = await store.importCloudFile('日常 - 新井圭一.cbz', cbzTemp.path);
      final book = store.bookFor(novel.id)!;
      expect(book.kind, LocalBookKind.comic);
      expect(book.pageCount, 2);
      expect(await store.readComicArchivePage(book.id, 0), p1);
      expect(await store.readComicArchivePage(book.id, 1), p2);
    });

    test('固定版式 / 纯图 EPUB 自动识别为漫画 EPUB 且提取图片页与 RTL 方向', () async {
      final p1 = await _solidPngBytes(color: const Color(0xFF224466));
      final p2 = await _solidPngBytes(color: const Color(0xFF664422));
      final epubBytes = _buildZipBytes({
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
    <dc:title>摇曳露营 第1卷</dc:title>
    <dc:creator>あfろ</dc:creator>
    <meta property="rendition:layout">pre-paginated</meta>
  </metadata>
  <manifest>
    <item id="p1" href="xhtml/p1.xhtml" media-type="application/xhtml+xml"/>
    <item id="p2" href="xhtml/p2.xhtml" media-type="application/xhtml+xml"/>
    <item id="img1" href="images/001.png" media-type="image/png"/>
    <item id="img2" href="images/002.png" media-type="image/png"/>
  </manifest>
  <spine page-progression-direction="rtl">
    <itemref idref="p1"/>
    <itemref idref="p2"/>
  </spine>
</package>'''),
        'OEBPS/xhtml/p1.xhtml': utf8.encode(
          '<html><body><svg><image xlink:href="../images/001.png"/></svg></body></html>',
        ),
        'OEBPS/xhtml/p2.xhtml': utf8.encode(
          '<html><body><img src="../images/002.png"/></body></html>',
        ),
        'OEBPS/images/001.png': p1,
        'OEBPS/images/002.png': p2,
      });

      final epubFile = File('${root.path}/yurucamp.epub');
      await epubFile.writeAsBytes(epubBytes);
      final pkg = await EpubPackage.open(epubFile.path);
      try {
        expect(pkg.isComicLayout, isTrue);
        expect(pkg.isRtlProgression, isTrue);
        final extracted = await pkg.extractMangaPages();
        expect(extracted.pages, ['OEBPS/images/001.png', 'OEBPS/images/002.png']);
        expect(extracted.pageToSpineChapter, [0, 1]);
      } finally {
        await pkg.close();
      }

      final store = await LocalLibraryStore.load();
      addTearDown(store.dispose);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);

      final novel = await store.importCloudFile('yurucamp.epub', epubFile.path);
      final book = store.bookFor(novel.id)!;
      expect(book.kind, LocalBookKind.epub);
      expect(book.isComicEpub, isTrue);
      expect(book.isRtlProgression, isTrue);
      expect(state.isMangaModeForBook(book.id, book: book), isTrue);
    });
  });
}

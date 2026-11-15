import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/archive_design.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/gbk_codec.dart';
import 'package:shuyu/library_backup.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/offline_cache.dart';
import 'package:shuyu/offline_repository.dart';
import 'package:shuyu/reader_content.dart';
import 'package:shuyu/reader_purification.dart';
import 'package:shuyu/sources/book_source.dart';
import 'package:shuyu/sources/book_source_store.dart';
import 'package:shuyu/sources/chapter_normalizer.dart';
import 'package:shuyu/sources/network_url_safety.dart';
import 'package:shuyu/sources/online_book_origins.dart';
import 'package:shuyu/sources/rule_engine.dart';
import 'package:shuyu/sources/source_http.dart';
import 'package:shuyu/sources/source_image_cache.dart';
import 'package:shuyu/sources/source_repository.dart';

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getExternalStoragePath() async => root;
}

/// Minimal valid 1x1 PNG raster buffer for magic-byte & disk-cache verification.
final Uint8List _validPng1x1 = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, // IDAT
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND
  0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NetworkUrlSafety.allowLoopbackForTesting = false;
    NetworkUrlSafety.debugDnsLookup = null;
  });

  group('NetworkUrlSafety 跳转拆包与 SSRF 防护', () {
    test('自动拆包酷安跳转链接、阅读 legado:// 深链与分享文本尾部标点', () {
      const coolapkUrl =
          'https://www.coolapk.com/link?url=https%3A%2F%2Fshuyuan.nyasama.net%2Fshuyuan%2Ff7fc76e0da51eec18490ea226ac43ba3.json';
      expect(
        NetworkUrlSafety.unwrapImportSourceUrl(coolapkUrl),
        'https://shuyuan.nyasama.net/shuyuan/f7fc76e0da51eec18490ea226ac43ba3.json',
      );

      const legadoLink =
          'legado://import/bookSource?src=https%3A%2F%2Fexample.org%2Fsources%2Fnovel.json';
      expect(
        NetworkUrlSafety.unwrapImportSourceUrl(legadoLink),
        'https://example.org/sources/novel.json',
      );

      const shareParagraph =
          '给你分享一套超稳的小说书源：https://link.zhihu.com/?target=https%3A%2F%2Fcdn.example.org%2Fs.json，复制即可导入！';
      expect(
        NetworkUrlSafety.unwrapImportSourceUrl(shareParagraph),
        'https://cdn.example.org/s.json',
      );
    });

    test('拦截非 HTTP 协议、回环/十六进制 IP 与 DNS 重绑定内网地址', () async {
      for (final unsafe in const [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'http://localhost:8080/api',
        'http://127.0.0.1:9000/secret',
        'http://0x7f000001/secret',
        'http://[::1]/secret',
      ]) {
        expect(
          () => NetworkUrlSafety.parsePublicHttpUrl(unsafe),
          throwsFormatException,
          reason: 'Should reject $unsafe',
        );
      }

      final privateLanA = InternetAddress.fromRawAddress(
        Uint8List.fromList([192, 168, 1, 25]),
      );
      final privateLanB = InternetAddress.fromRawAddress(
        Uint8List.fromList([10, 0, 0, 8]),
      );
      final linkLocalMetadata = InternetAddress.fromRawAddress(
        Uint8List.fromList([169, 254, 169, 254]),
      );

      for (final reboundIp in [privateLanA, privateLanB, linkLocalMetadata]) {
        NetworkUrlSafety.debugDnsLookup = (_) async => [reboundIp];
        await expectLater(
          NetworkUrlSafety.ensureSafeDestination(
            Uri.parse('https://rebind-check.example.org/feed.json'),
          ),
          throwsFormatException,
        );
      }

      final publicAddr = InternetAddress.fromRawAddress(
        Uint8List.fromList([93, 184, 216, 34]),
      );
      NetworkUrlSafety.debugDnsLookup = (_) async => [publicAddr];
      final verified = await NetworkUrlSafety.ensureSafeDestination(
        Uri.parse('https://rebind-check.example.org/feed.json'),
      );
      expect(verified.host, 'rebind-check.example.org');
    });
  });

  group('书籍 ID 分段、档案编号与信任边界', () {
    test('0x20000000..0x3fffffff 独立为在线书源号段且互不污染文库/本地段', () {
      expect(isWenkuNovelId(1234), isTrue);
      expect(isSourceNovelId(1234), isFalse);

      expect(isSourceNovelId(sourceNovelIdBase), isTrue);
      expect(isSourceNovelId(sourceNovelIdMax), isTrue);
      expect(isWenkuNovelId(sourceNovelIdBase), isFalse);
      expect(isLocalNovelId(sourceNovelIdBase), isFalse);

      expect(ArchiveDesign.fileCode(sourceNovelIdBase + 42), 'SR-00042');
      expect(ArchiveDesign.isBookCode('SR-00042'), isTrue);
    });

    test('<!--source-image--> 支持防盗链请求头解析且绝不放宽文库 <!--image--> 白名单', () {
      expect(
        readerIllustrationUrl('<!--image-->https://example.org/a.jpg<!--image-->'),
        isNull,
      );
      final encoded = encodeSourceImageParagraph(
        'https://img.example.org/ch1/001.webp',
        headers: const {'Referer': 'https://manga.example.org/'},
      );
      final extracted = readerIllustrationUrl(encoded);
      expect(extracted, isNotNull);
      final spec = tryParseSourceImageSpec(extracted!);
      expect(spec, isNotNull);
      expect(spec!.url, 'https://img.example.org/ch1/001.webp');
      expect(spec.headers['Referer'], 'https://manga.example.org/');
    });
  });

  group('BookSource 兼容性静态扫描、GBK 模板与敏感 Cookie 隔离存储', () {
    test('识别完全兼容、部分兼容与需脚本/动态渲染暂不支持书源', () {
      final rawJson = jsonEncode([
        {
          'bookSourceUrl': 'https://static-novel.example.org',
          'bookSourceName': '纯净静态源',
          'bookSourceType': 0,
          'searchUrl': '/search?q={{key}}&p={{page}}',
          'ruleSearch': {
            'bookList': '.book-item',
            'name': 'h3@text',
            'bookUrl': 'a@href',
          },
          'ruleToc': {'chapterList': '#list a', 'chapterName': 'text', 'chapterUrl': 'href'},
          'ruleContent': {'content': '#content@html'},
        },
        {
          'bookSourceUrl': 'https://partial-novel.example.org',
          'bookSourceName': '动态分类静态阅读源',
          'bookSourceType': 0,
          'searchUrl': '/s?k={{key}}',
          'exploreUrl': '@js:JSON.stringify([])',
          'ruleSearch': {'bookList': '.item', 'name': '.t@text', 'bookUrl': 'a@href'},
          'ruleToc': {'chapterList': '.c a', 'chapterName': 'text', 'chapterUrl': 'href'},
          'ruleContent': {'content': '#txt@html'},
        },
        {
          'bookSourceUrl': 'https://js-encrypted.example.org',
          'bookSourceName': 'JS 解密漫画源',
          'bookSourceType': 2,
          'searchUrl': '/s?k={{key}}',
          'ruleSearch': {'bookList': '.item', 'name': '.t@text', 'bookUrl': 'a@href'},
          'ruleToc': {'chapterList': '.c a', 'chapterName': 'text', 'chapterUrl': 'href'},
          'ruleContent': {
            'content': '@js:decryptImages(result)',
            'imageDecode': 'xorBytes(bytes)',
          },
        },
      ]);

      final parsed = parseBookSourcesJson(rawJson);
      expect(parsed.sources.length, 3);
      expect(parsed.fullCount, 1);
      expect(parsed.partialCount, 1);
      expect(parsed.unsupportedCount, 1);

      expect(parsed.sources[0].compatibility, SourceCompatibility.full);
      expect(parsed.sources[0].enabled, isTrue);

      expect(parsed.sources[1].compatibility, SourceCompatibility.partial);
      expect(parsed.sources[1].compatibility.canEnable, isTrue);
      expect(parsed.sources[1].exploreKinds, isEmpty);

      expect(
        parsed.sources[2].compatibility,
        SourceCompatibility.requiresJs,
      );
      expect(parsed.sources[2].compatibility.canEnable, isFalse);
      expect(parsed.sources[2].enabled, isFalse);
      expect(parsed.sources[2].isManga, isTrue);
    });

    test('支持 POST 请求、GBK 搜索参数编码、<first,rest> 分页与页码算术表达式', () {
      final src = BookSource.fromAnyMap({
        'bookSourceUrl': 'https://gbk-site.example.org',
        'bookSourceName': 'GBK 书源',
        'searchUrl':
            '/modules/article/search.php,{"method":"POST","charset":"GBK","body":"searchkey={{key}}&page={{page}}"}',
        'exploreUrl': '玄幻::/sort/1/<index.html,{{(page-1)*20}}.html>',
        'ruleToc': {'chapterList': 'a', 'chapterName': 'text', 'chapterUrl': 'href'},
        'ruleContent': {'content': '#nr'},
      })!;

      final postReq = src.buildRequest(src.searchUrl, keyword: '三体', page: 2);
      expect(postReq.method, 'POST');
      expect(postReq.charset?.toUpperCase(), 'GBK');
      expect(
        postReq.body,
        'searchkey=${encodeQueryValueWithCharset('三体', charset: 'GBK')}&page=2',
      );

      final page1 = src.buildRequest(src.exploreKinds.single.url, page: 1);
      final page3 = src.buildRequest(src.exploreKinds.single.url, page: 3);
      expect(page1.uri.toString(), 'https://gbk-site.example.org/sort/1/index.html');
      expect(page3.uri.toString(), 'https://gbk-site.example.org/sort/1/40.html');
    });

    test('BookSourceStore 将 Cookie/Authorization 隔离存放并在导出时自动脱敏', () async {
      final temp = await Directory.systemTemp.createTemp('shuyu_source_store_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      final store = BookSourceStore(directoryProvider: () async => temp);
      await store.load();
      final summary = await store.importFromJsonText(
        jsonEncode([
          {
            'bookSourceUrl': 'https://vip.example.org',
            'bookSourceName': '带登录态书源',
            'header': jsonEncode({
              'User-Agent': 'CustomUA/1.0',
              'Cookie': 'sid=super_secret_cookie',
              'Authorization': 'Bearer secret_token_123',
            }),
            'searchUrl': '/search?q={{key}}',
            'ruleSearch': {'bookList': '.b', 'name': 'a@text', 'bookUrl': 'a@href'},
            'ruleToc': {'chapterList': 'a', 'chapterName': 'text', 'chapterUrl': 'href'},
            'ruleContent': {'content': '#c'},
          },
        ]),
      );
      expect(summary.added, 1);

      final storedPublic = store.sources.single;
      expect(storedPublic.headers['User-Agent'], 'CustomUA/1.0');
      expect(storedPublic.headers.containsKey('Cookie'), isFalse);
      expect(storedPublic.headers.containsKey('Authorization'), isFalse);

      final mainDisk = await File('${temp.path}/book_sources_v1.json').readAsString();
      expect(mainDisk.contains('super_secret_cookie'), isFalse);
      expect(mainDisk.contains('secret_token_123'), isFalse);

      final exported = store.exportSanitizedJson();
      expect(exported.contains('super_secret_cookie'), isFalse);

      final hydrated = store.hydrated(storedPublic);
      expect(hydrated.headers['Cookie'], 'sid=super_secret_cookie');
      expect(hydrated.headers['Authorization'], 'Bearer secret_token_123');
    });
  });

  group('SourceRuleEngine 多语法规则引擎与 ChapterNormalizer 目录清洗', () {
    test('支持 Legado Jsoup 链、CSS、XPath、JSONPath、正则替换与组合子', () {
      const html = '''
      <html><body>
        <div class="result-list">
          <div class="item"><span>置顶公告</span></div>
          <div class="item">
            <h3><a href="/book/101.html">诡秘之主</a></h3>
            <p class="meta">作者：爱潜水的乌贼</p>
            <img data-original="/covers/101.jpg" src="/static/lazy.gif" />
          </div>
        </div>
      </body></html>
      ''';

      final items = SourceRuleEngine.parseBookListDirect(
        body: html,
        baseUrl: 'https://novel.example.org',
        rule: const SourceListRule(
          bookList: 'class.result-list@class.item!0',
          name: 'tag.h3@tag.a.0@text',
          author: '@css:.meta@text##^作者：',
          bookUrl: '//h3/a/@href',
          coverUrl: 'tag.img@data-original||tag.img@src',
        ),
      );
      expect(items.length, 1);
      expect(items.single.title, '诡秘之主');
      expect(items.single.author, '爱潜水的乌贼');
      expect(items.single.bookUrl, 'https://novel.example.org/book/101.html');
      expect(items.single.coverUrl, 'https://novel.example.org/covers/101.jpg');

      final jsonBody = jsonEncode({
        'code': 0,
        'data': {
          'books': [
            {
              'title': '黎明之剑',
              'writer': '远瞳',
              'id': '202',
            },
          ],
        },
      });
      final jsonItems = SourceRuleEngine.parseBookListDirect(
        body: jsonBody,
        baseUrl: 'https://api.example.org',
        rule: const SourceListRule(
          bookList: r'$.data.books[*]',
          name: r'$.title',
          author: r'$.writer',
          bookUrl: r'https://api.example.org/book/{{$.id}}',
        ),
      );
      expect(jsonItems.length, 1);
      expect(jsonItems.single.title, '黎明之剑');
      expect(jsonItems.single.bookUrl, 'https://api.example.org/book/202');
    });

    test('支持小说正文内嵌插图提取与漫画懒加载多图提取', () {
      const novelChapterHtml = '''
      <div id="content">
        <p>第一段正文内容。</p>
        <img data-src="/illus/scene1.png" />
        <p>第二段正文内容，请记住本站域名 example.org。</p>
      </div>
      ''';
      final novelPage = SourceRuleEngine.parseChapterPageDirect(
        body: novelChapterHtml,
        pageUrl: 'https://novel.example.org/b/1/c1.html',
        rule: const SourceContentRule(
          content: '#content@html',
          replaceRegex: '，请记住本站域名.*',
        ),
        contentType: SourceContentType.text,
      );
      expect(novelPage.body, contains('第一段正文内容。'));
      expect(
        novelPage.body,
        contains('<!--source-image-->https://novel.example.org/illus/scene1.png<!--source-image-->'),
      );
      expect(novelPage.body, contains('第二段正文内容'));
      expect(novelPage.body.contains('请记住本站域名'), isFalse);

      const mangaHtml = '''
      <div class="viewer">
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-original="https://img.example.org/ep1/01.jpg" />
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-original="https://img.example.org/ep1/02.jpg" />
      </div>
      ''';
      final mangaPage = SourceRuleEngine.parseChapterPageDirect(
        body: mangaHtml,
        pageUrl: 'https://manga.example.org/m/9/ep1.html',
        rule: const SourceContentRule(content: '.viewer img'),
        contentType: SourceContentType.manga,
      );
      final lines = mangaPage.body.split('\n\n');
      expect(lines.length, 2);
      expect(
        tryParseSourceImageSpec(lines[0])!.url,
        'https://img.example.org/ep1/01.jpg',
      );
      expect(
        tryParseSourceImageSpec(lines[0])!.headers['Referer'],
        'https://manga.example.org/m/9/ep1.html',
      );
    });

    test('ChapterNormalizer 自动剔除笔趣阁顶部最新章预览重复项并纠正全倒序中文数字目录', () {
      final biqugeRaw = <RawExtractedChapter>[
        const RawExtractedChapter(title: '第一百二十章 终局', url: 'https://n.example.org/120.html'),
        const RawExtractedChapter(title: '第一百一十九章 前夜', url: 'https://n.example.org/119.html'),
        const RawExtractedChapter(title: '第一章 醒来', url: 'https://n.example.org/1.html'),
        const RawExtractedChapter(title: '第二章 出发', url: 'https://n.example.org/2.html'),
        const RawExtractedChapter(title: '第一百一十九章 前夜', url: 'https://n.example.org/119.html'),
        const RawExtractedChapter(title: '第一百二十章 终局', url: 'https://n.example.org/120.html'),
      ];
      final cleaned = ChapterNormalizer.normalize(biqugeRaw);
      expect(cleaned.map((e) => e.chapter.title).toList(), [
        '第一章 醒来',
        '第二章 出发',
        '第一百一十九章 前夜',
        '第一百二十章 终局',
      ]);
      expect(cleaned.every((e) => e.chapter.id > 0), isTrue);

      final descendingRaw = <RawExtractedChapter>[
        for (var i = 6; i >= 1; i--)
          RawExtractedChapter(
            title: '第$i章 试炼$i',
            url: 'https://n.example.org/ch/$i.html',
          ),
      ];
      final reversed = ChapterNormalizer.normalize(
        descendingRaw,
        reverseMode: TocReverseMode.auto,
      );
      expect(reversed.first.chapter.title, '第1章 试炼1');
      expect(reversed.last.chapter.title, '第6章 试炼6');
    });
  });

  group('端到端本地 Mock HttpServer：搜索、分页目录、分页正文、GBK、换源、防爬提示、离线钉住插图与备份恢复', () {
    late Directory temp;
    late PathProviderPlatform prevPaths;
    late HttpOverrides? prevHttpOverrides;
    late BookSourceStore prevSourceStore;
    late OnlineBookOriginStore prevOriginStore;
    late SourceHttpClient prevHttpClient;
    late SourceImageCache prevImageCache;
    late HttpServer server;
    late String baseUrl;
    var serverTocChapterCount = 2;

    HttpClient directHttpClient() => HttpClient()..findProxy = (_) => 'DIRECT';

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('shuyu_online_e2e_');
      prevPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(temp.path);
      prevHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      NetworkUrlSafety.allowLoopbackForTesting = true;
      serverTocChapterCount = 2;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';

      server.listen((HttpRequest req) async {
        final path = req.uri.path;
        if (path == '/sources.json') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode([
              {
                'bookSourceUrl': baseUrl,
                'bookSourceName': '主力测试书源',
                'bookSourceType': 0,
                'searchUrl': '/search?q={{key}}',
                'exploreUrl': '热榜::/explore?page={{page}}',
                'ruleSearch': {
                  'bookList': '.item',
                  'name': '.title@text',
                  'author': '.author@text',
                  'bookUrl': 'a@href',
                  'coverUrl': 'img@src',
                  'lastChapter': '.latest@text',
                },
                'ruleExplore': {
                  'bookList': '.item',
                  'name': '.title@text',
                  'author': '.author@text',
                  'bookUrl': 'a@href',
                },
                'ruleBookInfo': {
                  'name': 'h1@text',
                  'author': '.writer@text',
                  'intro': '.intro@text',
                  'tocUrl': '.toc-link@href',
                  'coverUrl': '.cover@src',
                },
                'ruleToc': {
                  'chapterList': '.toc li a',
                  'chapterName': 'text',
                  'chapterUrl': 'href',
                  'nextTocUrl': 'a.next-toc@href',
                },
                'ruleContent': {
                  'content': '#chapter-body@html',
                  'nextContentUrl': 'a.next-page@href',
                },
              },
              {
                'bookSourceUrl': '$baseUrl/mirror',
                'bookSourceName': '备用镜像书源',
                'bookSourceType': 0,
                'searchUrl': '$baseUrl/mirror/search?q={{key}}',
                'ruleSearch': {
                  'bookList': '.item',
                  'name': '.title@text',
                  'author': '.author@text',
                  'bookUrl': 'a@href',
                },
                'ruleBookInfo': {'name': 'h1@text', 'author': '.writer@text'},
                'ruleToc': {
                  'chapterList': '.toc a',
                  'chapterName': 'text',
                  'chapterUrl': 'href',
                },
                'ruleContent': {'content': '#chapter-body@html'},
              },
            ]),
          );
          await req.response.close();
          return;
        }
        if (path == '/search' || path == '/explore') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <div class="item">
              <a href="/book/1"><span class="title">深海余烬</span></a>
              <span class="author">远瞳</span>
              <span class="latest">第2章 幽灵船</span>
              <img src="/img/cover.png" />
            </div>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/book/1') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <h1>深海余烬</h1>
            <div class="writer">远瞳</div>
            <div class="intro">在那一天，浓雾封锁了一切。</div>
            <img class="cover" src="/img/cover.png" />
            <a class="toc-link" href="/book/1/toc-1">目录</a>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/book/1/toc-1') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <ul class="toc">
              <li><a href="/book/1/c1">第一章 浓雾</a></li>
            </ul>
            <a class="next-toc" href="/book/1/toc-2">下一页目录</a>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/book/1/toc-2') {
          req.response.headers.contentType = ContentType.html;
          final extra = serverTocChapterCount >= 3
              ? '<li><a href="/book/1/c3">第三章 靠岸</a></li>'
              : '';
          req.response.write('''
            <ul class="toc">
              <li><a href="/book/1/c2">第二章 幽灵船</a></li>
              $extra
            </ul>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/book/1/c1') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <div id="chapter-body">
              <p>第一章 浓雾</p>
              <p>邓肯在船长室醒来。</p>
              <img src="/img/illus1.png" />
            </div>
            <a class="next-page" href="/book/1/c1_2">本章下一页</a>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/book/1/c1_2') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <div id="chapter-body">
              <p>第一章 浓雾（2/2）</p>
              <p>失乡号静静航行在无垠之海上。</p>
            </div>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/gbk-page') {
          req.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'text/html; charset=gbk',
          );
          req.response.add(encodeGbkBytes('<div id="g">中文GBK无乱码解析</div>'));
          await req.response.close();
          return;
        }
        if (path == '/cf-challenge') {
          req.response.statusCode = HttpStatus.forbidden;
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><head><title>Just a moment...</title></head>'
            '<body><div class="cf-turnstile">Verify you are human</div></body></html>',
          );
          await req.response.close();
          return;
        }
        if (path == '/mirror/search') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <div class="item">
              <a href="$baseUrl/mirror/book/99"><span class="title">深海余烬</span></a>
              <span class="author">远瞳</span>
            </div>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/mirror/book/99') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
            <h1>深海余烬</h1>
            <div class="writer">远瞳</div>
            <div class="toc">
              <a href="$baseUrl/mirror/c1">第1章 浓雾</a>
              <a href="$baseUrl/mirror/c2">第2章 幽灵船</a>
            </div>
          ''');
          await req.response.close();
          return;
        }
        if (path == '/mirror/c2') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<div id="chapter-body"><p>来自备用镜像书源的第二章正文。</p></div>',
          );
          await req.response.close();
          return;
        }
        if (path.startsWith('/img/')) {
          req.response.headers.set(HttpHeaders.contentTypeHeader, 'image/png');
          req.response.add(_validPng1x1);
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      prevSourceStore = BookSourceStore.shared;
      prevOriginStore = OnlineBookOriginStore.shared;
      prevHttpClient = SourceHttpClient.shared;
      prevImageCache = SourceImageCache.shared;

      BookSourceStore.shared = BookSourceStore(
        directoryProvider: () async => Directory('${temp.path}/sources'),
        httpClientFactory: directHttpClient,
      );
      OnlineBookOriginStore.shared = OnlineBookOriginStore(
        directoryProvider: () async => Directory('${temp.path}/sources'),
        sourceStore: BookSourceStore.shared,
      );
      SourceHttpClient.shared = SourceHttpClient(clientFactory: directHttpClient);
      SourceImageCache.shared = SourceImageCache(
        rootDirectoryProvider: () async => Directory('${temp.path}/images'),
        transport: (uri, headers, maxBytes) async {
          final client = directHttpClient();
          try {
            final req = await client.getUrl(uri);
            headers.forEach(req.headers.set);
            final res = await req.close();
            if (res.statusCode != 200) {
              throw HttpException('HTTP ${res.statusCode}');
            }
            final bytes = await res.fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (b, chunk) => b..add(chunk),
            );
            return bytes.takeBytes();
          } finally {
            client.close(force: true);
          }
        },
      );
      await BookSourceStore.shared.load();
      await OnlineBookOriginStore.shared.load();
      ReaderPurificationStore.shared.resetForTesting();
    });

    tearDown(() async {
      await server.close(force: true);
      BookSourceStore.shared = prevSourceStore;
      OnlineBookOriginStore.shared = prevOriginStore;
      SourceHttpClient.shared = prevHttpClient;
      SourceImageCache.shared = prevImageCache;
      HttpOverrides.global = prevHttpOverrides;
      PathProviderPlatform.instance = prevPaths;
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('支持酷安跳转 URL 导入、流式聚合搜索、多页目录/正文拼接、追更检测、换源章节对齐与离线插图钉住', () async {
      final coolapkWrapped =
          'https://www.coolapk.com/link?url=${Uri.encodeComponent('$baseUrl/sources.json')}';
      final imported = await BookSourceStore.shared.importFromUrl(coolapkWrapped);
      expect(imported.added, 2);
      expect(BookSourceStore.shared.hasActiveSources, isTrue);

      final sourceRepo = SourceNovelRepository(
        sourceStore: BookSourceStore.shared,
        originStore: OnlineBookOriginStore.shared,
        httpClient: SourceHttpClient.shared,
      );

      // 1. 流式搜索
      final batches = await sourceRepo.searchStream('深海').toList();
      expect(batches, isNotEmpty);
      final found = batches.expand((b) => b.items).firstWhere(
        (n) => OnlineBookOriginStore.shared.byBookId(n.id)?.sourceBaseUrl == baseUrl,
      );
      expect(isSourceNovelId(found.id), isTrue);
      expect(found.title, '深海余烬');

      // 2. 详情 + 跨页目录合并
      final detailed = await sourceRepo.detail(found);
      expect(detailed.summary, contains('浓雾封锁了一切'));
      final chapters = await sourceRepo.chapters(found.id);
      expect(chapters.map((c) => c.title).toList(), ['第一章 浓雾', '第二章 幽灵船']);

      // 3. 跨页正文拼接 + 重复章节标题剥离 + 内嵌插图保留
      final ch1Body = await sourceRepo.chapterContent(found.id, chapters.first);
      expect(ch1Body, contains('邓肯在船长室醒来。'));
      expect(ch1Body, contains('失乡号静静航行在无垠之海上。'));
      expect(ch1Body, contains('<!--source-image-->'));
      expect(ch1Body.startsWith('第一章 浓雾\n'), isFalse);

      // 4. GBK 自动解码与人机验证诚实报错（绝不绕过 CAPTCHA）
      final gbkResp = await SourceHttpClient.shared.send(
        ResolvedSourceRequest(uri: Uri.parse('$baseUrl/gbk-page')),
        rateKey: baseUrl,
      );
      expect(gbkResp.body, contains('中文GBK无乱码解析'));

      await expectLater(
        SourceHttpClient.shared.send(
          ResolvedSourceRequest(uri: Uri.parse('$baseUrl/cf-challenge')),
          rateKey: baseUrl,
        ),
        throwsA(isA<SourceChallengeException>()),
      );

      // 5. 书架追更检查 (+1 章未读提醒)
      serverTocChapterCount = 3;
      final updateSummary = await sourceRepo.checkShelfUpdates([found.id]);
      expect(updateSummary.updatedBooks, 1);
      expect(updateSummary.newChapters, 1);
      expect(
        OnlineBookOriginStore.shared.byBookId(found.id)?.unreadUpdateCount,
        1,
      );

      // 6. 离线缓存钉住插图：断网（关闭服务前用 OfflineNovelRepository 下载），关闭服务后仍可读取正文与插图
      final cacheDir = Directory('${temp.path}/offline-cache');
      final cacheStore = OfflineCacheStore(cacheDir);
      final offlineRepo = OfflineNovelRepository(
        remote: sourceRepo,
        cache: cacheStore,
      );
      addTearDown(() {
        offlineRepo.dispose();
        cacheStore.dispose();
      });
      await offlineRepo.loadCache();
      offlineRepo.download(detailed, chapterIds: {chapters.first.id});
      for (var i = 0; i < 240; i++) {
        final phase = offlineRepo.jobFor(found.id)?.phase;
        if (phase == DownloadPhase.completed || phase == DownloadPhase.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(offlineRepo.jobFor(found.id)?.phase, DownloadPhase.completed);

      // 清空内存缓存并验证磁盘已钉住插图（断网不触发网络请求）
      SourceImageCache.shared.clearMemory();
      final pinnedDir = Directory('${temp.path}/images/pinned/book_${found.id}');
      expect(await pinnedDir.exists(), isTrue);
      expect(await pinnedDir.list().length, 1);

      // 7. 换源：保持相同 bookId，并将「第二章 幽灵船」自动对齐到备用源「第2章 幽灵船」
      final alternatives = await sourceRepo.findAlternativeSources(found.id);
      expect(alternatives.length, 1);
      expect(alternatives.single.source.name, '备用镜像书源');
      final switched = await sourceRepo.switchSourceForBook(
        found.id,
        alternatives.single,
        previousChapterTitle: '第二章 幽灵船',
        previousChapterIndex: 1,
      );
      expect(switched.novel.id, found.id);
      expect(switched.alignedIndex, 1);
      final mirrorBody = await sourceRepo.chapterContent(
        found.id,
        switched.chapters[switched.alignedIndex],
      );
      expect(mirrorBody, contains('来自备用镜像书源的第二章正文。'));

      // 8. 清理单本离线缓存时连同已钉住插图一并删除
      await offlineRepo.removeCachedBook(found.id);
      expect(await pinnedDir.exists(), isFalse);
    });

    test('LibraryBackup 备份与恢复完整保留脱敏书源、在线书籍来源映射与阅读进度', () async {
      SharedPreferences.setMockInitialValues({});
      await TagStore.load();

      // 使用合法公网域名验证跨 Isolate（compute）备份校验器与 Cookie 脱敏
      await BookSourceStore.shared.clearAll();
      await BookSourceStore.shared.importFromJsonText(
        jsonEncode([
          {
            'bookSourceUrl': 'https://backup-novel.example.org',
            'bookSourceName': '备份测试书源',
            'header': jsonEncode({
              'User-Agent': 'BackupUA/1.0',
              'Cookie': 'session=must_not_leak_in_backup',
            }),
            'searchUrl': '/s?q={{key}}',
            'ruleSearch': {'bookList': '.i', 'name': 'a@text', 'bookUrl': 'a@href'},
            'ruleToc': {'chapterList': 'a', 'chapterName': 'text', 'chapterUrl': 'href'},
            'ruleContent': {'content': '#c'},
          },
        ]),
      );
      final origin = OnlineBookOriginStore.shared.upsertDiscovered(
        sourceId: BookSourceStore.shared.sources.single.id,
        sourceName: '备份测试书源',
        sourceBaseUrl: 'https://backup-novel.example.org',
        bookUrl: 'https://backup-novel.example.org/book/777',
        title: '道诡异仙',
        author: '狐尾的笔',
        coverUrl: 'https://backup-novel.example.org/cover/777.jpg',
        knownChapterCount: 50,
      );
      await OnlineBookOriginStore.shared.flush();

      final stateA = await LibraryState.load();
      addTearDown(stateA.dispose);
      final novel = origin.toNovel(
        chapters: const [
          NovelChapter('第一章', '', id: 1001),
          NovelChapter('第二章', '', id: 1002),
        ],
      );
      await stateA.rememberNovel(novel);
      await stateA.toggleShelf(novel.id);
      await stateA.savePosition(
        novel: novel,
        chapter: 1,
        offset: 120,
        maximum: 400,
        width: 390,
      );

      final backup = await stateA.createBackup();
      final encoded = await backup.encode();
      expect(encoded.contains('must_not_leak_in_backup'), isFalse);
      expect(encoded.contains('https://backup-novel.example.org'), isTrue);
      expect(encoded.contains('道诡异仙'), isTrue);

      // 模拟在新设备恢复备份
      final restoreDir = Directory('${temp.path}/restored-device');
      await restoreDir.create(recursive: true);
      BookSourceStore.shared = BookSourceStore(
        directoryProvider: () async => restoreDir,
      );
      OnlineBookOriginStore.shared = OnlineBookOriginStore(
        directoryProvider: () async => restoreDir,
        sourceStore: BookSourceStore.shared,
      );
      await BookSourceStore.shared.load();
      await OnlineBookOriginStore.shared.load();
      expect(BookSourceStore.shared.sources, isEmpty);
      expect(OnlineBookOriginStore.shared.origins, isEmpty);

      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      final stateB = await LibraryState.load();
      addTearDown(stateB.dispose);

      final parsedBackup = await LibraryBackup.parse(encoded);
      await stateB.restoreBackup(parsedBackup);

      expect(BookSourceStore.shared.sources.length, 1);
      expect(
        BookSourceStore.shared.sources.single.name,
        '备份测试书源',
      );
      expect(
        OnlineBookOriginStore.shared.byBookId(origin.bookId)?.title,
        '道诡异仙',
      );
      expect(stateB.contains(origin.bookId), isTrue);
      expect(stateB.chapterFor(origin.bookId), 1);
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_manga_reader.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/sources/book_source.dart';
import 'package:shuyu/sources/book_source_store.dart';
import 'package:shuyu/sources/network_url_safety.dart';
import 'package:shuyu/sources/online_book_origins.dart';
import 'package:shuyu/sources/source_http.dart';
import 'package:shuyu/sources/source_image_cache.dart';
import 'package:shuyu/sources/source_repository.dart';

class _WidgetTestPaths extends PathProviderPlatform {
  _WidgetTestPaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getExternalStoragePath() async => root;
}

Future<Uint8List> _renderSolidPng({
  int width = 90,
  int height = 130,
  Color color = const Color(0xFF3E6B89),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    Rect.fromLTWH(8, 10, width - 16.0, height - 20.0),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final bytes = Uint8List.fromList(byteData.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return bytes;
}

Future<void> _pumpAsyncUi(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 220));
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 180));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NetworkUrlSafety.debugDnsLookup = (_) async => [
      InternetAddress.fromRawAddress(Uint8List.fromList([93, 184, 216, 34])),
    ];
  });

  tearDown(() {
    NetworkUrlSafety.debugDnsLookup = null;
    NetworkUrlSafety.allowLoopbackForTesting = false;
  });

  group('发现页「本地馆藏 | 在线书源」切换与在线漫画阅读器', () {
    testWidgets('0 启用书源时发现页零打扰隐藏切换栏；启用书源后可在发现页切换至在线书源面板', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late Directory temp;
      late PathProviderPlatform prevPaths;
      late BookSourceStore prevSourceStore;
      late OnlineBookOriginStore prevOriginStore;
      late SourceHttpClient prevHttp;
      late LibraryState state;

      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('shuyu_discover_switch_');
        prevPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _WidgetTestPaths(temp.path);
        prevSourceStore = BookSourceStore.shared;
        prevOriginStore = OnlineBookOriginStore.shared;
        prevHttp = SourceHttpClient.shared;

        BookSourceStore.shared = BookSourceStore(
          directoryProvider: () async => Directory('${temp.path}/sources'),
        );
        OnlineBookOriginStore.shared = OnlineBookOriginStore(
          directoryProvider: () async => Directory('${temp.path}/sources'),
          sourceStore: BookSourceStore.shared,
          enablePersistence: false,
        );
        SourceHttpClient.shared = SourceHttpClient(
          transport: (req) async => SourceHttpResponse(
            finalUri: req.uri,
            statusCode: 200,
            body:
                '<div class="b"><a href="https://novel.example.org/1">星际书馆</a></div>',
            headers: const {},
          ),
        );
        await BookSourceStore.shared.load();
        await OnlineBookOriginStore.shared.load();

        LibraryFilter.shared.resetForTesting();
        SharedPreferences.setMockInitialValues({'reduceMotion': true});
        await TagStore.load();
        state = await LibraryState.load();
      });

      addTearDown(() async {
        state.dispose();
        BookSourceStore.shared = prevSourceStore;
        OnlineBookOriginStore.shared = prevOriginStore;
        SourceHttpClient.shared = prevHttp;
        PathProviderPlatform.instance = prevPaths;
        await tester.runAsync(() async {
          if (await temp.exists()) await temp.delete(recursive: true);
        });
      });

      final sourceRepo = SourceNovelRepository(
        sourceStore: BookSourceStore.shared,
        originStore: OnlineBookOriginStore.shared,
        httpClient: SourceHttpClient.shared,
      );
      final router = RemoteRouterRepository(
        legacy: const DemoNovelRepository(),
        sources: sourceRepo,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DiscoverPage(
              books: const [],
              state: state,
              repository: router,
              onSearch: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 未导入书源时，零打扰：不展示「本地馆藏 | 在线书源」切换器
      expect(
        find.byKey(const ValueKey('discover-source-mode-switcher')),
        findsNothing,
      );

      // 导入 1 条启用书源后，自动展示切换器并可切换至在线书源面板
      await tester.runAsync(() async {
        await BookSourceStore.shared.importFromJsonText(
          jsonEncode([
            {
              'bookSourceUrl': 'https://novel.example.org',
              'bookSourceName': '星际书源',
              'searchUrl': '/s?q={{key}}',
              'exploreUrl': '推荐::/hot?p={{page}}',
              'ruleSearch': {
                'bookList': '.b',
                'name': 'a@text',
                'bookUrl': 'a@href',
              },
              'ruleExplore': {
                'bookList': '.b',
                'name': 'a@text',
                'bookUrl': 'a@href',
              },
              'ruleToc': {
                'chapterList': 'a',
                'chapterName': 'text',
                'chapterUrl': 'href',
              },
              'ruleContent': {'content': '#c'},
            },
          ]),
        );
      });
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(const ValueKey('discover-source-mode-switcher')),
        findsOneWidget,
      );
      expect(find.text('本地馆藏'), findsOneWidget);
      expect(find.text('在线书源'), findsOneWidget);

      await tester.tap(find.text('在线书源'));
      await _pumpAsyncUi(tester);

      expect(find.text('星际书馆'), findsWidgets);
    });

    testWidgets(
      '在线漫画（bookSourceType == 2）自动路由至 LocalMangaReaderPage，支持防盗链图片加载、话内翻页进度、书签与跨话切换',
      (tester) async {
        tester.view.physicalSize = const Size(420, 860);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        late Directory temp;
        late PathProviderPlatform prevPaths;
        late BookSourceStore prevSourceStore;
        late OnlineBookOriginStore prevOriginStore;
        late SourceHttpClient prevHttp;
        late SourceImageCache prevImageCache;
        late LibraryState state;
        late Uint8List pagePngA;
        late Uint8List pagePngB;
        final recordedImageHeaders = <String, Map<String, String>>{};

        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('shuyu_online_manga_');
          prevPaths = PathProviderPlatform.instance;
          PathProviderPlatform.instance = _WidgetTestPaths(temp.path);
          pagePngA = await _renderSolidPng(color: const Color(0xFF2B6CB0));
          pagePngB = await _renderSolidPng(color: const Color(0xFF2F855A));

          prevSourceStore = BookSourceStore.shared;
          prevOriginStore = OnlineBookOriginStore.shared;
          prevHttp = SourceHttpClient.shared;
          prevImageCache = SourceImageCache.shared;

          BookSourceStore.shared = BookSourceStore(
            directoryProvider: () async => Directory('${temp.path}/sources'),
          );
          OnlineBookOriginStore.shared = OnlineBookOriginStore(
            directoryProvider: () async => Directory('${temp.path}/sources'),
            sourceStore: BookSourceStore.shared,
            enablePersistence: false,
          );
          SourceHttpClient.shared = SourceHttpClient(
            transport: (req) async {
              final path = req.uri.path;
              if (path == '/manga/10') {
                return SourceHttpResponse(
                  finalUri: req.uri,
                  statusCode: 200,
                  body: '''
                    <h1>迷宫饭在线版</h1>
                    <ul class="eps">
                      <li><a href="https://manga.example.org/manga/10/ep1">第1话 启程</a></li>
                      <li><a href="https://manga.example.org/manga/10/ep2">第2话 重逢</a></li>
                    </ul>
                  ''',
                  headers: const {},
                );
              }
              if (path == '/manga/10/ep1') {
                return SourceHttpResponse(
                  finalUri: req.uri,
                  statusCode: 200,
                  body: '''
                    <div class="pages">
                      <img data-original="https://img.example.org/ep1/p1.png" />
                      <img data-original="https://img.example.org/ep1/p2.png" />
                    </div>
                  ''',
                  headers: const {},
                );
              }
              if (path == '/manga/10/ep2') {
                return SourceHttpResponse(
                  finalUri: req.uri,
                  statusCode: 200,
                  body: '''
                    <div class="pages">
                      <img data-original="https://img.example.org/ep2/p1.png" />
                      <img data-original="https://img.example.org/ep2/p2.png" />
                    </div>
                  ''',
                  headers: const {},
                );
              }
              throw HttpException('Unexpected URL ${req.uri}');
            },
          );
          SourceImageCache.shared = SourceImageCache(
            enableDiskCache: false,
            transport: (uri, headers, maxBytes) async {
              recordedImageHeaders[uri.toString()] = Map<String, String>.from(
                headers,
              );
              return uri.path.endsWith('p1.png') ? pagePngA : pagePngB;
            },
          );

          await BookSourceStore.shared.load();
          await OnlineBookOriginStore.shared.load();

          await BookSourceStore.shared.importFromJsonText(
            jsonEncode([
              {
                'bookSourceUrl': 'https://manga.example.org',
                'bookSourceName': '测试漫画源',
                'bookSourceType': 2,
                'header': jsonEncode({'User-Agent': 'MangaUA/2.0'}),
                'searchUrl': '/search?q={{key}}',
                'ruleSearch': {
                  'bookList': '.m',
                  'name': 'a@text',
                  'bookUrl': 'a@href',
                },
                'ruleBookInfo': {'name': 'h1@text'},
                'ruleToc': {
                  'chapterList': '.eps li a',
                  'chapterName': 'text',
                  'chapterUrl': 'href',
                },
                'ruleContent': {'content': '.pages img'},
              },
            ]),
          );

          SharedPreferences.setMockInitialValues({'reduceMotion': true});
          await TagStore.load();
          state = await LibraryState.load();
        });

        addTearDown(() async {
          state.dispose();
          BookSourceStore.shared = prevSourceStore;
          OnlineBookOriginStore.shared = prevOriginStore;
          SourceHttpClient.shared = prevHttp;
          SourceImageCache.shared = prevImageCache;
          PathProviderPlatform.instance = prevPaths;
          await tester.runAsync(() async {
            if (await temp.exists()) await temp.delete(recursive: true);
          });
        });

        final sourceRepo = SourceNovelRepository(
          sourceStore: BookSourceStore.shared,
          originStore: OnlineBookOriginStore.shared,
          httpClient: SourceHttpClient.shared,
        );
        final router = RemoteRouterRepository(
          legacy: const DemoNovelRepository(),
          sources: sourceRepo,
        );

        late OnlineBookOrigin origin;
        late List<NovelChapter> episodes;
        await tester.runAsync(() async {
          final src = BookSourceStore.shared.sources.firstWhere(
            (s) => s.contentType == SourceContentType.manga,
          );
          origin = OnlineBookOriginStore.shared.upsertDiscovered(
            sourceId: src.id,
            sourceName: src.name,
            sourceBaseUrl: src.baseUrl,
            bookUrl: 'https://manga.example.org/manga/10',
            title: '迷宫饭在线版',
            isManga: true,
          );
          episodes = await sourceRepo.chapters(origin.bookId);
        });
        final mangaNovel = origin.toNovel(chapters: episodes);

        expect(state.isMangaModeForBook(mangaNovel.id), isTrue);
        final routed = readerPageFor(
          novel: mangaNovel,
          state: state,
          repository: router,
          chapter: 0,
        );
        expect(routed, isA<LocalMangaReaderPage>());

        await tester.pumpWidget(
          MaterialApp(
            home: routed,
          ),
        );
        await _pumpAsyncUi(tester);

        // 验证第 1 话加载完成，且防盗链 Referer 与自定义 User-Agent 已注入图片请求
        expect(find.textContaining('第1话 启程 · 第 1 / 2 页'), findsOneWidget);
        final p1Headers =
            recordedImageHeaders['https://img.example.org/ep1/p1.png'];
        expect(p1Headers, isNotNull);
        expect(p1Headers!['Referer'], 'https://manga.example.org/manga/10/ep1');
        expect(p1Headers['User-Agent'], 'MangaUA/2.0');

        // 日漫右翻模式下点击左侧区域翻至第 2 页，验证保存 (chapter: 0, paragraphIndex: 1)
        await tester.tapAt(const Offset(60, 430));
        await _pumpAsyncUi(tester);
        expect(find.textContaining('第1话 启程 · 第 2 / 2 页'), findsOneWidget);
        expect(state.positionFor(mangaNovel.id)?.chapter, 0);
        expect(state.positionFor(mangaNovel.id)?.paragraphIndex, 1);

        // 点击底栏「下一话」（日漫右翻模式下左侧按钮 manga-prev-chapter 为下一话）跨话进入第 2 话
        await tester.tap(find.byKey(const ValueKey('manga-prev-chapter')));
        await _pumpAsyncUi(tester);
        expect(find.textContaining('第2话 重逢 · 第 1 / 2 页'), findsOneWidget);
        expect(state.chapterForNovel(mangaNovel), 1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      },
    );
  });
}

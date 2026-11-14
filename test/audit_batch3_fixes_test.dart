import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/book_sync.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/cloud_sources.dart';
import 'package:shuyu/font_download.dart';
import 'package:shuyu/lan_bookshelf_server.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/listening/audio_output.dart';
import 'package:shuyu/listening/controller.dart';
import 'package:shuyu/listening/http_tts.dart';
import 'package:shuyu/listening/models.dart';
import 'package:shuyu/listening/store.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/reading_activity.dart';
import 'package:shuyu/reading_report_page.dart';
import 'package:shuyu/reading_report_range.dart';
import 'package:shuyu/reading_statistics_charts.dart';
import 'package:shuyu/reading_statistics_data.dart';
import 'package:shuyu/updates/app_updates.dart';
import 'package:shuyu/updates/update_page.dart';
import 'package:shuyu/webdav_sync.dart';

import 'support/listening_fixture.dart';

class _Batch3Paths extends PathProviderPlatform {
  _Batch3Paths(this.root);
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

class _StubUpdatePlatform implements UpdatePlatform {
  @override
  Future<InstalledApp> installedApp() async => const InstalledApp(
    version: '1.8.0',
    build: 180,
    abis: ['arm64-v8a'],
  );

  @override
  Future<String> install(File apk, String version) async => 'opened';

  @override
  Future<void> allowInstalls() async {}

  @override
  Future<void> openRelease(Uri page) async {}
}

class _StubUpdateSource implements UpdateSource {
  _StubUpdateSource(this.release);
  final AppRelease? release;
  int checks = 0;

  @override
  Future<AppRelease?> latest() async {
    checks++;
    return release;
  }

  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int) progress,
  ) async {
    await file.writeAsBytes(const [1, 2, 3, 4]);
    progress(4);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('P1-3: TagStore name deduplication & sync scope', () {
    tearDown(TagStore.resetForTesting);

    test(
      'TagStore.importTagRecords deduplicates tags by normalized name and remaps book assignments',
      () async {
        SharedPreferences.setMockInitialValues({});
        await TagStore.load();
        final store = TagStore.shared;
        final localTagId = await store.createTag('科幻');
        await store.setTagsForBook(101, [localTagId]);

        await store.importTagRecords({
          'tag_defs': jsonEncode([
            {'id': 'remote-scifi-id', 'name': ' 科幻 ', 'colorIndex': 2},
            {'id': 'remote-mystery-id', 'name': '推理', 'colorIndex': 3},
          ]),
          'tag_map': jsonEncode({
            '202': ['remote-scifi-id', 'remote-mystery-id'],
          }),
        });

        expect(store.tags.where((t) => t.name == '科幻').length, 1);
        expect(store.tags.any((t) => t.name == '推理'), isTrue);
        final book202TagIds = store.tagsForBook(202).map((t) => t.id).toSet();
        expect(book202TagIds.contains(localTagId), isTrue);
        expect(book202TagIds.contains('remote-mystery-id'), isTrue);
        expect(book202TagIds.contains('remote-scifi-id'), isFalse);
      },
    );

    test(
      'createSyncBackup and restoreBackupTagsOnly honor syncReading and syncCategories independently',
      () async {
        SharedPreferences.setMockInitialValues({});
        await TagStore.load();
        final source = await LibraryState.load();
        addTearDown(source.dispose);
        final tagId = await TagStore.shared.createTag('轻小说');
        await TagStore.shared.setTagsForBook(1, [tagId]);
        await source.addShelfBooks([demoNovels.first]);

        final categoriesOnly = await source.createSyncBackup(
          syncReading: false,
          syncCategories: true,
        );
        expect(categoriesOnly.records.containsKey('tag_defs'), isTrue);
        expect(categoriesOnly.records.containsKey('shelf'), isFalse);

        TagStore.resetForTesting();
        SharedPreferences.setMockInitialValues({});
        await TagStore.load();
        final target = await LibraryState.load();
        addTearDown(target.dispose);
        await target.restoreBackupTagsOnly(categoriesOnly);
        expect(TagStore.shared.tags.map((t) => t.name), contains('轻小说'));
        expect(target.shelf, isEmpty);
      },
    );

    test(
      'encodeBookSync enforces 512 MiB cumulative uncompressed ceiling across all entries',
      () {
        final largePayload = Uint8List(512 * 1024 * 1024 - 16);
        final bundle = BookSyncBundle(
          '{"format":"wenku8-library-backup","version":1,"records":{}}',
          [LocalBookInput('huge.txt', largePayload, text: 'extra text')],
        );
        expect(() => encodeBookSync(bundle), throwsFormatException);
      },
    );
  });

  group('P1-4, P1-5, P1-6 & P2-8: S3, WebDAV & CloudSource security', () {
    test(
      'S3BookClient.list decodes + as space when EncodingType is url and normalizes leading / in prefix',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousOverrides);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.headers.contentType = ContentType('application', 'xml');
          req.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <EncodingType>url</EncodingType>
  <CommonPrefixes>
    <Prefix>books/Light+Novels/</Prefix>
  </CommonPrefixes>
  <Contents>
    <Key>books/Volume+1+%2B+Bonus.epub</Key>
    <Size>4096</Size>
  </Contents>
</ListBucketResult>''');
          await req.response.close();
        });

        final config = CloudSourceConfig(
          kind: CloudSourceKind.s3,
          address: 'http://127.0.0.1:${server.port}',
          region: 'us-east-1',
          bucket: 'archive',
          username: 'ak',
          password: 'sk',
          prefix: '/books',
          pathStyle: true,
          allowHttp: true,
        );
        final http = CloudHttp();
        addTearDown(http.close);
        final client = S3BookClient(config, http: http);
        expect(client.root, 'books/');

        final listing = await client.list('books/');
        final names = listing.entries.map((e) => e.name).toList();
        expect(names, contains('Light Novels'));
        expect(names, contains('Volume 1 + Bonus.epub'));
      },
    );

    test(
      'AndroidCloudConfigStorage refuses plaintext SharedPreferences fallback on Android and scrubs legacy key',
      () async {
        AndroidCloudConfigStorage.resetForTesting();
        SharedPreferences.setMockInitialValues({
          'cloud_sources_fallback_v1': '{"legacy":"secret"}',
        });
        messenger.setMockMethodCallHandler(
          AndroidCloudConfigStorage.channel,
          null,
        );
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final storage = AndroidCloudConfigStorage();
          await expectLater(storage.read(), throwsA(isA<CloudSourceFailure>()));
          await expectLater(
            storage.write('{"s3":"secret"}'),
            throwsA(isA<CloudSourceFailure>()),
          );

          final vault = <String, String?>{};
          messenger.setMockMethodCallHandler(
            AndroidCloudConfigStorage.channel,
            (call) async {
              if (call.method == 'read') return vault['v'];
              if (call.method == 'write') {
                vault['v'] = call.arguments as String?;
                return null;
              }
              return null;
            },
          );
          final migrated = await storage.read();
          expect(migrated, '{"legacy":"secret"}');
          expect(vault['v'], '{"legacy":"secret"}');
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.containsKey('cloud_sources_fallback_v1'), isFalse);
        } finally {
          debugDefaultTargetPlatformOverride = null;
          messenger.setMockMethodCallHandler(
            AndroidCloudConfigStorage.channel,
            null,
          );
          AndroidCloudConfigStorage.resetForTesting();
        }
      },
    );

    test(
      'WebDavSecretStorage.readPasswordResult reports failed=true on native PlatformException instead of silently returning empty password',
      () async {
        WebDavSecretStorage.resetForTesting();
        messenger.setMockMethodCallHandler(WebDavSecretStorage.channel, (
          call,
        ) async {
          throw PlatformException(code: 'KEYSTORE_LOCKED', message: 'locked');
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(WebDavSecretStorage.channel, null);
          WebDavSecretStorage.resetForTesting();
        });

        final res = await WebDavSecretStorage.readPasswordResult();
        expect(res.failed, isTrue);
      },
    );

    test(
      'CloudHttp.resolveRelaxedHref resolves unescaped brackets in WebDAV hrefs without throwing FormatException',
      () {
        final base = Uri.parse('https://dav.example.com/books/');
        final resolved = CloudHttp.resolveRelaxedHref(
          base,
          '/books/[轻小说] 刀剑神域 [01].epub',
        );
        expect(resolved.host, 'dav.example.com');
        expect(resolved.pathSegments.last, '[轻小说] 刀剑神域 [01].epub');
      },
    );
  });

  group('P1-7 & P1-9: LanBookshelfServer & FontDownloadClient hardening', () {
    late PathProviderPlatform previousPaths;
    late Directory supportRoot;

    setUp(() async {
      previousPaths = PathProviderPlatform.instance;
      supportRoot = await Directory.systemTemp.createTemp('batch3-paths-');
      PathProviderPlatform.instance = _Batch3Paths(supportRoot.path);
    });

    tearDown(() async {
      PathProviderPlatform.instance = previousPaths;
      if (await supportRoot.exists()) {
        await supportRoot.delete(recursive: true);
      }
    });

    test(
      'LanBookshelfServer.isPrivateLanIpv4 accurately distinguishes RFC1918 ranges from 172.32+ and CGNAT',
      () {
        InternetAddress ip(int a, int b, int c, int d) =>
            InternetAddress.fromRawAddress(Uint8List.fromList([a, b, c, d]));

        expect(LanBookshelfServer.isPrivateLanIpv4(ip(10, 1, 2, 3)), isTrue);
        expect(LanBookshelfServer.isPrivateLanIpv4(ip(172, 16, 0, 1)), isTrue);
        expect(
          LanBookshelfServer.isPrivateLanIpv4(ip(172, 31, 255, 1)),
          isTrue,
        );
        expect(LanBookshelfServer.isPrivateLanIpv4(ip(172, 32, 0, 1)), isFalse);
        expect(LanBookshelfServer.isPrivateLanIpv4(ip(192, 168, 1, 5)), isTrue);
        expect(LanBookshelfServer.isPrivateLanIpv4(ip(100, 64, 0, 1)), isFalse);
      },
    );

    test(
      'LanBookshelfServer blocks DNS rebinding Host headers, uses URL fragment token, and rate-limits PIN brute force',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        final local = await LocalLibraryStore.load();
        final server = LanBookshelfServer(local: local, state: state);
        addTearDown(() async {
          HttpOverrides.global = previousOverrides;
          await server.stop();
          server.dispose();
          local.dispose();
          state.dispose();
        });

        await server.start(
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        expect(server.isRunning, isTrue);
        expect(server.url, contains('#token='));
        expect(server.url, isNot(contains('?token=')));

        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        // 1. DNS rebinding Host header rejected with 403
        final rebindReq = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/books'),
        );
        rebindReq.headers.set(HttpHeaders.hostHeader, 'attacker.evil.invalid');
        final rebindRes = await rebindReq.close();
        await rebindRes.drain<void>();
        expect(rebindRes.statusCode, HttpStatus.forbidden);

        // 2. Repeated wrong PIN triggers 429 rate limit
        var lastStatus = 0;
        for (var i = 0; i < 6; i++) {
          final authReq = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/api/books'),
          );
          authReq.headers.set(
            HttpHeaders.hostHeader,
            '127.0.0.1:${server.port}',
          );
          authReq.headers.set('x-shuyu-token', 'wrong-pin');
          final authRes = await authReq.close();
          await authRes.drain<void>();
          lastStatus = authRes.statusCode;
        }
        expect(lastStatus, HttpStatus.tooManyRequests);
      },
    );

    test(
      'LanBookshelfServer dispose during start leaves no running zombie server',
      () async {
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        final local = await LocalLibraryStore.load();
        addTearDown(() {
          local.dispose();
          state.dispose();
        });

        final server = LanBookshelfServer(local: local, state: state);
        final starting = server.start(
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        server.dispose();
        await starting;
        expect(server.isRunning, isFalse);
      },
    );

    test(
      'FontDownloadProgress handles total <= 0 and FontDownloadClient rejects HTTP/loopback',
      () async {
        expect(const FontDownloadProgress(128, 0).fraction, 0.0);
        expect(const FontDownloadProgress(128, 0).percent, 0);
        expect(const FontDownloadProgress(128, -1).percent, 0);

        final target = File('${supportRoot.path}/font.otf');
        final insecureClient = FontDownloadClient(
          sources: [Uri.parse('http://fonts.example.com/font.otf')],
        );
        await expectLater(
          insecureClient.download(
            target,
            cancellation: FontDownloadCancellation(),
            onProgress: (_) {},
          ),
          throwsFormatException,
        );
        expect(await target.exists(), isFalse);

        final payload = utf8.encode('synthetic font payload bytes');
        expect(sha256.convert(payload).toString().length, 64);
      },
    );
  });

  group('P1-15 & P2-7: ListeningController, HttpTtsStore & AppUpdates', () {
    test(
      'ListeningController resume and setVoice preserve explicit target chapter instead of jumping back to old savedCursor',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = ListeningStore(prefs);
        await store.saveCursor(
          const ListeningCursor(
            novelId: 1,
            chapterId: 0,
            revision: '',
            textOffset: 0,
            chapter: 0,
            paragraph: 0,
            start: 0,
            positionMs: 5000,
            segmentHash: 'legacy',
          ),
        );

        final output = FakeListeningOutput();
        final audio = FakeSpeechAudio()..fail = true;
        final controller = ListeningController(
          repository: const DemoNovelRepository(),
          audio: audio,
          store: store,
          outputFactory: (_) async => output,
        );
        addTearDown(controller.dispose);

        final book = demoNovels.first.withChapters(const [
          NovelChapter('第一章', '第一章第一段。'),
          NovelChapter('第二章', '第二章第一段。'),
          NovelChapter('第三章', '第三章第一段。\n\n第三章第二段。'),
        ]);

        // Explicitly jump to chapter 2 (not chapter 0 in savedCursor) while offline/failing
        await controller.start(book, chapter: 2, paragraph: 1, resume: false);
        expect(controller.snapshot.value.phase, ListeningPhase.failed);
        expect(controller.snapshot.value.chapter, 2);

        // Retrying via resume() must stay on chapter 2, paragraph 1!
        audio.fail = false;
        await controller.resume();
        expect(controller.snapshot.value.phase, ListeningPhase.playing);
        expect(controller.snapshot.value.chapter, 2);
        expect(controller.snapshot.value.current?.paragraph, 1);
      },
    );

    test(
      'ListeningAudioHandler seek and fastForward/rewind cross segment boundaries on chapter timeline',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final output = FakeListeningOutput();
        final audio = FakeSpeechAudio();
        final controller = ListeningController(
          repository: const DemoNovelRepository(),
          audio: audio,
          store: ListeningStore(prefs),
          outputFactory: (_) async => output,
        );
        final handler = ListeningAudioHandler(controller);
        addTearDown(controller.dispose);

        final book = demoNovels.first.withChapters(const [
          NovelChapter('第一章', '第一段测试文本。\n\n第二段测试文本。'),
        ]);
        await controller.start(book, chapter: 0);
        expect(controller.snapshot.value.segment, 0);

        // Advance to segment 1 so both segment 0 (30s) and segment 1 (30s) are measured
        output.complete();
        await listeningMicrotasks();
        expect(controller.snapshot.value.segment, 1);
        output.positionEvents.add(const Duration(seconds: 10));
        await listeningMicrotasks();
        expect(
          controller.chapterProgress.value.position,
          const Duration(seconds: 40),
        );

        // Scrubbing MediaSession back to 12s jumps back to segment 0 at 12s!
        await handler.seek(const Duration(seconds: 12));
        expect(controller.snapshot.value.segment, 0);
        expect(
          controller.progress.value.position,
          const Duration(seconds: 12),
        );

        // Fast-forwarding twice (+15s, +15s) crosses from segment 0 (12s -> 27s -> 42s) into segment 1 at 12s!
        await handler.fastForward();
        expect(controller.snapshot.value.segment, 0);
        expect(
          controller.progress.value.position,
          const Duration(seconds: 27),
        );
        await handler.fastForward();
        expect(controller.snapshot.value.segment, 1);
        expect(
          controller.progress.value.position,
          const Duration(seconds: 12),
        );
      },
    );

    test(
      'HttpTtsStore single-pass template substitution prevents second-pass injection, escapes SSML XML, and isolates voice signatures',
      () async {
        final jsonBody = HttpTtsStore.substituteTemplate(
          r'{"text":"{{speakText}}","speed":${speakSpeed}}',
          text: r'Literal ${speakSpeed} and "quotes"',
          speed: 1.5,
          urlEncodeText: false,
          contentType: 'application/json; charset=utf-8',
        );
        expect(
          jsonBody,
          r'{"text":"Literal ${speakSpeed} and \"quotes\"","speed":15}',
        );

        final ssmlBody = HttpTtsStore.substituteTemplate(
          '<speak><prosody rate="{{speakSpeedRate}}">{{speakText}}</prosody></speak>',
          text: '5 < 10 & "hello"',
          speed: 1.0,
          urlEncodeText: false,
          contentType: 'application/ssml+xml',
        );
        expect(
          ssmlBody,
          '<speak><prosody rate="1.00">5 &lt; 10 &amp; &quot;hello&quot;</prosody></speak>',
        );

        const e1 = HttpTtsEngineConfig(
          id: 'custom-1',
          name: 'Engine',
          url: 'https://tts.example.com/v1?text={{speakText}}',
        );
        const e2 = HttpTtsEngineConfig(
          id: 'custom-1',
          name: 'Engine',
          url: 'https://tts.example.com/v2?text={{speakText}}',
        );
        expect(e1.toSpeechVoice().engine, isNot(e2.toSpeechVoice().engine));

        SharedPreferences.setMockInitialValues({});
        await HttpTtsStore.shared.ensureInitialized();
        await HttpTtsStore.shared.upsertEngine(e1);
        addTearDown(() => HttpTtsStore.shared.removeEngine('custom-1'));
        await expectLater(
          HttpTtsStore.shared.synthesize(
            '测试文本',
            const SpeechVoice(
              id: 'deleted-engine-id',
              label: 'Deleted',
              source: ListeningSource.custom,
              engine: 'http_tts',
            ),
            SpeechCancellation(),
          ),
          throwsA(isA<SpeechFailure>()),
        );
      },
    );

    test(
      'AppUpdates.check recovers when lastAppUpdateCheck is in the future after system clock rollback',
      () async {
        SharedPreferences.setMockInitialValues({
          'lastAppUpdateCheck': DateTime(2099, 1, 1).millisecondsSinceEpoch,
        });
        final prefs = await SharedPreferences.getInstance();
        final release = AppRelease.fromGithub({
          'tag_name': 'v1.9.0',
          'draft': false,
          'prerelease': false,
          'body': 'Fixes',
          'assets': [
            {
              'name': 'wenku8-1.9.0-arm64-v8a.apk',
              'size': 1024,
              'browser_download_url':
                  'https://github.com/sushi342119/Shuyu/releases/download/v1.9.0/wenku8-1.9.0-arm64-v8a.apk',
            },
          ],
        }, 'sushi342119/Shuyu');
        final source = _StubUpdateSource(release);
        final updates = AppUpdates(
          preferences: prefs,
          source: source,
          platform: _StubUpdatePlatform(),
          clock: () => DateTime(2026, 11, 14),
        );
        addTearDown(updates.dispose);

        await updates.check(automatic: true);
        expect(source.checks, 1);
        expect(updates.available, isTrue);
      },
    );

    testWidgets(
      'AppUpdatePage renders indeterminate progress without NaN error when asset size is 0',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final release = AppRelease(
          tag: 'v1.9.0',
          version: ReleaseVersion.parse('v1.9.0')!,
          notes: 'Notes',
          page: Uri.parse(
            'https://github.com/sushi342119/Shuyu/releases/tag/v1.9.0',
          ),
          assets: [
            UpdateAsset(
              name: 'wenku8-1.9.0-arm64-v8a.apk',
              url: Uri.parse(
                'https://github.com/sushi342119/Shuyu/releases/download/v1.9.0/wenku8-1.9.0-arm64-v8a.apk',
              ),
              size: 0,
            ),
          ],
        );
        final updates = AppUpdates(
          preferences: prefs,
          source: _StubUpdateSource(release),
          platform: _StubUpdatePlatform(),
        );
        addTearDown(updates.dispose);
        await updates.check();
        updates
          ..downloading = true
          ..bytes = 128;

        await tester.pumpWidget(
          MaterialApp(home: AppUpdatePage(updates: updates)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      },
    );
  });

  group('P1-18 & P2-11: ReadingActivity idle cap, Report date clamp, poster ratio & narrow charts', () {
    test(
      'ReadingActivitySession caps unattended idle time at idleTimeout and resumes on notifyInteraction',
      () async {
        final store = ReadingActivityStore();
        addTearDown(store.dispose);
        var now = DateTime(2026, 11, 14, 21, 0, 0);
        var elapsed = Duration.zero;
        final session = ReadingActivitySession(
          store: store,
          bookId: 88,
          now: () => now,
          elapsed: () => elapsed,
          idleTimeout: const Duration(minutes: 5),
        );

        session.setActive(true);
        // Simulate 2 hours unattended with screen kept awake
        elapsed = const Duration(hours: 2);
        now = now.add(elapsed);
        session.setActive(false);
        await Future<void>.delayed(Duration.zero);

        // Only 5 minutes (300s) accrued instead of 7200s!
        expect(store.totalSeconds, 300);

        // User interacts again after reopening/resuming
        session.setActive(true);
        elapsed += const Duration(minutes: 2);
        now = now.add(const Duration(minutes: 2));
        session.notifyInteraction();
        elapsed += const Duration(minutes: 2);
        now = now.add(const Duration(minutes: 2));
        session.dispose();
        await Future<void>.delayed(Duration.zero);

        expect(store.totalSeconds, 300 + 240);
      },
    );

    testWidgets(
      'ReadingReportDateSheet clamps future until and pre-2020 from dates without CupertinoDatePicker AssertionError',
      (tester) async {
        final today = DateTime(2026, 11, 14);
        final outOfBoundsRange = ReadingReportRange(
          period: 30,
          from: DateTime(2015, 5, 1),
          until: DateTime(2028, 1, 10),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReadingReportDateSheet(
                today: today,
                range: outOfBoundsRange,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('结束日期'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(CupertinoDatePicker), findsOneWidget);
      },
    );

    test(
      'ReadingReportPage.posterPixelRatioForSize caps tall posters below 8000px GPU texture limit and ReadingStatisticsData exposes periodLongestStreak',
      () async {
        expect(
          ReadingReportPage.posterPixelRatioForSize(const Size(400, 1200)),
          2.5,
        );
        final tallRatio = ReadingReportPage.posterPixelRatioForSize(
          const Size(420, 5000),
        );
        expect(tallRatio * 5000, lessThanOrEqualTo(8000.0));

        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        // 5-day streak 60 days ago (outside 7-day period) + 2-day streak inside 7-day period
        for (var d = 0; d < 5; d++) {
          await state.readingActivity.recordInterval(
            bookId: 1,
            startedAt: DateTime(2026, 9, 1 + d, 20),
            elapsed: const Duration(minutes: 15),
          );
        }
        for (var d = 0; d < 2; d++) {
          await state.readingActivity.recordInterval(
            bookId: 1,
            startedAt: DateTime(2026, 11, 13 + d, 20),
            elapsed: const Duration(minutes: 15),
          );
        }
        final data = ReadingStatisticsData(
          state: state,
          repository: const DemoNovelRepository(),
          now: DateTime(2026, 11, 14),
          period: 7,
        );
        expect(data.longestStreak, 5);
        expect(data.periodLongestStreak, 2);
      },
    );

    testWidgets(
      'ReadingRhythmChart handles ultra-narrow viewport and tap without Infinity.toInt crash',
      (tester) async {
        final dates = [
          DateTime(2026, 11, 13),
          DateTime(2026, 11, 14),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 10,
                  height: 180,
                  child: ReadingRhythmChart(
                    dates: dates,
                    minutes: const [12.0, 25.0],
                    averageMinutes: const [12.0, 18.5],
                    selectedIndex: 0,
                    onSelected: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('reading-rhythm-gesture')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/archive_random_pick_card.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/listening/cache.dart';
import 'package:shuyu/listening/edge_tts.dart';
import 'package:shuyu/local_platform.dart';
import 'package:shuyu/reader_status.dart';
import 'package:shuyu/reading_widget_cards.dart';
import 'package:shuyu/reading_widget_controller.dart';
import 'package:shuyu/reading_widget_settings_page.dart';
import 'package:shuyu/reading_widget_skin.dart';

class _Batch4Paths extends PathProviderPlatform {
  _Batch4Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';

  @override
  Future<String?> getExternalStoragePath() async => '$root/ext';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('P2-10: ReadingWidgetCardEditor & persistent card staging', () {
    testWidgets(
      'ReadingWidgetCardEditor renders safe fallback before attach and when cardId is missing',
      (tester) async {
        messenger.setMockMethodCallHandler(ReadingWidgetBridge.channel, (
          MethodCall call,
        ) async {
          if (call.method == 'cardsSupported') return false;
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            ReadingWidgetBridge.channel,
            null,
          ),
        );

        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final state = LibraryState(prefs);

        await tester.pumpWidget(
          MaterialApp(
            home: ReadingWidgetCardEditor(
              state: state,
              cardId: 'removed_card_id',
            ),
          ),
        );

        // First synchronous frame before _prepare() completes must not throw StateError.
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('reading-widget-missing-state')),
          findsOneWidget,
        );
        expect(find.text('正在加载小组件配置…'), findsOneWidget);

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final missingFinder = find.byKey(
          const ValueKey('reading-widget-missing-state'),
        );
        expect(missingFinder, findsOneWidget);
        expect(tester.widget<Text>(missingFinder).data, '未找到对应桌面小组件');
      },
    );

    test(
      'ReadingWidgetCards stages PNGs in support directory and regenerates missing cached files',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('shuyu_batch4_');
        final previousPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Batch4Paths(tempDir.path);
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final publishedPayloads = <List<Map<Object?, Object?>>>[];
        messenger.setMockMethodCallHandler(ReadingWidgetBridge.channel, (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'cardsSupported':
              return true;
            case 'publishCards':
              final args = call.arguments as Map<Object?, Object?>;
              final rawCards = args['cards'] as List<Object?>;
              publishedPayloads.add(
                rawCards.cast<Map<Object?, Object?>>(),
              );
              return null;
            case 'publishSnapshot':
            case 'consumeOpenRequest':
              return null;
            default:
              return null;
          }
        });

        try {
          SharedPreferences.setMockInitialValues({
            ReadingWidgetCards.preferenceKey: jsonEncode([
              const ReadingWidgetCardConfig(
                id: 'focus',
                design: ReadingWidgetDesign.focus,
              ).toJson(),
            ]),
          });
          final prefs = await SharedPreferences.getInstance();
          final state = LibraryState(prefs);
          final cards = ReadingWidgetCards.forState(state);

          await cards.attach();

          expect(cards.error, isNull);
          expect(publishedPayloads, hasLength(1));
          final firstImages =
              (publishedPayloads.last.single['images'] as Map<Object?, Object?>)
                  .cast<String, String>();
          expect(firstImages, isNotEmpty);

          for (final imagePath in firstImages.values) {
            expect(
              imagePath,
              startsWith('${tempDir.path}/support/reading-cards-staging-v1/'),
            );
            expect(File(imagePath).existsSync(), isTrue);
          }
          expect(Directory('${tempDir.path}/tmp').existsSync(), isFalse);

          // Delete one staged PNG file while visual signature remains unchanged.
          final deletedKey = firstImages.keys.first;
          final deletedPath = firstImages[deletedKey]!;
          await File(deletedPath).delete();
          await cards.publish();

          expect(cards.error, isNull);
          expect(publishedPayloads, hasLength(2));
          final secondImages =
              (publishedPayloads.last.single['images'] as Map<Object?, Object?>)
                  .cast<String, String>();
          expect(secondImages[deletedKey], isNot(equals(deletedPath)));
          for (final imagePath in secondImages.values) {
            expect(File(imagePath).existsSync(), isTrue);
          }

          cards.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        } finally {
          debugDefaultTargetPlatformOverride = null;
          messenger.setMockMethodCallHandler(ReadingWidgetBridge.channel, null);
          PathProviderPlatform.instance = previousPathProvider;
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );
  });

  group('P0-11: Android-only platform gates & MissingPluginException guards', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
      messenger.setMockMethodCallHandler(SpeechAudioCache.system, null);
    });

    test('LocalPlatform capabilities disable unsupported iOS target cleanly', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(LocalPlatform.readerAppearance, isFalse);
      expect(LocalPlatform.listening, isFalse);
      expect(LocalPlatform.fileActions, isFalse);
      expect(LocalPlatform.volumePaging, isFalse);
      expect(ReadingWidgetBridge.supported, isFalse);
      expect(await LocalPlatform.deviceProfile(), isNull);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(LocalPlatform.readerAppearance, isTrue);
      expect(LocalPlatform.listening, isTrue);
      expect(LocalPlatform.fileActions, isTrue);
      expect(LocalPlatform.volumePaging, isTrue);
      expect(ReadingWidgetBridge.supported, isTrue);
      // No mock handler registered -> MissingPluginException caught cleanly.
      expect(await LocalPlatform.deviceProfile(), isNull);
    });

    test('SpeechAudioCache.offlineVoices handles MissingPluginException and PlatformException', () async {
      final tempDir = Directory.systemTemp.createTempSync('shuyu_speech_');
      try {
        final cache = SpeechAudioCache(tempDir, EdgeSpeechClient());
        // Unregistered channel -> MissingPluginException -> empty list.
        expect(await cache.offlineVoices(), isEmpty);

        messenger.setMockMethodCallHandler(SpeechAudioCache.system, (
          MethodCall call,
        ) async {
          throw PlatformException(code: 'unavailable', message: 'no tts');
        });
        expect(await cache.offlineVoices(), isEmpty);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'ReaderStatusFooter lifecycle pause and dispose suppress MissingPluginException',
      (tester) async {
        expect(LocalPlatform.readerAppearance, isTrue);
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: ReaderStatusFooter()),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(tester.takeException(), isNull);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('P2-13: ArchiveRandomPickCard dynamic duration update', () {
    testWidgets(
      'switching totalDuration from 900ms to 2400ms updates animation controller duration',
      (tester) async {
        Widget buildCard(Duration duration) => MaterialApp(
          home: Scaffold(
            body: ArchiveRandomPickCard<String>(
              books: const ['甲书', '乙书'],
              titleOf: (book) => book,
              authorOf: (_) => '作者',
              onOpenDetail: (_) {},
              totalDuration: duration,
            ),
          ),
        );

        await tester.pumpWidget(buildCard(const Duration(milliseconds: 900)));
        await tester.pumpWidget(buildCard(const Duration(milliseconds: 2400)));

        await tester.tap(find.text('抽阅一本'));
        await tester.pump();
        expect(find.text('抽阅中…'), findsOneWidget);

        // At 1200ms, quick (900ms) would already be finished, while ceremony (2400ms) is still spinning.
        await tester.pump(const Duration(milliseconds: 1200));
        expect(find.text('抽阅中…'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump(const Duration(microseconds: 1));
        expect(find.text('抽阅中…'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('P2-9: LiquidGlassViewController rebinding', () {
    testWidgets(
      'swapping LiquidGlassView controller detaches previous controller and attaches new one',
      (tester) async {
        final controllerA = LiquidGlassViewController();
        final controllerB = LiquidGlassViewController();

        Widget buildView(LiquidGlassViewController controller) => MaterialApp(
          home: Scaffold(
            body: LiquidGlassView(
              controller: controller,
              realTimeCapture: false,
              useImpellerBackdrop: true,
              backgroundWidget: const ColoredBox(color: Colors.white),
              child: const SizedBox(width: 120, height: 120),
            ),
          ),
        );

        await tester.pumpWidget(buildView(controllerA));
        await tester.pump();
        final firstCapture = controllerA.captureOnce();
        await tester.pump();
        await firstCapture;
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(buildView(controllerB));
        await tester.pump();

        // Detached controllerA completes immediately without waiting on endOfFrame;
        // newly attached controllerB drives the view cleanly.
        controllerA.startRealtimeCapture();
        controllerA.stopRealtimeCapture();
        await controllerA.captureOnce();

        controllerB.startRealtimeCapture();
        controllerB.stopRealtimeCapture();
        final secondCapture = controllerB.captureOnce();
        await tester.pump();
        await secondCapture;
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();
        await controllerB.captureOnce();
        controllerB.startRealtimeCapture();
        expect(tester.takeException(), isNull);
      },
    );
  });
}

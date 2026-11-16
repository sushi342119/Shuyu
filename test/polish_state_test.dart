import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/novel_feed_controller.dart';
import 'package:shuyu/reader_content.dart';
import 'package:shuyu/ui_notifiers.dart';

import 'support/offline_fixture.dart';

class _Search extends DemoNovelRepository {
  final calls = <String>[];
  final replies = <String, Completer<NovelPage>>{};
  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) {
    calls.add(query);
    return replies.putIfAbsent(query, Completer<NovelPage>.new).future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '120 input edits request one final query and isolate stale responses',
    (tester) async {
      final repository = _Search();
      final feed = NovelFeedController(repository, search: true);
      addTearDown(feed.dispose);
      final old = feed.searchFor('old');
      for (var index = 0; index < 120; index++) {
        feed.scheduleSearch('query-$index');
        await tester.pump(const Duration(milliseconds: 2));
      }
      expect(repository.calls, ['old']);
      repository.replies['old']!.complete(
        NovelPage(items: [demoNovels.first], page: 1),
      );
      await old;
      expect(feed.items, isEmpty);
      expect(feed.loading, isTrue);
      await feed.loadMore();
      expect(repository.calls, ['old']);
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, ['old', 'query-119']);
      repository.replies['query-119']!.complete(
        NovelPage(items: [demoNovels.last], page: 1, totalPages: 1),
      );
      await tester.pump();
      expect(feed.items.single, demoNovels.last);
      expect(feed.loading, isFalse);
    },
  );

  testWidgets(
    'search submit flushes the timer and disposal cancels pending work',
    (tester) async {
      final repository = _Search();
      final feed = NovelFeedController(repository, search: true);
      feed.scheduleSearch('submitted');
      final submitted = feed.searchFor('submitted');
      expect(repository.calls, ['submitted']);
      repository.replies['submitted']!.complete(
        const NovelPage(items: [], page: 1, totalPages: 0),
      );
      await submitted;
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, ['submitted']);
      feed.scheduleSearch('closed');
      feed.cancelScheduledSearch();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, ['submitted']);
      feed.scheduleSearch('disposed');
      feed.dispose();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, ['submitted']);
    },
  );

  testWidgets(
    'repeated submit shares in-flight work and a failed page can restart the same query',
    (tester) async {
      final repository = _Search();
      final feed = NovelFeedController(repository, search: true);
      addTearDown(feed.dispose);
      final initial = feed.searchFor('same');
      await feed.searchFor('same');
      expect(repository.calls, ['same']);
      repository.replies['same']!.complete(
        NovelPage(items: [demoNovels.first], page: 1, totalPages: 2),
      );
      await initial;
      final next = repository.replies['same'] = Completer<NovelPage>();
      final more = feed.loadMore();
      next.completeError(StateError('page two failed'));
      await more;
      expect(feed.page, 1);
      expect(feed.error, isNotNull);
      final retry = repository.replies['same'] = Completer<NovelPage>();
      feed.scheduleSearch('same');
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, ['same', 'same', 'same']);
      retry.complete(
        NovelPage(items: [demoNovels.last], page: 1, totalPages: 1),
      );
      await tester.pump();
      expect(feed.error, isNull);
      expect(feed.items.single, demoNovels.last);
    },
  );

  testWidgets(
    'visual notifications are coalesced once per frame and disposed callbacks stay quiet',
    (tester) async {
      final notifier = FrameChangeNotifier();
      var notifications = 0;
      notifier.addListener(() => notifications++);
      for (var index = 0; index < 120; index++) {
        notifier.notifyListeners();
      }
      expect(notifications, 0);
      await tester.pump();
      expect(notifications, 1);
      notifier.notifyListeners();
      notifier.dispose();
      await tester.pump();
      expect(notifications, 1);
    },
  );

  testWidgets(
    'retained inactive tabs do not rebuild and catch up on activation',
    (tester) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      var builds = 0;
      Widget tree(bool active) => Directionality(
        textDirection: TextDirection.ltr,
        child: TickerMode(
          enabled: active,
          child: ActiveListenableBuilder(
            listenable: value,
            builder: (_) {
              builds++;
              return Text('${value.value}');
            },
          ),
        ),
      );
      await tester.pumpWidget(tree(false));
      final baseline = builds;
      for (var index = 1; index <= 120; index++) {
        value.value = index;
        await tester.pump();
      }
      expect(builds, baseline);
      await tester.pumpWidget(tree(true));
      expect(builds, baseline + 1);
      expect(find.text('120'), findsOneWidget);
    },
  );

  test(
    'bad appearance preferences fall back and a typography transaction notifies once',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme': 3,
        'reduceMotion': 'bad',
        'glassBlur': double.nan,
        'glassOpacity': 'bad',
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      expect(state.theme, ThemeMode.system);
      expect(state.reduceMotion, isFalse);
      expect(state.glassBlur, 8);
      expect(state.glassOpacity, .87);
      var typography = 0;
      var appearance = 0;
      state.readerSettingsChanges.addListener(() => typography++);
      state.appearanceChanges.addListener(() => appearance++);
      await state.setTypography(fontSize: 23, lineHeight: 1.95);
      expect(typography, 1);
      await state.setTypography(fontSize: 23, lineHeight: 1.95);
      await state.setGlassBlur(double.nan);
      await state.setGlassOpacity(double.infinity);
      await state.setTheme(ThemeMode.system);
      await state.setReduceMotion(false);
      expect(typography, 1);
      expect(appearance, 0);
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.fontSize, 23);
      expect(restored.lineHeight, 1.95);
    },
  );

  test(
    'paragraph anchors and text scale survive resume and bookmark persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final book = offlineFixtureBook(71);
      await state.savePosition(
        novel: book,
        chapter: 0,
        offset: 1500,
        maximum: 5000,
        width: 400,
        paragraphIndex: 19,
        paragraphFraction: .37,
        textScale: 1.3,
      );
      await state.addBookmark(novel: book, position: state.positionFor(71)!);
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.positionFor(71)!.paragraphIndex, 19);
      expect(restored.bookmarksFor(71).single.position.paragraphFraction, .37);
      expect(restored.positionFor(71)!.textScale, 1.3);
      final legacy = ReadingPosition.fromJson({
        'chapter': 0,
        'paragraphIndex': -2,
        'paragraphFraction': double.nan,
        'textScale': 'bad',
      });
      expect(legacy.paragraphIndex, isNull);
      expect(legacy.paragraphFraction, 0);
      expect(legacy.textScale, 1);
    },
  );

  test(
    'rapid shelf toggles serialize snapshots without changing final membership',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final book = offlineFixtureBook(71);
      await Future.wait(
        List.generate(41, (_) => state.toggleShelf(71, novel: book)),
      );
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.contains(71), isTrue);
      expect(restored.cachedNovel(71)!.title, book.title);
      expect(state.debugMetadataEncodeCount, 1);
    },
  );

  test(
    'hard-wrapped mid-sentence paragraphs are merged while distinct paragraphs stay separate',
    () async {
      final rawTxt =
          '少女推开木门，微凉的夜风迎面吹来，\n吹散了屋里残留的茶香。\n\n'
          '“你终于来了，我还以为你今天不会经过这座桥，\n\n结果还是让我等到了。”\n\n'
          '少年只是轻轻点头，没有多说什么。';
      final parsed = await ReaderContent.parse(rawTxt);
      expect(parsed.paragraphs, [
        '少女推开木门，微凉的夜风迎面吹来，吹散了屋里残留的茶香。',
        '“你终于来了，我还以为你今天不会经过这座桥，结果还是让我等到了。”',
        '少年只是轻轻点头，没有多说什么。',
      ]);
    },
  );
}

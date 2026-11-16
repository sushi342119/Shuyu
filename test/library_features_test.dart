import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/novel_feed_controller.dart';

Novel _book(int id, {List<NovelChapter> chapters = const []}) => Novel(
  id: id,
  title: '作品 $id',
  author: '作者',
  genre: '轻小说',
  summary: '介绍',
  colors: const [Colors.blue, Colors.black],
  chapters: chapters,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed next page retains items and cursor and requires explicit retry',
    () async {
      final calls = <(int, bool)>[];
      var fail = true;
      final feed = NovelFeedController(
        _PagedRepository((sort, page, refresh) async {
          calls.add((page, refresh));
          if (page == 2 && fail) throw StateError('network');
          return NovelPage(items: [_book(page)], page: page, totalPages: 2);
        }),
      );
      addTearDown(feed.dispose);
      await feed.loadInitial();
      expect(feed.resultRevision, 1);
      expect(feed.resultStartIndex, 0);
      await feed.loadMore();
      expect(feed.resultRevision, 1);
      expect(feed.items.single.id, 1);
      expect(feed.page, 1);
      await feed.loadMore();
      expect(calls.length, 2);
      fail = false;
      await feed.retry();
      expect(calls.last, (2, true));
      expect(feed.items.map((b) => b.id), [1, 2]);
      expect(feed.resultRevision, 2);
      expect(feed.resultStartIndex, 1);
      expect(feed.hasMore, isFalse);
    },
  );

  test(
    'refresh errors keep old content and retry starts from page one',
    () async {
      var fail = false;
      final calls = <int>[];
      final feed = NovelFeedController(
        _PagedRepository((sort, page, refresh) async {
          calls.add(page);
          if (fail) throw StateError('offline');
          return NovelPage(items: [_book(page)], page: page, totalPages: 3);
        }),
      );
      addTearDown(feed.dispose);
      await feed.loadInitial();
      await feed.loadMore();
      fail = true;
      await feed.refresh();
      expect(feed.page, 2);
      expect(feed.items.length, 2);
      expect(feed.refreshFailed, isTrue);
      fail = false;
      await feed.retry();
      expect(calls.last, 1);
      expect(feed.items.single.id, 1);
    },
  );

  test(
    'switching sort isolates late responses and duplicate books are merged',
    () async {
      final pending = Completer<NovelPage>();
      final feed = NovelFeedController(
        _PagedRepository((sort, page, refresh) async {
          if (sort == NovelSort.lastUpdate) return pending.future;
          return NovelPage(
            items: [_book(9), if (page > 1) _book(10)],
            page: page,
            totalPages: 2,
          );
        }),
      );
      addTearDown(feed.dispose);
      final old = feed.loadInitial();
      await feed.selectSort(NovelSort.allVisit);
      pending.complete(NovelPage(items: [_book(1)], page: 1, totalPages: 1));
      await old;
      expect(feed.items.single.id, 9);
      await feed.loadMore();
      expect(feed.items.map((b) => b.id), [9, 10]);
    },
  );

  test(
    'dispose ignores an outstanding page without notifying listeners',
    () async {
      final pending = Completer<NovelPage>();
      final feed = NovelFeedController(
        _PagedRepository((_, _, _) => pending.future),
      );
      var notifications = 0;
      feed.addListener(() => notifications++);
      final loading = feed.loadInitial();
      feed.dispose();
      pending.complete(const NovelPage(items: [], page: 1, totalPages: 0));
      await loading;
      expect(notifications, 1);
    },
  );

  test(
    'saved metadata is independent of recent results and excludes chapter bodies',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final book = _book(
        5000,
        chapters: const [NovelChapter('标题', '正文不应写入快照', id: 50)],
      );
      await state.toggleShelf(book.id, novel: book);
      final reloaded = await LibraryState.load();
      expect(reloaded.shelf, {5000});
      expect(reloaded.cachedNovel(5000)!.title, book.title);
      expect(reloaded.cachedNovel(5000)!.chapterCount, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('novel_meta_5000'), isNot(contains('正文不应写入快照')));
    },
  );

  test(
    'legacy IDs and chapter records survive malformed cache records',
    () async {
      SharedPreferences.setMockInitialValues({
        'shelf': ['5000', 'oops', '0', '-1'],
        'chapter_5000': 7,
        'chapter_999': 'broken',
        'novel_meta_5000': '{broken',
        'reading_position_5000': '[]',
      });
      final state = await LibraryState.load();
      expect(state.shelf, {5000});
      expect(state.chapterFor(5000), 7);
      expect(state.cachedNovel(5000), isNull);
      expect(state.positionFor(5000), isNull);
    },
  );

  test(
    'positions persist in order and stable chapter IDs survive a reordered directory',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final book = _book(
        99,
        chapters: const [
          NovelChapter('A', '', id: 100),
          NovelChapter('B', '', id: 200),
        ],
      );
      final first = state.savePosition(
        novel: book,
        chapter: 1,
        offset: 100,
        maximum: 1000,
        width: 400,
      );
      final last = state.savePosition(
        novel: book,
        chapter: 1,
        offset: 350,
        maximum: 1000,
        width: 400,
      );
      await Future.wait([first, last]);
      final reloaded = await LibraryState.load();
      expect(reloaded.positionFor(99)!.offset, 350);
      expect(reloaded.positionFor(99)!.fraction, .35);
      final changed = book.withChapters([
        const NovelChapter('新增', '', id: 50),
        ...book.chapters,
      ]);
      expect(reloaded.chapterForNovel(changed), 2);
      final cached = reloaded.cachedNovel(99)!;
      expect(reloaded.chapterForNovel(cached), 1);
    },
  );

  test(
    'removing a shelf book preserves progress and supports re-adding',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.toggleShelf(1, novel: _book(1));
      await state.setChapter(1, 4);
      await state.toggleShelf(1);
      expect(state.contains(1), isFalse);
      expect(state.chapterFor(1), 4);
      await state.toggleShelf(1);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('novel_meta_1')!)['title'], '作品 1');
      expect(state.addedAt(1), greaterThan(0));
    },
  );
}

import 'package:shuyu/reader_underline.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/reader_paging.dart';
import 'package:shuyu/reader_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const size = Size(400, 800);
  const left = Offset(40, 200), leftLow = Offset(40, 700);
  const centre = Offset(200, 400);
  const right = Offset(360, 200), rightLow = Offset(360, 700);

  test('tap paging off: every tap toggles controls', () {
    const prefs = ReaderPreferences();
    for (final p in [left, centre, right]) {
      expect(readerTapAction(p, size, prefs), ReaderTapAction.toggle);
    }
  });

  test('常规 layout: left previous, centre toggle, right next', () {
    const prefs = ReaderPreferences(tapPaging: true);
    expect(readerTapAction(left, size, prefs), ReaderTapAction.previous);
    expect(readerTapAction(centre, size, prefs), ReaderTapAction.toggle);
    expect(readerTapAction(right, size, prefs), ReaderTapAction.next);
  });

  test('右手 layout splits the right column', () {
    const prefs = ReaderPreferences(
      tapPaging: true,
      tapLayout: ReaderTapLayout.rightHand,
    );
    expect(readerTapAction(right, size, prefs), ReaderTapAction.previous);
    expect(readerTapAction(rightLow, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(left, size, prefs), ReaderTapAction.next);
  });

  test('左手 layout splits the left column', () {
    const prefs = ReaderPreferences(
      tapPaging: true,
      tapLayout: ReaderTapLayout.leftHand,
    );
    expect(readerTapAction(left, size, prefs), ReaderTapAction.previous);
    expect(readerTapAction(leftLow, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(right, size, prefs), ReaderTapAction.next);
  });

  test('both sides next', () {
    const prefs = ReaderPreferences(tapPaging: true, tapBothSidesNext: true);
    expect(readerTapAction(left, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(right, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(centre, size, prefs), ReaderTapAction.toggle);
  });

  test('reader mode defaults stay on scroll and survive a round trip', () {
    const prefs = ReaderPreferences();
    expect(prefs.mode, ReaderMode.scroll);
    expect(prefs.pageEffect, ReaderPageEffect.slide);
    final paged = prefs.copyWith(mode: ReaderMode.vertical, tapPaging: true);
    final back = ReaderPreferences.fromJson(paged.toJson());
    expect(back.mode, ReaderMode.vertical);
    expect(back.tapPaging, isTrue);
    expect(back.pageEffect, ReaderPageEffect.slide);
  });

  test('legacy unconfigured staggered pageEffect migrates to slide while explicit choice stays', () {
    final legacy = ReaderPreferences.fromJson(const {
      'mode': 'paged',
      'pageEffect': 'staggered',
    });
    expect(legacy.pageEffect, ReaderPageEffect.slide);

    const explicitStaggered = ReaderPreferences(
      mode: ReaderMode.paged,
      pageEffect: ReaderPageEffect.staggered,
    );
    final roundTrip = ReaderPreferences.fromJson(explicitStaggered.toJson());
    expect(roundTrip.pageEffect, ReaderPageEffect.staggered);

    const explicitCover = ReaderPreferences(
      mode: ReaderMode.paged,
      pageEffect: ReaderPageEffect.cover,
    );
    expect(
      ReaderPreferences.fromJson(explicitCover.toJson()).pageEffect,
      ReaderPageEffect.cover,
    );
  });

  test('shelfChanges isolates shelf listeners from scroll savePosition and theme toggles', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    var shelfTicks = 0;
    state.shelfChanges.addListener(() => shelfTicks++);

    const book = Novel(
      id: 1073741825,
      title: '性能隔离测试',
      author: '测试作者',
      genre: '本地',
      summary: '简介',
      colors: [],
      chapters: [NovelChapter('第一章', '正文内容', id: 1)],
    );
    await state.setShelfMembership(book.id, true, novel: book);
    expect(shelfTicks, 1);

    await state.savePosition(
      novel: book,
      chapter: 0,
      offset: 120,
      maximum: 600,
      width: 390,
    );
    await state.setTheme(ThemeMode.dark);
    await state.setGlassBlur(12);
    expect(shelfTicks, 1);

    await state.setShelfMembership(book.id, false);
    expect(shelfTicks, 2);
  });

  test('bookmarks and underlines defer JSON decoding at cold start and hydrate lazily per book', () async {
    const bookA = 1073741901;
    const bookB = 1073741902;
    final seededMark = ReaderBookmark(
      id: 'mark-a1',
      chapterTitle: '第一章',
      quote: '月光落在窗台上',
      position: const ReadingPosition(
        chapter: 0,
        chapterId: 101,
        paragraphIndex: 1,
        textOffset: 0,
        offset: 80,
        fraction: 0.2,
        fontSize: 18,
        width: 390,
        updatedAt: 1700000001000,
      ),
      underlineRanges: const [
        ReaderUnderlineRange(
          chapterId: 101,
          startParagraph: 1,
          startOffset: 0,
          endParagraph: 1,
          endOffset: 7,
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'reader_bookmarks_$bookA': jsonEncode([seededMark.toJson()]),
      'reader_bookmarks_$bookB': jsonEncode([seededMark.toJson()]),
    });

    final state = await LibraryState.load();
    addTearDown(state.dispose);

    // Neither book is decoded synchronously during cold start.
    expect(state.debugIsBookmarksDecoded(bookA), isFalse);
    expect(state.debugIsBookmarksDecoded(bookB), isFalse);

    // Querying underlines for bookA hydrates only bookA, leaving bookB deferred.
    final underlinesA = state.underlinesFor(bookA, chapterId: 101);
    expect(underlinesA.length, 1);
    expect(state.debugIsBookmarksDecoded(bookA), isTrue);
    expect(state.debugIsBookmarksDecoded(bookB), isFalse);

    // Mutating bookmarks on un-decoded bookB hydrates first without dropping existing marks.
    const novelB = Novel(
      id: bookB,
      title: '懒加载测试书',
      author: '作者',
      genre: '本地',
      summary: '',
      colors: [],
    );
    await state.addPageBookmark(novel: novelB, page: 2, pageCount: 10);
    expect(state.debugIsBookmarksDecoded(bookB), isTrue);
    expect(state.bookmarksFor(bookB).length, 2);
  });
}

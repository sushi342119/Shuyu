import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_duplicates_page.dart';
import 'package:shuyu/local_library.dart';

import 'support/pump_storage.dart';

LocalBook _book(int id, String hash) => LocalBook(
  id: localNovelIdBase + id,
  title: '相同书名',
  author: '作者',
  fileUri: '/books/$id.txt',
  fileName: '$id.txt',
  kind: LocalBookKind.txt,
  size: 100,
  modified: 1,
  chapters: const [],
  pageCount: 0,
  sourceFingerprint: hash,
);

class _Store extends Fake implements LocalLibraryStore {
  final items = [_book(1, 'same'), _book(2, 'same'), _book(3, 'same')];
  final deleted = <int>[];
  int? failingId;

  @override
  List<LocalBook> get books => List.unmodifiable(items);

  @override
  LocalBook? bookFor(int id) {
    for (final book in items) {
      if (book.id == id) return book;
    }
    return null;
  }

  @override
  Future<void> deleteDuplicateBookFile(
    LocalBook expected, {
    required LocalBook keeper,
  }) async {
    if (expected.id == failingId) throw StateError('存储暂不可用');
    expect(items.any((b) => b.id == keeper.id), isTrue);
    deleted.add(expected.id);
    items.removeWhere((b) => b.id == expected.id);
  }

  @override
  Future<void> confirmAssociatedCleanupIds(Iterable<int> ids) async {}
}

void main() {
  late _Store store;
  late LibraryState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
    await TagStore.load();
    state = await LibraryState.load();
    store = _Store();
  });

  tearDown(() => state.dispose());

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: LocalDuplicatesPage(local: store, state: state),
      ),
    );
    await pumpUntil(
      tester,
      () =>
          find.byKey(const ValueKey('duplicate-filters')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'nothing selected initially; selecting copies always retains a book',
    (tester) async {
      await mount(tester);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('每组保留一本，选择其余副本'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      final keeper = tester.widget<CheckboxListTile>(
        find.byKey(ValueKey('duplicate-book-${localNovelIdBase + 1}')),
      );
      expect(keeper.value, isFalse);
      expect(keeper.onChanged, isNull);
      expect(store.deleted, isEmpty);
      expect(find.textContaining('删除选中 2 本'), findsOneWidget);
    },
  );

  testWidgets('canceling confirmation deletes no files', (tester) async {
    await mount(tester);
    await tester.tap(find.text('每组保留一本，选择其余副本'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.deleted, isEmpty);
    expect(store.items, hasLength(3));
  });

  testWidgets(
    'two confirmations delete selected files; batch continues after failure',
    (tester) async {
      store.failingId = localNovelIdBase + 2;
      await pumpStorage(
        tester,
        () => state.setShelfMembership(localNovelIdBase + 3, true),
      );
      await pumpStorage(
        tester,
        () => state.setChapter(localNovelIdBase + 3, 2),
      );
      await mount(tester);
      await tester.tap(find.text('每组保留一本，选择其余副本'));
      await tester.pumpAndSettle();
      // Reading history makes book 3 the keeper; choose it for deletion manually
      // only after deselecting another book so the UI can retain book 1.
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('duplicate-book-${localNovelIdBase + 1}')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('duplicate-book-${localNovelIdBase + 3}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('duplicate-book-${localNovelIdBase + 3}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(store.deleted, isEmpty);
      await tester.tap(find.text('永久删除 2 本'));
      await pumpUntil(tester, () => find.text('清理结果').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(store.deleted, [localNovelIdBase + 3]);
      expect(store.items.map((b) => b.id), [
        localNovelIdBase + 1,
        localNovelIdBase + 2,
      ]);
      expect(find.textContaining('已删除 1 本，未完成 1 本'), findsOneWidget);
      expect(state.contains(localNovelIdBase + 3), isFalse);
      expect(state.hasRead(localNovelIdBase + 3), isFalse);
    },
  );

  testWidgets('suspected titles require manual selection', (tester) async {
    store.items.add(_book(4, 'other-edition'));
    await mount(tester);
    await tester.tap(find.text('每组保留一本，选择其余副本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('疑似同名（1 组）'));
    await tester.pumpAndSettle();
    expect(find.text('每组保留一本，选择其余副本'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(store.deleted, isEmpty);
  });
  testWidgets(
    'opens suspected matches when exact hashes differ and keeps filters below header',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(349, 768);
      addTearDown(tester.view.reset);
      store.items
        ..clear()
        ..addAll([
          _book(1, 'a').copyWith(title: '长风集'),
          _book(2, 'b').copyWith(title: '长风集 张三'),
          _book(3, 'c').copyWith(title: '长风集1'),
        ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 24, bottom: 16),
              textScaler: TextScaler.linear(1.2),
            ),
            child: child!,
          ),
          home: LocalDuplicatesPage(local: store, state: state),
        ),
      );
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('duplicate-filters'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pumpAndSettle();
      final filters = tester.getRect(
        find.byKey(const ValueKey('duplicate-filters')),
      );
      expect(
        filters.top,
        greaterThanOrEqualTo(24 + FrostedHeader.toolbarHeight),
      );
      final suspected = find.widgetWithText(ChoiceChip, '疑似同名（1 组）');
      expect(tester.widget<ChoiceChip>(suspected).selected, isTrue);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(find.text('每组保留一本，选择其余副本'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('duplicate-results-scroll')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(find.text('长风集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'controls scroll without overflow with large text in short landscape window',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(780, 260);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: LocalDuplicatesPage(local: store, state: state),
        ),
      );
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('duplicate-filters'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byKey(const ValueKey('duplicate-results-scroll')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

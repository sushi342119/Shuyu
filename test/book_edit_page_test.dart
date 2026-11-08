import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/pages.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalLibraryStore local;
  late LibraryState state;
  late CompositeNovelRepository repository;
  late PathProviderPlatform oldPaths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('book-edit-page-');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({'motionLevel': 'off'});
    await TagStore.load();
    state = await LibraryState.load();
    final dir = await Directory('${root.path}/novels').create();
    await File('${dir.path}/《秦家仙子》作者：佚名 ✦古风.txt').writeAsString(
      '第一章 初见\n正文内容一二三四五六七八九十。',
    );
    local = await LocalLibraryStore.load();
    await local.scanAppFolder();
    await TagStore.shared.createTag('母子');
    final book = local.books.single;
    await state.setShelfMembership(book.id, true, novel: local.toNovel(book));
    repository = CompositeNovelRepository(
      remote: const DemoNovelRepository(),
      local: local,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() async {
    local.dispose();
    state.dispose();
    PathProviderPlatform.instance = oldPaths;
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> pumpDetailPage(WidgetTester tester) async {
    final book = local.books.single;
    final chapters = await local.chapters(book.id);
    final novel = local.toNovel(book).withChapters(chapters);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: DetailPage(
          novel: novel,
          state: state,
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'tapping title and author on DetailPage opens focused editors and updates live',
    (tester) async {
      await pumpDetailPage(tester);
      final bookId = local.books.single.id;

      // Tap book title directly on DetailPage
      await tester.tap(find.byKey(const ValueKey('detail-edit-title')));
      await tester.pumpAndSettle();
      expect(find.text('修改书名'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('book-edit-filename-unchanged')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('book-edit-title-field')),
        '全新书名',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('book-edit-rename-preview')),
        findsOneWidget,
      );
      expect(find.textContaining('改名后：全新书名 ✦古风.txt'), findsOneWidget);

      // Reset to original parsed title
      await tester.tap(find.byKey(const ValueKey('book-edit-reset-title')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('book-edit-filename-unchanged')),
        findsOneWidget,
      );

      // Enter new title and save
      await tester.enterText(
        find.byKey(const ValueKey('book-edit-title-field')),
        '秦家仙子新编',
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('book-edit-save-button')));
        for (
          var i = 0;
          i < 120 &&
              (local.bookFor(bookId)?.displayTitle != '秦家仙子新编' ||
                  state.cachedNovel(bookId)?.title != '秦家仙子新编');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();

      expect(local.bookFor(bookId)!.displayTitle, '秦家仙子新编');
      expect(local.bookFor(bookId)!.fileName, '秦家仙子新编 ✦古风.txt');
      expect(find.text('秦家仙子新编'), findsWidgets);

      // Tap author name directly on DetailPage
      await tester.tap(find.byKey(const ValueKey('detail-edit-author')));
      await tester.pumpAndSettle();
      expect(find.text('修改作者'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('book-edit-author-field')),
        '知名作者',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('book-edit-reset-author')),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('book-edit-save-button')));
        for (
          var i = 0;
          i < 120 &&
              (local.bookFor(bookId)?.displayAuthor != '知名作者' ||
                  state.cachedNovel(bookId)?.author != '知名作者');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();

      expect(local.bookFor(bookId)!.displayAuthor, '知名作者');
      expect(state.cachedNovel(bookId)?.title, '秦家仙子新编');
      expect(state.cachedNovel(bookId)?.author, '知名作者');
      expect(find.text('知名作者'), findsWidgets);
    },
  );

  testWidgets(
    'DetailPage tag editor uses capsule chips, creates tag inline, and removes 编辑书籍信息 menu item',
    (tester) async {
      await pumpDetailPage(tester);
      final bookId = local.books.single.id;

      // Open tag editor from DetailPage
      final editTagsButton = find.byKey(
        const ValueKey('detail-edit-tags-button'),
      );
      await tester.ensureVisible(editTagsButton);
      await tester.pumpAndSettle();
      await tester.tap(editTagsButton);
      await tester.pumpAndSettle();

      expect(find.text('书籍标签'), findsOneWidget);

      // Toggle existing tag '母子'
      await tester.tap(find.byKey(const ValueKey('book-edit-tag-母子')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('tag-filename-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('✦古风 ✦母子.txt'), findsOneWidget);

      // Create new tag '精校' and auto-select it
      await tester.enterText(
        find.byKey(const ValueKey('book-edit-new-tag-field')),
        '精校',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('book-edit-add-tag-button')));
        for (
          var i = 0;
          i < 60 && !TagStore.shared.tags.any((t) => t.name == '精校');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-edit-tag-精校')), findsOneWidget);

      // Save tags
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('book-edit-save-button')));
        for (
          var i = 0;
          i < 120 &&
              !TagStore.shared.tagNamesForBook(bookId).contains('精校');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();

      expect(
        TagStore.shared.tagNamesForBook(bookId),
        containsAll(['古风', '母子', '精校']),
      );
      expect(
        local.bookFor(bookId)!.fileName,
        '《秦家仙子》作者：佚名 ✦古风 ✦母子 ✦精校.txt',
      );
      expect(find.byKey(const ValueKey('detail-tag-精校')), findsOneWidget);
    },
  );
}

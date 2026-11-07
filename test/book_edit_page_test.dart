import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/book_edit_page.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_library.dart';

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
  late PathProviderPlatform oldPaths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('book-edit-page-');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
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
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() async {
    local.dispose();
    state.dispose();
    PathProviderPlatform.instance = oldPaths;
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> pumpEditPage(WidgetTester tester) async {
    final book = local.books.single;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openLocalBookEditPage(
                context,
                state: state,
                local: local,
                bookId: book.id,
              ),
              child: const Text('打开编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders cover preview, metadata, and updates live as user types', (
    tester,
  ) async {
    await pumpEditPage(tester);
    expect(find.text('编辑书籍信息'), findsOneWidget);
    expect(find.byKey(const ValueKey('book-edit-preview-card')), findsOneWidget);
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('1 章'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('book-edit-title-field')),
      '全新书名',
    );
    await tester.enterText(
      find.byKey(const ValueKey('book-edit-author-field')),
      '新作者',
    );
    await tester.pump();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('book-edit-preview-title')))
          .data,
      '全新书名',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('book-edit-preview-author')))
          .data,
      '新作者',
    );
    expect(find.byKey(const ValueKey('book-edit-rename-preview')), findsOneWidget);
    expect(find.textContaining('改名后：全新书名 ✦古风.txt'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('book-edit-reset-title')));
    await tester.pump();
    expect(find.byKey(const ValueKey('book-edit-filename-unchanged')), findsOneWidget);
  });

  testWidgets('creates tag, toggles tags, and saves title/author/tags atomically', (
    tester,
  ) async {
    await pumpEditPage(tester);
    final bookId = local.books.single.id;

    // Select existing tag '母子'
    final existingTagFinder = find.byKey(const ValueKey('book-edit-tag-母子'));
    await tester.ensureVisible(existingTagFinder);
    await tester.pumpAndSettle();
    await tester.tap(existingTagFinder);
    await tester.pump();
    expect(
      find.textContaining('✦古风 ✦母子.txt'),
      findsOneWidget,
    );

    // Create a new tag inline and auto-select it
    final newTagField = find.byKey(const ValueKey('book-edit-new-tag-field'));
    await tester.ensureVisible(newTagField);
    await tester.pumpAndSettle();
    await tester.enterText(newTagField, '精校');
    final addTagButton = find.byKey(const ValueKey('book-edit-add-tag-button'));
    await tester.ensureVisible(addTagButton);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(addTagButton);
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

    // Change title & author
    final titleField = find.byKey(const ValueKey('book-edit-title-field'));
    await tester.ensureVisible(titleField);
    await tester.pumpAndSettle();
    await tester.enterText(titleField, '秦家仙子新编');
    final authorField = find.byKey(const ValueKey('book-edit-author-field'));
    await tester.ensureVisible(authorField);
    await tester.pumpAndSettle();
    await tester.enterText(authorField, '知名作者');
    await tester.pump();

    // Save via header button
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('book-edit-header-save')));
      for (
        var i = 0;
        i < 120 && local.bookFor(bookId)?.displayTitle != '秦家仙子新编';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();

    final updated = local.bookFor(bookId)!;
    expect(updated.displayTitle, '秦家仙子新编');
    expect(updated.displayAuthor, '知名作者');
    expect(updated.fileName, '秦家仙子新编 ✦古风 ✦母子 ✦精校.txt');
    expect(
      TagStore.shared.tagNamesForBook(bookId),
      containsAll(['古风', '母子', '精校']),
    );
    expect(state.cachedNovel(bookId)?.title, '秦家仙子新编');
    expect(state.cachedNovel(bookId)?.author, '知名作者');
    expect(find.text('已保存'), findsOneWidget);
  });
}

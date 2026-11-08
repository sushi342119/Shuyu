import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/reader_annotation_editor.dart';
import 'package:shuyu/reader_catalogue.dart';
import 'package:shuyu/reader_selection.dart';
import 'package:shuyu/reader_underline.dart';

class _TestNovelRepository extends DemoNovelRepository {
  _TestNovelRepository(this.novel, this.body);
  final Novel novel;
  final String body;

  @override
  Future<List<Novel>> list() async => [novel];

  @override
  Future<Novel?> find(int id) async => id == novel.id ? novel : null;

  @override
  Future<Novel> detail(Novel n) async => novel;

  @override
  Future<List<NovelChapter>> chapters(int id) async => novel.chapters;

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async => body;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ReaderUnderlineRange and LibraryState support chapterId >= 0 (including local chapter 0)', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);

    const localNovel = Novel(
      id: -101,
      title: '本地测试书籍',
      author: '作者',
      genre: '本地导入',
      summary: '',
      colors: [Color(0xFF202020), Color(0xFF404040)],
      chapters: [
        NovelChapter('第一章', '', id: 0),
      ],
    );
    const range = ReaderUnderlineRange(
      chapterId: 0,
      startParagraph: 0,
      startOffset: 0,
      endParagraph: 0,
      endOffset: 6,
    );
    expect(range.isValid, isTrue);

    const position = ReadingPosition(
      chapter: 0,
      chapterId: 0,
      offset: 0,
      fraction: 0,
      fontSize: 19,
      width: 360,
      updatedAt: 1,
      paragraphIndex: 0,
    );

    final added = await state.toggleUnderline(
      novel: localNovel,
      position: position,
      ranges: const [range],
      quote: '春眠不觉晓，',
    );
    expect(added, isTrue);
    expect(state.underlinesFor(localNovel.id, chapterId: 0), [range]);
    expect(state.annotationsFor(localNovel.id, chapterId: 0), hasLength(1));

    final removed = await state.toggleUnderline(
      novel: localNovel,
      position: position,
      ranges: const [range],
      quote: '春眠不觉晓，',
    );
    expect(removed, isFalse);
    expect(state.underlinesFor(localNovel.id, chapterId: 0), isEmpty);
  });

  testWidgets('Long press on article paragraph selects sentence, copies, underlines, and renders in ReaderMarksSheet', (tester) async {
    SharedPreferences.setMockInitialValues({'reduce_motion': true});
    final state = await LibraryState.load();
    addTearDown(state.dispose);

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<dynamic, dynamic>;
          clipboardText = args['text'] as String?;
        } else if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': clipboardText};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    const novel = Novel(
      id: 88,
      title: '划线测试作品',
      author: '测试作者',
      genre: '文学',
      summary: '测试划线与复制',
      colors: [Color(0xFF222222), Color(0xFF444444)],
      chapters: [
        NovelChapter('第一章 晨光', '', id: 8801),
      ],
    );
    const body = '春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。\n\n第二段正文内容，用来验证段落选择。';
    final repo = _TestNovelRepository(novel, body);

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          novel: novel,
          initialChapter: 0,
          state: state,
          repository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final paragraph0 = find.byKey(const ValueKey('paragraph-0'));
    expect(paragraph0, findsOneWidget);

    await tester.longPressAt(tester.getTopLeft(paragraph0) + const Offset(24, 12));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-selection-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-selection-underline')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-selection-copy')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-selection-underline')));
    await tester.pumpAndSettle();

    expect(state.underlinesFor(novel.id, chapterId: 8801), isNotEmpty);

    await tester.longPressAt(tester.getTopLeft(paragraph0) + const Offset(24, 12));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-selection-copy')));
    await tester.pumpAndSettle();
    expect(clipboardText, isNotNull);
    expect(clipboardText, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('reader-catalogue-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderMarksSheet), findsOneWidget);

    await tester.tap(find.text('划线'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-underline-list')), findsOneWidget);

    final mark = state.bookmarksFor(novel.id).single;
    clipboardText = null;
    await tester.tap(find.byKey(ValueKey('reader-mark-copy-${mark.id}')));
    await tester.pumpAndSettle();
    expect(clipboardText, mark.quote.trim());

    await tester.tap(find.byKey(ValueKey('reader-mark-edit-${mark.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderAnnotationEditor), findsOneWidget);
    expect(find.byKey(const ValueKey('annotation-copy-quote')), findsOneWidget);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/chapter_splitter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_annotation_remap.dart';
import 'package:shuyu/local_epub.dart';
import 'package:shuyu/local_epub_reader.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/reader_content.dart';
import 'package:shuyu/reader_pagination.dart';
import 'package:shuyu/reader_preferences.dart';
import 'package:shuyu/reader_rich_content.dart';
import 'package:shuyu/reader_text.dart';
import 'package:shuyu/reader_underline.dart';

class _IndentNovelRepository extends DemoNovelRepository {
  _IndentNovelRepository(this.novel, this.body);
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
  Future<String> chapterContent(int novelId, NovelChapter chapter) async =>
      body;
}

class _IndentEpubStore extends Fake implements LocalLibraryStore {
  _IndentEpubStore()
    : book = const LocalBook(
        id: localNovelIdBase + 77,
        title: 'EPUB 缩进样本',
        author: '测试作者',
        fileUri: '',
        fileName: 'indent.epub',
        kind: LocalBookKind.epub,
        size: 0,
        modified: 0,
        chapters: [LocalChapterIndex('第一章', 0, 0)],
        pageCount: 0,
      );

  final LocalBook book;

  @override
  LocalBook? bookFor(int id) => id == book.id ? book : null;

  @override
  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})> epubChapter(
    int novelId,
    int chapterIndex,
  ) async => (
    blocks: const [
      EpubBlock.text('第一章 晨光初照', heading: true),
      EpubBlock.text('第一段正文内容，用来检验默认首行空两格缩进。'),
      EpubBlock.text('　　第二段自带全角空格，不应叠加成四字缩进。'),
    ],
    images: const <String, Uint8List>{},
  );
}

double? _leadingIndentWidth(Text widget) {
  final span = widget.textSpan;
  if (span is! TextSpan) return null;
  final children = span.children;
  if (children == null || children.isEmpty) return null;
  final first = children.first;
  if (first is! WidgetSpan) return null;
  var child = first.child;
  if (child is ExcludeSemantics && child.child != null) {
    child = child.child!;
  }
  return child is SizedBox ? child.width : null;
}

List<int> _buildMinimalEpubBytes(Map<String, String> chapters) {
  final archive = Archive();
  void addText(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  addText(
    'META-INF/container.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
        '</container>',
  );
  final manifestItems = StringBuffer();
  final spineRefs = StringBuffer();
  var idx = 0;
  for (final entry in chapters.entries) {
    idx++;
    manifestItems.write(
      '<item id="ch$idx" href="${entry.key}" media-type="application/xhtml+xml"/>',
    );
    spineRefs.write('<itemref idref="ch$idx"/>');
    addText('OEBPS/${entry.key}', entry.value);
  }
  addText(
    'OEBPS/content.opf',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>测试</dc:title></metadata>'
        '<manifest>$manifestItems</manifest>'
        '<spine>$spineRefs</spine>'
        '</package>',
  );
  return ZipEncoder().encode(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Issue #19 paragraph reflow & leading indent normalization', () {
    test(
      'strips full-width, tab, and ASCII leading indent completely without leaving 1-char indent',
      () {
        const singleNewlineTxt =
            '　　第一段首行带两个全角空格。\n'
            '　　第二段同样带两个全角空格，修复前会残留一个全角空格！\n'
            '\t\t第三段带两个制表符。\n'
            '    第四段带四个半角空格。\n'
            '　第五段原本只有一个全角空格。';
        final paragraphs = reflowReaderParagraphs(singleNewlineTxt);
        expect(paragraphs, [
          '第一段首行带两个全角空格。',
          '第二段同样带两个全角空格，修复前会残留一个全角空格！',
          '第三段带两个制表符。',
          '第四段带四个半角空格。',
          '第五段原本只有一个全角空格。',
        ]);
      },
    );

    test(
      'strips leading spaces on double-newline TXT and preserves exact UTF-16 raw offsets',
      () async {
        const raw = '　　春眠不觉晓，处处闻啼鸟。\n\n　　夜来风雨声，花落知多少。';
        final mapped = reflowReaderParagraphsWithOffsets(raw);
        expect(
          mapped.map((p) => p.text).toList(),
          ['春眠不觉晓，处处闻啼鸟。', '夜来风雨声，花落知多少。'],
        );
        expect(
          raw.substring(mapped[0].rawStart(0), mapped[0].rawEnd(mapped[0].text.length)),
          mapped[0].text,
        );
        expect(
          raw.substring(mapped[1].rawStart(0), mapped[1].rawEnd(mapped[1].text.length)),
          mapped[1].text,
        );
        for (final p in mapped) {
          for (var i = 0; i < p.text.length; i++) {
            expect(raw[p.charStarts[i]], p.text[i]);
            expect(p.charEnds[i], p.charStarts[i] + 1);
          }
        }

        // Verify local annotation remapping without quote still aligns cleanly
        // when leading full-width spaces are stripped from \n\n paragraphs.
        final tempDir = await Directory.systemTemp.createTemp('indent-remap-');
        addTearDown(() => tempDir.delete(recursive: true));
        const chapterTxt = '第一章 晨光\n　　春眠不觉晓，处处闻啼鸟。\n\n　　夜来风雨声，花落知多少。';
        final file = await File('${tempDir.path}/book.txt').writeAsString(chapterTxt);
        final anchor = await FileTextAnchor.open(file.path);
        final chapters = splitLocalChapters(chapterTxt);
        final remapped = await remapLocalUnderlineRanges(
          ranges: const [
            ReaderUnderlineRange(
              chapterId: 0,
              startParagraph: 1,
              startOffset: 0,
              endParagraph: 1,
              endOffset: 5,
              contentRevision: 'v5',
            ),
          ],
          oldText: anchor,
          newText: anchor,
          oldChapters: [
            for (final c in chapters) (offset: c.offset, length: c.length),
          ],
          newChapters: chapters,
          oldRevision: 'v5',
          newRevision: 'v6',
        );
        expect(
          remapped.single.toJson(),
          const ReaderUnderlineRange(
            chapterId: 0,
            startParagraph: 1,
            startOffset: 0,
            endParagraph: 1,
            endOffset: 5,
            contentRevision: 'v6',
          ).toJson(),
        );
      },
    );

    test(
      'never merges an indented next paragraph into a non-punctuated previous line',
      () {
        const raw = '未带句末标点的上一段文字\n　　下一段明确带缩进，绝不能合并到上一段。';
        expect(reflowReaderParagraphs(raw), [
          '未带句末标点的上一段文字',
          '下一段明确带缩进，绝不能合并到上一段。',
        ]);
      },
    );
  });

  group('ReaderPreferences indent default & legacy migration', () {
    test(
      'defaults to indent=true, migrates legacy unconfigured false to true, and persists explicit false',
      () {
        const defaults = ReaderPreferences();
        expect(defaults.indent, isTrue);

        // Legacy <= v1.9.16 JSON saved before any UI toggle existed.
        final migrated = ReaderPreferences.fromJson(const {
          'mode': 'scroll',
          'indent': false,
        });
        expect(migrated.indent, isTrue);

        // Explicit user opt-out persists indentConfigured=true and reloads as false.
        final disabled = defaults.copyWith(indent: false);
        expect(disabled.indent, isFalse);
        final encodedDisabled = disabled.toJson();
        expect(encodedDisabled['indent'], isFalse);
        expect(encodedDisabled['indentConfigured'], isTrue);
        expect(ReaderPreferences.fromJson(encodedDisabled).indent, isFalse);

        // Re-enabling round-trips as true.
        final reenabled = disabled.copyWith(indent: true);
        expect(ReaderPreferences.fromJson(reenabled.toJson()).indent, isTrue);
      },
    );

    test(
      'shouldIndentReaderParagraph skips headings, centered text, images, and pre-indented lines',
      () {
        expect(shouldIndentReaderParagraph('普通正文段落。', enabled: true), isTrue);
        expect(shouldIndentReaderParagraph('普通正文段落。', enabled: false), isFalse);
        expect(
          shouldIndentReaderParagraph('第一章 标题', enabled: true, heading: true),
          isFalse,
        );
        expect(
          shouldIndentReaderParagraph(
            '居中诗句',
            enabled: true,
            allowsIndent: false,
          ),
          isFalse,
        );
        expect(shouldIndentReaderParagraph('[插图]', enabled: true), isFalse);
        expect(shouldIndentReaderParagraph('   ', enabled: true), isFalse);
        expect(
          shouldIndentReaderParagraph('　　自带全角缩进', enabled: true),
          isFalse,
        );
        expect(
          shouldIndentReaderParagraph('  自带两个半角空格', enabled: true),
          isFalse,
        );
      },
    );
  });

  group('EPUB heading detection & pagination indentation', () {
    test('EpubPackage marks h1-h6 as heading across both XML and fallback HTML', () async {
      final tempDir = await Directory.systemTemp.createTemp('epub-heading-');
      addTearDown(() => tempDir.delete(recursive: true));
      final epubFile = File('${tempDir.path}/sample.epub');
      await epubFile.writeAsBytes(
        _buildMinimalEpubBytes({
          'ch1.xhtml':
              '<?xml version="1.0" encoding="UTF-8"?>'
              '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
              '<h1>第一章 破晓</h1><p>清晨的第一缕阳光照进窗台。</p>'
              '</body></html>',
          // Unclosed <br> triggers regex HTML fallback parser.
          'ch2.xhtml':
              '<html><body><h2>第二章 夜幕</h2><br><p>晚风吹过树梢。</p></body></html>',
        }),
      );
      final pkg = await EpubPackage.open(epubFile.path, lenient: true);
      addTearDown(pkg.close);

      final ch1 = await pkg.chapterBlocks(0);
      expect(ch1, hasLength(2));
      expect(ch1[0].text, '第一章 破晓');
      expect(ch1[0].heading, isTrue);
      expect(ch1[1].text, '清晨的第一缕阳光照进窗台。');
      expect(ch1[1].heading, isFalse);

      final ch2 = await pkg.chapterBlocks(1);
      expect(ch2, hasLength(2));
      expect(ch2[0].text, '第二章 夜幕');
      expect(ch2[0].heading, isTrue);
      expect(ch2[1].text, '晚风吹过树梢。');
      expect(ch2[1].heading, isFalse);
    });

    test(
      'paginateReader indents normal paragraphs by default and skips centered paragraphs',
      () async {
        const content = ReaderContent(
          ['普通段落正文内容。', '居中章节小标题'],
          formats: {
            0: ReaderRichParagraph(),
            1: ReaderRichParagraph(alignment: 'center'),
          },
        );
        final plan = await paginateReader(
          content: content,
          size: const Size(360, 640),
          style: const TextStyle(fontSize: 20, height: 1.7),
          preferences: const ReaderPreferences(mode: ReaderMode.paged),
          scaler: TextScaler.noScaling,
          current: () => true,
        );
        expect(plan, isNotNull);
        final fragments = plan!.pages.first.fragments;
        expect(fragments[0].indent, isTrue);
        expect(fragments[1].indent, isFalse);
      },
    );
  });

  testWidgets(
    'Scroll ReaderPage renders 2-em first-line indent by default, toggles via ReaderTools, and keeps selection/copy clean',
    (tester) async {
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
        id: 1901,
        title: '首行缩进测试书',
        author: '测试作者',
        genre: '文学',
        summary: '',
        colors: [Color(0xFF222222), Color(0xFF444444)],
        chapters: [NovelChapter('第一章', '', id: 190101)],
      );
      // Simulate raw TXT with 2 full-width spaces separated by single newline.
      const body = '　　春眠不觉晓，处处闻啼鸟。\n　　夜来风雨声，花落知多少。';
      final repo = _IndentNovelRepository(novel, body);

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderPage(
            novel: novel,
            initialChapter: 0,
            state: state,
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Both paragraph 0 and paragraph 1 have stripped text + exact 2*fontSize WidgetSpan!
      final p0 = tester.widget<Text>(find.byKey(const ValueKey('paragraph-0')));
      final p1 = tester.widget<Text>(find.byKey(const ValueKey('paragraph-1')));
      expect(
        p0.textSpan!.toPlainText(includePlaceholders: false),
        '春眠不觉晓，处处闻啼鸟。',
      );
      expect(
        p1.textSpan!.toPlainText(includePlaceholders: false),
        '夜来风雨声，花落知多少。',
      );
      expect(_leadingIndentWidth(p0), state.fontSize * 2);
      expect(_leadingIndentWidth(p1), state.fontSize * 2);

      // Long press directly on the leading area selects the first sentence cleanly
      // without copying leading spaces or U+FFFC placeholder characters.
      final p0TopLeft = tester.getTopLeft(
        find.byKey(const ValueKey('paragraph-0')),
      );
      await tester.longPressAt(p0TopLeft + const Offset(10, 12));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-selection-copy')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('reader-selection-copy')));
      await tester.pumpAndSettle();
      expect(clipboardText, '春眠不觉晓，处处闻啼鸟。');
      expect(clipboardText!.contains(readerIndentPlaceholder), isFalse);
      expect(clipboardText!.startsWith('　'), isFalse);

      // Open ReaderTools ("阅读设置") and toggle 首行缩进 off, then reset layout.
      ScaffoldMessenger.maybeOf(
        tester.element(find.byType(Scaffold).first),
      )?.clearSnackBars();
      await tester.pumpAndSettle();
      final settingsButton = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is GlassIconButton && w.label == '阅读设置',
        ),
        matching: find.byType(InkWell),
      );
      await tester.tap(settingsButton);
      await tester.pumpAndSettle();

      final indentSwitch = find.byKey(
        const ValueKey('reader-first-line-indent'),
      );
      await tester.ensureVisible(indentSwitch);
      expect(tester.widget<CupertinoSwitch>(indentSwitch).value, isTrue);

      await tester.tap(indentSwitch);
      await tester.pumpAndSettle();
      expect(state.readerPreferences.indent, isFalse);
      final p0Unindented = tester.widget<Text>(
        find.byKey(const ValueKey('paragraph-0')),
      );
      expect(_leadingIndentWidth(p0Unindented), isNull);
      expect(
        p0Unindented.data ??
            p0Unindented.textSpan!.toPlainText(includePlaceholders: false),
        '春眠不觉晓，处处闻啼鸟。',
      );

      final resetButton = find.text('恢复默认排版');
      await tester.ensureVisible(resetButton);
      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      expect(state.readerPreferences.indent, isTrue);
      expect(
        _leadingIndentWidth(
          tester.widget<Text>(find.byKey(const ValueKey('paragraph-0'))),
        ),
        state.fontSize * 2,
      );
    },
  );

  testWidgets(
    'LocalEpubReaderPage indents prose blocks, skips headings/pre-indented lines, and toggles via epub-first-line-indent',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduce_motion': true});
      final store = _IndentEpubStore();
      final state = await LibraryState.load();
      addTearDown(state.dispose);

      const novel = Novel(
        id: localNovelIdBase + 77,
        title: 'EPUB 缩进样本',
        author: '测试作者',
        genre: '本地',
        summary: '',
        colors: [Colors.black, Colors.grey],
        chapters: [NovelChapter('第一章', '', id: 0)],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: LocalEpubReaderPage(
            novel: novel,
            initialChapter: 0,
            state: state,
            local: store,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();

      Text findEpubText(String plain) => tester.widget<Text>(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data ?? w.textSpan?.toPlainText(includePlaceholders: false)) ==
                  plain,
        ),
      );

      // Heading block has NO indent; normal prose has 2*fontSize indent;
      // pre-indented block ('　　...') has NO duplicate WidgetSpan indent!
      expect(_leadingIndentWidth(findEpubText('第一章 晨光初照')), isNull);
      expect(
        _leadingIndentWidth(findEpubText('第一段正文内容，用来检验默认首行空两格缩进。')),
        state.fontSize * 2,
      );
      expect(
        _leadingIndentWidth(findEpubText('　　第二段自带全角空格，不应叠加成四字缩进。')),
        isNull,
      );

      // Toggle off via EPUB tools sheet.
      final settingsButton = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is GlassIconButton && w.label == '阅读设置',
        ),
        matching: find.byType(InkWell),
      );
      await tester.tap(settingsButton);
      await tester.pumpAndSettle();

      final epubSwitch = find.byKey(const ValueKey('epub-first-line-indent'));
      await tester.ensureVisible(epubSwitch);
      expect(tester.widget<CupertinoSwitch>(epubSwitch).value, isTrue);
      await tester.tap(epubSwitch);
      await tester.pumpAndSettle();
      expect(state.readerPreferences.indent, isFalse);
      expect(
        _leadingIndentWidth(findEpubText('第一段正文内容，用来检验默认首行空两格缩进。')),
        isNull,
      );
    },
  );

  testWidgets('SettingsPage exposes settings-first-line-indent switch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reduce_motion': true});
    final state = await LibraryState.load();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Scaffold(
          body: SettingsPage(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('settings-first-line-indent'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<CupertinoSwitch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.readerPreferences.indent, isFalse);
  });
}

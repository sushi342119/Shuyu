import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/chapter_splitter.dart';
import 'package:shuyu/library_state.dart' show FileTextAnchor;
import 'package:shuyu/local_annotation_remap.dart';
import 'package:shuyu/reader_underline.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('annotation-remap-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'v5/v6 round trips preserve exact emoji selections and paragraph offsets',
    () async {
      const text = '第一章 开场\n甲正文。\n\n简介\n独立目标😀段落。\n\n随后还有第二段。\n第二章 结束\n末尾正文。';
      final file = await File('${root.path}/text.txt').writeAsString(text);
      final anchor = await FileTextAnchor.open(file.path);
      final legacy = splitLocalChapters(text, enableChapterExtensions: false);
      final extended = splitLocalChapters(text);
      const original = ReaderUnderlineRange(
        chapterId: 0,
        startParagraph: 1,
        startOffset: 5,
        endParagraph: 1,
        endOffset: 9,
        contentRevision: 'v5',
      );
      var ranges = [original];
      for (var cycle = 0; cycle < 3; cycle++) {
        ranges = await remapLocalUnderlineRanges(
          ranges: ranges,
          oldText: anchor,
          newText: anchor,
          oldChapters: [
            for (final chapter in legacy)
              (offset: chapter.offset, length: chapter.length),
          ],
          newChapters: extended,
          oldRevision: 'v5',
          newRevision: 'v6',
        );
        expect(
          ranges.single.toJson(),
          const ReaderUnderlineRange(
            chapterId: 1,
            startParagraph: 0,
            startOffset: 2,
            endParagraph: 0,
            endOffset: 6,
            contentRevision: 'v6',
          ).toJson(),
        );
        ranges = await remapLocalUnderlineRanges(
          ranges: ranges,
          oldText: anchor,
          newText: anchor,
          oldChapters: [
            for (final chapter in extended)
              (offset: chapter.offset, length: chapter.length),
          ],
          newChapters: legacy,
          oldRevision: 'v6',
          newRevision: 'v5',
        );
        expect(ranges, [original]);
        expect(ReaderUnderlineRange.fromJson(ranges.single.toJson()), original);
      }
    },
  );

  test(
    'a selection spanning a new heading is clipped into chapter body ranges',
    () async {
      const text = '第一章 开场\n甲正文。\n\n简介\n独立目标😀段落。\n第二章 结束\n末尾正文。';
      final file = await File('${root.path}/text.txt').writeAsString(text);
      final anchor = await FileTextAnchor.open(file.path);
      final legacy = splitLocalChapters(text, enableChapterExtensions: false);
      final ranges = await remapLocalUnderlineRanges(
        ranges: [
          const ReaderUnderlineRange(
            chapterId: 0,
            startParagraph: 0,
            startOffset: 0,
            endParagraph: 1,
            endOffset: 9,
            contentRevision: 'v5',
          ),
        ],
        oldText: anchor,
        newText: anchor,
        oldChapters: [
          for (final chapter in legacy)
            (offset: chapter.offset, length: chapter.length),
        ],
        newChapters: splitLocalChapters(text),
        oldRevision: 'v5',
        newRevision: 'v6',
      );
      expect(ranges, [
        const ReaderUnderlineRange(
          chapterId: 0,
          startParagraph: 0,
          startOffset: 0,
          endParagraph: 0,
          endOffset: 4,
          contentRevision: 'v6',
        ),
        const ReaderUnderlineRange(
          chapterId: 1,
          startParagraph: 0,
          startOffset: 0,
          endParagraph: 0,
          endOffset: 6,
          contentRevision: 'v6',
        ),
      ]);
      expect(ranges.every((range) => range.isValid), isTrue);
    },
  );

  test(
    'changed source text relocates the selection instead of reusing old offsets',
    () async {
      const oldText = '第一章 开场\n前段\n\n简介\n独立目标😀段落。\n';
      const newText = '新增的开场文字。\n第一章 开场\n前段\n\n简介\n独立目标😀段落。\n';
      final oldFile = await File('${root.path}/old.txt').writeAsString(oldText);
      final newFile = await File('${root.path}/new.txt').writeAsString(newText);
      final legacy = splitLocalChapters(
        oldText,
        enableChapterExtensions: false,
      );
      final ranges = await remapLocalUnderlineRanges(
        ranges: [
          const ReaderUnderlineRange(
            chapterId: 0,
            startParagraph: 1,
            startOffset: 5,
            endParagraph: 1,
            endOffset: 9,
            contentRevision: 'v5',
          ),
        ],
        oldText: await FileTextAnchor.open(oldFile.path),
        newText: await FileTextAnchor.open(newFile.path),
        oldChapters: [
          for (final chapter in legacy)
            (offset: chapter.offset, length: chapter.length),
        ],
        newChapters: splitLocalChapters(newText),
        oldRevision: 'v5',
        newRevision: 'v6',
      );
      expect(
        ranges.single,
        const ReaderUnderlineRange(
          chapterId: 2,
          startParagraph: 0,
          startOffset: 2,
          endParagraph: 0,
          endOffset: 6,
          contentRevision: 'v6',
        ),
      );
    },
  );

  test(
    'unknown revisions and invalid paragraph ranges fail instead of silently moving',
    () async {
      const text = '简介\n独立目标😀段落。';
      final file = await File('${root.path}/text.txt').writeAsString(text);
      final anchor = await FileTextAnchor.open(file.path);
      for (final invalid in [
        const ReaderUnderlineRange(
          chapterId: 0,
          startParagraph: 0,
          startOffset: 0,
          endParagraph: 0,
          endOffset: 2,
          contentRevision: 'unrelated',
        ),
        const ReaderUnderlineRange(
          chapterId: 0,
          startParagraph: 3,
          startOffset: 0,
          endParagraph: 3,
          endOffset: 2,
          contentRevision: 'v5',
        ),
        const ReaderUnderlineRange(
          chapterId: 0,
          startParagraph: 0,
          startOffset: 0,
          endParagraph: 0,
          endOffset: 999,
          contentRevision: 'v5',
        ),
      ]) {
        await expectLater(
          remapLocalUnderlineRanges(
            ranges: [invalid],
            oldText: anchor,
            newText: anchor,
            oldChapters: [(offset: 0, length: text.length)],
            newChapters: splitLocalChapters(text),
            oldRevision: 'v5',
            newRevision: 'v6',
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'chapter zero keeps upstream validity and mapped ranges are idempotent',
    () async {
      const range = ReaderUnderlineRange(
        chapterId: 0,
        startParagraph: 0,
        startOffset: 0,
        endParagraph: 0,
        endOffset: 2,
        contentRevision: 'v6',
      );
      expect(range.isValid, isTrue);
      expect(range.withRevision('').isValid, isTrue);
      final file = await File('${root.path}/text.txt').writeAsString('正文😀');
      final anchor = await FileTextAnchor.open(file.path);
      expect(
        await remapLocalUnderlineRanges(
          ranges: [range],
          oldText: anchor,
          newText: anchor,
          oldChapters: [(offset: 0, length: 4)],
          newChapters: [const LocalChapterIndex('正文', 0, 4)],
          oldRevision: 'v5',
          newRevision: 'v6',
        ),
        [range],
      );
    },
  );
}

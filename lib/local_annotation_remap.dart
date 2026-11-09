import 'chapter_splitter.dart';
import 'library_state.dart' show FileTextAnchor;
import 'reader_underline.dart';

Future<List<ReaderUnderlineRange>> remapLocalUnderlineRanges({
  required List<ReaderUnderlineRange> ranges,
  required FileTextAnchor oldText,
  required FileTextAnchor newText,
  required List<({int offset, int length})> oldChapters,
  required List<LocalChapterIndex> newChapters,
  required String oldRevision,
  required String newRevision,
}) async {
  final mapped = <ReaderUnderlineRange>[];
  for (final source in ranges) {
    if (source.contentRevision == newRevision && newRevision.isNotEmpty) {
      mapped.add(source);
      continue;
    }
    if (source.chapterId < 0 ||
        source.chapterId >= oldChapters.length ||
        (source.contentRevision.isNotEmpty &&
            oldRevision.isNotEmpty &&
            source.contentRevision != oldRevision)) {
      throw const FormatException('批注属于其他目录修订');
    }
    final oldChapter = oldChapters[source.chapterId];
    final oldBody = await oldText.trimmedRange(
      oldChapter.offset,
      oldChapter.offset + oldChapter.length,
    );
    final startParagraph = await oldText.paragraphAt(
      oldBody.start,
      oldBody.end,
      stopAt: source.startParagraph,
    );
    final endParagraph = await oldText.paragraphAt(
      oldBody.start,
      oldBody.end,
      stopAt: source.endParagraph,
    );
    final oldStart = oldBody.start + startParagraph.start + source.startOffset;
    final oldEnd = oldBody.start + endParagraph.start + source.endOffset;
    if (startParagraph.index != source.startParagraph ||
        endParagraph.index != source.endParagraph ||
        oldStart < oldBody.start ||
        oldEnd > oldBody.end ||
        oldEnd <= oldStart) {
      throw const FormatException('批注范围越界');
    }
    final newStart = await newText.relocateFrom(oldText, oldStart);
    final newEnd = await newText.relocateFrom(oldText, oldEnd);
    for (
      var chapterIndex = 0;
      chapterIndex < newChapters.length;
      chapterIndex++
    ) {
      final chapter = newChapters[chapterIndex];
      if (chapter.offset >= newEnd) break;
      if (chapter.offset + chapter.length <= newStart) continue;
      final body = await newText.trimmedRange(
        chapter.offset,
        chapter.offset + chapter.length,
      );
      final start = newStart.clamp(body.start, body.end);
      final end = newEnd.clamp(body.start, body.end);
      if (end <= start) continue;
      final first = await newText.locate([chapter], start);
      final last = await newText.locate([chapter], end);
      mapped.add(
        ReaderUnderlineRange(
          chapterId: chapterIndex,
          startParagraph: first.paragraph,
          startOffset: first.textOffset - first.paragraphStart,
          endParagraph: last.paragraph,
          endOffset: last.textOffset - last.paragraphStart,
          contentRevision: newRevision,
        ),
      );
    }
  }
  return mapped;
}

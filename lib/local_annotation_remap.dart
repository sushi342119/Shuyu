import 'chapter_splitter.dart';
import 'library_state.dart' show FileTextAnchor;
import 'reader_rich_content.dart';
import 'reader_underline.dart';

String _normalizeQuoteComparison(String input) =>
    input.replaceAll(RegExp(r'\s+'), '');

Future<List<ReaderUnderlineRange>> remapLocalUnderlineRanges({
  required List<ReaderUnderlineRange> ranges,
  required FileTextAnchor oldText,
  required FileTextAnchor newText,
  required List<({int offset, int length})> oldChapters,
  required List<LocalChapterIndex> newChapters,
  required String oldRevision,
  required String newRevision,
  String? quote,
}) async {
  final mapped = <ReaderUnderlineRange>[];
  final cleanQuote = quote == null ? '' : _normalizeQuoteComparison(quote);
  for (final source in ranges) {
    if (source.contentRevision == newRevision && newRevision.isNotEmpty) {
      mapped.add(source);
      continue;
    }
    if (source.chapterId < 0 ||
        source.chapterId >= oldChapters.length ||
        !source.isValid ||
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
    final rawStart =
        oldBody.start + startParagraph.start + source.startOffset;
    final rawEnd = oldBody.start + endParagraph.start + source.endOffset;
    final validRaw =
        startParagraph.index == source.startParagraph &&
        endParagraph.index == source.endParagraph &&
        rawStart >= oldBody.start &&
        rawEnd <= oldBody.end &&
        rawEnd > rawStart;

    var oldStart = rawStart;
    var oldEnd = rawEnd;
    var useReflow = false;

    final canSliceOld =
        oldBody.end - oldBody.start <= FileTextAnchor.maxSliceLength;
    if (canSliceOld && (!validRaw || cleanQuote.isNotEmpty)) {
      String? rawSliceQuote;
      if (validRaw && cleanQuote.isNotEmpty) {
        rawSliceQuote = _normalizeQuoteComparison(
          await oldText.slice(rawStart, rawEnd),
        );
      }
      final rawMatchesQuote =
          validRaw &&
          cleanQuote.isNotEmpty &&
          (rawSliceQuote == cleanQuote ||
              cleanQuote.contains(rawSliceQuote!) &&
                  rawSliceQuote.isNotEmpty);
      if (!validRaw || !rawMatchesQuote) {
        final oldSlice = await oldText.slice(oldBody.start, oldBody.end);
        final reflowed = reflowReaderParagraphsWithOffsets(oldSlice);
        if (source.startParagraph < reflowed.length &&
            source.endParagraph < reflowed.length &&
            source.startOffset <=
                reflowed[source.startParagraph].text.length &&
            source.endOffset <= reflowed[source.endParagraph].text.length) {
          final candidateStart =
              oldBody.start +
              reflowed[source.startParagraph].rawStart(source.startOffset);
          final candidateEnd =
              oldBody.start +
              reflowed[source.endParagraph].rawEnd(source.endOffset);
          if (candidateStart >= oldBody.start &&
              candidateEnd <= oldBody.end &&
              candidateEnd > candidateStart) {
            if (!validRaw) {
              oldStart = candidateStart;
              oldEnd = candidateEnd;
              useReflow = true;
            } else {
              final reflowQuote = _normalizeQuoteComparison(
                extractReflowedRangeText(
                  reflowed,
                  source.startParagraph,
                  source.startOffset,
                  source.endParagraph,
                  source.endOffset,
                ),
              );
              if (reflowQuote.isNotEmpty &&
                  (reflowQuote == cleanQuote ||
                      cleanQuote.contains(reflowQuote))) {
                oldStart = candidateStart;
                oldEnd = candidateEnd;
                useReflow = true;
              }
            }
          }
        }
      } else if (validRaw && cleanQuote.isNotEmpty) {
        final oldSlice = await oldText.slice(oldBody.start, oldBody.end);
        if (!oldSlice.contains('\n\n') && oldSlice.contains('\n')) {
          useReflow = true;
        }
      }
    }

    if (!validRaw && !useReflow) {
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
      final canSliceNew =
          body.end - body.start <= FileTextAnchor.maxSliceLength;
      String? newSlice;
      if (canSliceNew && (useReflow || cleanQuote.isNotEmpty)) {
        newSlice = await newText.slice(body.start, body.end);
      }
      final projectViaReflow =
          newSlice != null &&
          (useReflow ||
              (!newSlice.contains('\n\n') && newSlice.contains('\n')));
      if (projectViaReflow) {
        final reflowedNew = reflowReaderParagraphsWithOffsets(newSlice);
        final first = locateReflowedStart(reflowedNew, start - body.start);
        final last = locateReflowedEnd(reflowedNew, end - body.start);
        final candidate = ReaderUnderlineRange(
          chapterId: chapterIndex,
          startParagraph: first.paragraph,
          startOffset: first.offset,
          endParagraph: last.paragraph,
          endOffset: last.offset,
          contentRevision: newRevision,
        );
        if (candidate.isValid) {
          mapped.add(candidate);
          continue;
        }
      }
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
  if (ranges.isNotEmpty && mapped.isEmpty) {
    throw const FormatException('批注范围越界');
  }
  return mapped;
}

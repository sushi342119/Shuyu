import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/local_duplicates.dart';
import 'package:shuyu/local_library.dart';

LocalBook book(
  int id, {
  String title = '小说',
  String source = '',
  String text = '',
  int size = 100,
  int? words,
  LocalBookKind kind = LocalBookKind.txt,
}) => LocalBook(
  id: localNovelIdBase + id,
  title: title,
  author: '',
  fileUri: '/books/$id.txt',
  fileName: '$id.txt',
  kind: kind,
  size: size,
  modified: 1,
  chapters: const [],
  pageCount: 0,
  wordCount: words,
  sourceFingerprint: source,
  textFingerprint: text,
);

void main() {
  test(
    'renamed files and differently encoded identical text join by fingerprints',
    () {
      final report = findLocalDuplicates([
        book(1, title: '旧名', source: 'raw-a', text: 'decoded'),
        book(2, title: '新名', source: 'raw-a'),
        book(3, title: '另一份', source: 'raw-b', text: 'decoded'),
        book(4, title: '无关', source: 'raw-c', text: 'different'),
      ]);
      expect(report.content.single.books.map((b) => b.id), [
        localNovelIdBase + 1,
        localNovelIdBase + 2,
        localNovelIdBase + 3,
      ]);
      expect(report.title, isEmpty);
    },
  );

  test(
    'empty hashes and source/text hash namespaces never cause false matches',
    () {
      final report = findLocalDuplicates([
        book(1),
        book(2),
        book(3, source: 'abc'),
        book(4, text: 'abc'),
      ]);
      expect(report.content, isEmpty);
      expect(report.title.single.books, hasLength(4));
    },
  );

  test(
    'same name and size with different content is only a suspected match',
    () {
      final report = findLocalDuplicates([
        book(1, title: '《小说》', source: 'a'),
        book(2, title: '小说 (1)', source: 'b', kind: LocalBookKind.epub),
        book(3, title: '小说 副本', source: 'c'),
        book(4, title: '小说第二卷', source: 'd'),
      ]);
      expect(report.content, isEmpty);
      expect(report.title.single.books, hasLength(3));
    },
  );

  test(
    'exact groups are omitted from same-name list unless another edition exists',
    () {
      final first = book(1, source: 'same');
      final second = book(2, source: 'same');
      expect(findLocalDuplicates([first, second]).title, isEmpty);
      final report = findLocalDuplicates([
        first,
        second,
        book(3, source: 'edition'),
      ]);
      expect(report.content.single.books, hasLength(2));
      expect(report.title.single.books, hasLength(3));
    },
  );

  test('empty names and duplicate ids do not create phantom groups', () {
    expect(
      findLocalDuplicates([book(1, title: ''), book(2, title: '')]).title,
      isEmpty,
    );
    final same = book(1, source: 'same');
    expect(findLocalDuplicates([same, same]).content, isEmpty);
  });

  test(
    'keeper recommendation prioritizes reading history then recent read',
    () {
      final books = [book(1, words: 999999), book(2), book(3)];
      final keeper = recommendedDuplicateKeeper(
        books,
        hasRead: (id) => id != books.first.id,
        lastReadAt: (id) => id == books.last.id ? 100 : 50,
      );
      expect(keeper.id, books.last.id);
      expect(books.first.id, localNovelIdBase + 1);
    },
  );

  test('keeper recommendation breaks ties by completeness then stable id', () {
    final books = [
      book(2, words: 200),
      book(3, words: 100),
      book(1, words: 200),
    ];
    final keeper = recommendedDuplicateKeeper(
      books,
      hasRead: (_) => false,
      lastReadAt: (_) => 0,
    );
    expect(keeper.id, localNovelIdBase + 1);
  });
}

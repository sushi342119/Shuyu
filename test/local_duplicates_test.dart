import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/local_duplicates.dart';
import 'package:shuyu/local_library.dart';

LocalBook book(
  int id, {
  String title = '小说',
  String author = '',
  String? filename,
  String source = '',
  String text = '',
  int size = 100,
  int? words,
  LocalBookKind kind = LocalBookKind.txt,
}) => LocalBook(
  id: localNovelIdBase + id,
  title: title,
  author: author,
  fileUri: '/books/$id.txt',
  fileName: filename ?? '$id.txt',
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

  for (final variant in [
    '长风集张三',
    '长风集我吃西红柿',
    '长风集1',
    '长风集 1',
    '长风集_1',
    '长风集１',
    '长风集（1）',
    '长风集[1]',
    '长风集 张三',
    '长风集 - 张三',
    '长风集_张三',
    '长风集（张三）',
    '长风集 作者：张三',
    '长风集作者张三',
    '长风集 by Zhang',
    '《长风集》张三',
    '长风集1 张三',
    '长风集 张三 (1)',
    '长风集 副本 (1)',
  ]) {
    test('flags author/copy suffix as suspected: $variant', () {
      final report = findLocalDuplicates([
        book(1, title: '长风集', source: 'a'),
        book(2, title: variant, source: 'b'),
      ]);
      expect(report.content, isEmpty);
      expect(report.title.single.books, hasLength(2));
    });
  }

  test('known author matches an unseparated suffix on another record', () {
    final report = findLocalDuplicates([
      book(1, title: '长风集', author: '张三'),
      book(2, title: '长风集张三'),
    ]);
    expect(report.title.single.books, hasLength(2));
  });

  test(
    'uses original filename alongside embedded metadata and ignores filename tags',
    () {
      final report = findLocalDuplicates([
        book(1, title: '长风集'),
        book(2, title: '某网站下载版', filename: '长风集1 - 张三 ✦收藏.EPUB'),
      ]);
      expect(report.title.single.books, hasLength(2));
    },
  );

  test('does not merge numbered volumes without an unnumbered counterpart', () {
    final report = findLocalDuplicates([
      book(1, title: '长风集1'),
      book(2, title: '长风集2'),
      book(3, title: '长风集 - 第一卷'),
      book(4, title: '长风集 - 第二卷'),
      book(5, title: '长风集 番外'),
      book(6, title: '长风集 外传'),
    ]);
    expect(report.title, isEmpty);
  });

  test(
    'keeps explicit volume/edition markers separate from the bare title',
    () {
      final report = findLocalDuplicates([
        book(1, title: '长风集'),
        book(2, title: '长风集 - 第二卷'),
        book(3, title: '《长风集》番外'),
        book(4, title: '长风集 修订版'),
      ]);
      expect(report.title, isEmpty);
    },
  );

  test('generic numbered filenames do not group different metadata titles', () {
    expect(
      findLocalDuplicates([
        book(1, title: '长风集', filename: '1.txt'),
        book(2, title: '孤岛', filename: '1.txt'),
      ]).title,
      isEmpty,
    );
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

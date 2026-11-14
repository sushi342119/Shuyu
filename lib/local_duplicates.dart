import 'local_library.dart';
import 'filename_tags.dart';

enum LocalDuplicateKind { content, title }

class LocalDuplicateGroup {
  LocalDuplicateGroup(this.kind, Iterable<LocalBook> books)
    : books = List.unmodifiable(books);

  final LocalDuplicateKind kind;
  final List<LocalBook> books;
}

class LocalDuplicateReport {
  const LocalDuplicateReport(this.content, this.title);

  final List<LocalDuplicateGroup> content;
  final List<LocalDuplicateGroup> title;
}

/// Strip only explicit copy words ("副本") for strong identity; parenthesized or
/// bracketed numbers like `(1)` / `[01]` may denote light-novel volumes and are
/// treated only as weak aliases so `(1)` and `(2)` never merge without a bare
/// unnumbered counterpart.
String _trimExplicitCopyMarker(String title) {
  var key = title.trim();
  String previous;
  do {
    previous = key;
    key = key.replaceAll(
      RegExp(r'\s*[-_ ]*副本(?:\s*[（(\[]?\d+[）)\]]?)?\s*$'),
      '',
    );
  } while (key != previous);
  return key;
}

/// Normalize common copy markers for weak candidate matching.
String _trimCopySuffix(String title) {
  var key = title.trim();
  String previous;
  do {
    previous = key;
    key = key.replaceAll(RegExp(r'\s*[（(\[]\d+[）)\]]\s*$'), '');
    key = key.replaceAll(RegExp(r'\s*[-_ ]*副本\s*$'), '');
  } while (key != previous);
  return key;
}

String _normalizeRawTitleKey(String title) {
  var key = _trimExplicitCopyMarker(title).toLowerCase();
  key = key.replaceAll('（', '(').replaceAll('）', ')');
  key = key.replaceAll(RegExp(r'[\s\u3000_]+'), '');
  if (key.startsWith('《') && key.endsWith('》')) {
    key = key.substring(1, key.length - 1);
  }
  return key;
}

String duplicateTitleKey(String title) =>
    _normalizeRawTitleKey(_trimCopySuffix(title));

bool _usableTitleKey(String key) =>
    key.isNotEmpty && !RegExp(r'^[\d\s._\-()\[\]]+$').hasMatch(key);

bool _isEditionSuffix(String suffix) => RegExp(
  r'^(?:第?[0-9０-９零一二三四五六七八九十百]+[卷部集册章回]|[卷部集册][0-9０-９零一二三四五六七八九十百]+|[上下中][卷部册篇]?|番外|外传|后传|前传|续集|续篇|完整版|修订版|精校版)',
).hasMatch(suffix.trim());

/// Weak aliases only match an existing complete title. In particular, volume
/// 1 and volume 2 must not join just because both end in a number.
({
  Set<String> strong,
  Set<String> weak,
  String author,
  bool knownAuthor,
})
_titleAliases(LocalBook book) {
  final strong = <String>{};
  final weak = <String>{};
  final author = duplicateTitleKey(book.displayAuthor);
  final knownAuthor =
      author.isNotEmpty && !{'未知', '未知作者', '佚名', '作者不详'}.contains(author);
  void addWeak(String raw) {
    final key = duplicateTitleKey(raw);
    if (!_usableTitleKey(key)) return;
    weak.add(key);
    final numbered = RegExp(r'^(.*?)[\s_\-]*[0-9０-９]+$').firstMatch(key);
    if (numbered != null && _usableTitleKey(numbered[1]!)) {
      weak.add(numbered[1]!);
    }
  }

  void add(String raw, {bool weakOnly = false}) {
    var title = _trimExplicitCopyMarker(raw);
    final explicitAuthor = RegExp(
      r'\s*(?:[-_—–：:]\s*)?(?:[（(\[【]\s*)?(?:作者\s*[:：]?|著者\s*[:：]?|by\s+).+$',
      caseSensitive: false,
    ).firstMatch(title);
    if (explicitAuthor != null && explicitAuthor.start > 0) {
      title = title.substring(0, explicitAuthor.start).trim();
    }
    final quoted = RegExp(r'^《([^》]+)》\s*(.+)$').firstMatch(title);
    if (quoted != null && !_isEditionSuffix(quoted[2]!)) {
      addWeak(quoted[1]!);
    }
    var key = _normalizeRawTitleKey(title);
    if (!_usableTitleKey(key)) return;
    (weakOnly ? weak : strong).add(key);
    if (knownAuthor && key.endsWith(author) && key.length > author.length) {
      key = key
          .substring(0, key.length - author.length)
          .replaceFirst(RegExp(r'[\s_\-—–:：（(\[【]+$'), '');
      key = _normalizeRawTitleKey(key);
      if (_usableTitleKey(key)) (weakOnly ? weak : strong).add(key);
    }
    // Bare "书名1", "书名_1" and "书名 1" are candidates, never exact proof.
    final numbered = RegExp(r'^(.*?)[\s_\-]*[0-9０-９]+$').firstMatch(key);
    if (numbered != null && _usableTitleKey(numbered[1]!)) {
      weak.add(numbered[1]!);
    }
    final delimited = RegExp(
      r'^(.*?)\s*(?:\s+|[_\-—–]|[（(\[【])\s*([^\s]+)[）)\]】]?\s*$',
    ).firstMatch(title);
    if (delimited != null && !_isEditionSuffix(delimited[2]!)) {
      addWeak(delimited[1]!);
    }
    final copyTrimmed = _trimCopySuffix(title);
    if (copyTrimmed != title && copyTrimmed.isNotEmpty) {
      addWeak(copyTrimmed);
      if (!weakOnly) add(copyTrimmed, weakOnly: true);
    }
  }

  add(book.displayTitle);
  // Filenames remain useful when EPUB/MOBI metadata uses a different title.
  var filename = stripFilenameTags(book.fileName);
  filename = filename.replaceFirst(
    RegExp(r'\.(?:txt|epub|pdf|mobi|azw3)$', caseSensitive: false),
    '',
  );
  add(filename, weakOnly: true);
  if (knownAuthor) {
    for (final key in strong.toList()) {
      weak.add('$key$author');
    }
  }
  return (
    strong: strong,
    weak: weak,
    author: author,
    knownAuthor: knownAuthor,
  );
}

/// Linear union by SHA-256. Empty fingerprints must never join unrelated books.
/// Source-byte and decoded-text hashes have separate namespaces.
LocalDuplicateReport findLocalDuplicates(List<LocalBook> input) {
  final books = {for (final book in input) book.id: book}.values.toList();
  final parents = List.generate(books.length, (i) => i);
  int root(int i) {
    while (parents[i] != i) {
      parents[i] = parents[parents[i]];
      i = parents[i];
    }
    return i;
  }

  final seen = <String, int>{};
  for (var i = 0; i < books.length; i++) {
    final book = books[i];
    final keys = <String>[
      if (book.sourceFingerprint.isNotEmpty) 'source:${book.sourceFingerprint}',
      if (book.textFingerprint.isNotEmpty) 'text:${book.textFingerprint}',
    ];
    for (final key in keys) {
      final previous = seen.putIfAbsent(key, () => i);
      parents[root(i)] = root(previous);
    }
  }
  final byContent = <int, List<LocalBook>>{};
  for (var i = 0; i < books.length; i++) {
    final book = books[i];
    byContent.putIfAbsent(root(i), () => []).add(book);
  }
  final rootById = {
    for (var i = 0; i < books.length; i++) books[i].id: root(i),
  };
  final titleParents = List.generate(books.length, (i) => i);
  int titleRoot(int i) {
    while (titleParents[i] != i) {
      titleParents[i] = titleParents[titleParents[i]];
      i = titleParents[i];
    }
    return i;
  }

  final aliases = books.map(_titleAliases).toList();
  bool compatibleAuthors(int a, int b) =>
      !aliases[a].knownAuthor ||
      !aliases[b].knownAuthor ||
      aliases[a].author == aliases[b].author;

  final titleIndex = <String, List<int>>{};
  for (var i = 0; i < books.length; i++) {
    for (final key in aliases[i].strong) {
      final bucket = titleIndex.putIfAbsent(key, () => <int>[]);
      for (final previous in bucket) {
        if (compatibleAuthors(i, previous)) {
          titleParents[titleRoot(i)] = titleRoot(previous);
          break;
        }
      }
      bucket.add(i);
    }
  }
  for (var i = 0; i < books.length; i++) {
    for (final key in aliases[i].weak) {
      final bucket = titleIndex[key];
      if (bucket == null) continue;
      for (final previous in bucket) {
        if (compatibleAuthors(i, previous)) {
          titleParents[titleRoot(i)] = titleRoot(previous);
          break;
        }
      }
    }
    // Some collections concatenate an unknown pen name with no separator.
    // A short Chinese suffix is only a suspicion, and must have an actual
    // standalone title elsewhere in this library. Never use it as content proof,
    // and never treat a subtitle/sequel on a book with a known author as an
    // unknown pen name.
    if (!aliases[i].knownAuthor) {
      for (final key in {...aliases[i].strong, ...aliases[i].weak}) {
        for (var length = 2; length <= 8 && key.length - length >= 2; length++) {
          final suffix = key.substring(key.length - length);
          if (!RegExp(r'^[\u3400-\u9fff·]+$').hasMatch(suffix) ||
              _isEditionSuffix(suffix) ||
              RegExp(r'^[之的与和续第卷部章篇]').hasMatch(suffix)) {
            continue;
          }
          final bucket = titleIndex[key.substring(0, key.length - length)];
          if (bucket == null) continue;
          for (final previous in bucket) {
            if (!aliases[previous].knownAuthor ||
                aliases[previous].author == suffix) {
              titleParents[titleRoot(i)] = titleRoot(previous);
              break;
            }
          }
        }
      }
    }
  }
  final byTitle = <int, List<LocalBook>>{};
  for (var i = 0; i < books.length; i++) {
    byTitle.putIfAbsent(titleRoot(i), () => []).add(books[i]);
  }
  List<LocalDuplicateGroup> groups(
    Iterable<List<LocalBook>> values,
    LocalDuplicateKind kind,
  ) =>
      [
        for (final group in values)
          if (group.length > 1 &&
              (kind == LocalDuplicateKind.content ||
                  group.map((b) => rootById[b.id]).toSet().length > 1))
            LocalDuplicateGroup(kind, group),
      ]..sort(
        (a, b) =>
            a.books.first.displayTitle.compareTo(b.books.first.displayTitle),
      );

  return LocalDuplicateReport(
    groups(byContent.values, LocalDuplicateKind.content),
    groups(byTitle.values, LocalDuplicateKind.title),
  );
}

/// Prefer the copy with reading history or annotations, then bookmark count and
/// recency. Stable tie breaks make refreshes predictable; never auto-deletes.
LocalBook recommendedDuplicateKeeper(
  List<LocalBook> books, {
  required bool Function(int) hasRead,
  required int Function(int) lastReadAt,
  int Function(int)? annotationCount,
}) {
  int marksOf(int id) => annotationCount?.call(id) ?? 0;
  bool activeOf(int id) => hasRead(id) || marksOf(id) > 0;
  final ranked = [...books]
    ..sort((a, b) {
      final read = (activeOf(b.id) ? 1 : 0).compareTo(activeOf(a.id) ? 1 : 0);
      if (read != 0) return read;
      final marks = marksOf(b.id).compareTo(marksOf(a.id));
      if (marks != 0) return marks;
      final recent = lastReadAt(b.id).compareTo(lastReadAt(a.id));
      if (recent != 0) return recent;
      final words = (b.wordCount ?? 0).compareTo(a.wordCount ?? 0);
      if (words != 0) return words;
      final size = b.size.compareTo(a.size);
      return size != 0 ? size : a.id.compareTo(b.id);
    });
  return ranked.first;
}

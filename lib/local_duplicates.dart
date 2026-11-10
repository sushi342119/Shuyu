import 'local_library.dart';

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

/// Keep volume numbers, edition names and punctuation inside the title. Only
/// remove common OS copy suffixes; a name match is never proof of equal content.
String duplicateTitleKey(String title) {
  var key = title.trim().toLowerCase();
  key = key.replaceAll(RegExp(r'\s*[（(]\d+[）)]\s*$'), '');
  key = key.replaceAll(RegExp(r'\s*[-_ ]*副本\s*$'), '');
  key = key.replaceAll(RegExp(r'[\s\u3000_]+'), '');
  if (key.startsWith('《') && key.endsWith('》')) {
    key = key.substring(1, key.length - 1);
  }
  return key;
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
  final byTitle = <String, List<LocalBook>>{};
  for (var i = 0; i < books.length; i++) {
    final book = books[i];
    byContent.putIfAbsent(root(i), () => []).add(book);
    final title = duplicateTitleKey(book.displayTitle);
    if (title.isNotEmpty) byTitle.putIfAbsent(title, () => []).add(book);
  }
  final rootById = {
    for (var i = 0; i < books.length; i++) books[i].id: root(i),
  };
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

/// Prefer the copy with reading history, then the most recently read copy.
/// Stable tie breaks make refreshes predictable; this never selects deletions.
LocalBook recommendedDuplicateKeeper(
  List<LocalBook> books, {
  required bool Function(int) hasRead,
  required int Function(int) lastReadAt,
}) {
  final ranked = [...books]
    ..sort((a, b) {
      final read = (hasRead(b.id) ? 1 : 0).compareTo(hasRead(a.id) ? 1 : 0);
      if (read != 0) return read;
      final recent = lastReadAt(b.id).compareTo(lastReadAt(a.id));
      if (recent != 0) return recent;
      final words = (b.wordCount ?? 0).compareTo(a.wordCount ?? 0);
      if (words != 0) return words;
      final size = b.size.compareTo(a.size);
      return size != 0 ? size : a.id.compareTo(b.id);
    });
  return ranked.first;
}

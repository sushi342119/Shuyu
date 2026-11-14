/// File imports stream TXT and EPUB entries off the UI isolate.
const maxLocalTextBytes = 128 * 1024 * 1024;
const maxLocalEpubBytes = 512 * 1024 * 1024;
const maxLocalArchiveBytes = 512 * 1024 * 1024;

final _bookImportExtension = RegExp(
  r'\.(txt|epub|mobi|azw|azw3|prc|fb2|pdf|docx?|rtf|html?|xhtml|md|markdown|cbz|zip)$',
  caseSensitive: false,
);

bool supportsBookImport(String name) => _bookImportExtension.hasMatch(name);

int localBookByteLimit(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'zip' || 'cbz' => maxLocalArchiveBytes,
      'epub' || 'pdf' || 'docx' => maxLocalEpubBytes,
      'mobi' || 'azw' || 'azw3' || 'prc' => 256 * 1024 * 1024,
      'html' || 'htm' || 'xhtml' || 'md' || 'markdown' => 32 * 1024 * 1024,
      _ => maxLocalTextBytes,
    };

String localBookSizeMessage(String name) =>
    '单个 ${name.split('.').last.toUpperCase()} 不能超过 ${localBookByteLimit(name) ~/ (1024 * 1024)} MiB';


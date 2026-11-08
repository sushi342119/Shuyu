String readerLanguageCode(String value) {
  final tag = value.trim().replaceAll('_', '-');
  if (!RegExp(r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8}){0,4}$').hasMatch(tag)) {
    return '';
  }
  return tag.split('-').first.toLowerCase();
}

/// Primary language matching tolerates ISO metadata emitted by Android engines.
String speechLanguageCode(String value) => switch (readerLanguageCode(value)) {
  'chi' || 'zho' => 'zh',
  'jpn' => 'ja',
  'eng' => 'en',
  'kor' => 'ko',
  final code => code,
};

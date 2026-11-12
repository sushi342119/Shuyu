import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/chapter_splitter.dart';

String _body(int n) =>
    List.filled(n, '他走在路上，看着远处的山，心里想着很多事情。').join('\n');

List<String> _split(List<String> heads) {
  final text = [for (final h in heads) '$h\n${_body(6)}'].join('\n');
  return splitLocalChapters(normalizeLocalText(text))
      .map((c) => c.title)
      .toList();
}

void main() {
  final main12 = [for (var i = 1; i <= 12; i++) '第$i章 标题$i'];

  test('a lone 第N节 continuing the 第N章 sequence stays its own chapter', () {
    final heads = [...main12, '第13节 小插曲', '第14章 后来'];
    final titles = _split(heads);
    expect(titles, hasLength(heads.length));
    expect(titles[12], contains('第13节'));
  });

  test('a lone 第N回 written in Chinese numerals is not merged', () {
    final heads = [...main12, '第十三回 小插曲', '第14章 后来'];
    final titles = _split(heads);
    expect(titles, hasLength(heads.length));
    expect(titles[12], contains('第十三回'));
  });

  test('Chinese numeral chapter inside an Arabic sequence splits', () {
    final many = [for (var i = 1; i <= 20; i++) '第$i章 标题$i'];
    final heads = [...many.take(10), '第十一章 标题', ...many.skip(11)];
    expect(_split(heads), hasLength(heads.length));
  });

  test('a lone 第N节 that breaks the sequence is still not a chapter', () {
    final heads = [...main12, '第3节 回忆', '第13章 后来'];
    expect(_split(heads), hasLength(heads.length - 1));
  });
}

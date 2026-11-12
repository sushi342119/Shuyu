import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/chapter_splitter.dart';

import 'support/chapter_rules_cases.dart';

const _body = '这一段是独立的测试正文，长度超过八字，用来建立章节正文证据。';
const _displayTitles = {
  'H03': '第二章 夜雨',
  'H04': '第三章 晨光',
  'H46': '第一章起点',
  'H47': '第一章 起点',
  'P25': '1234567890',
};

String _bodyOf(String text, LocalChapterIndex chapter) =>
    text.substring(chapter.offset, chapter.offset + chapter.length);

void _checkCoordinates(String text, List<LocalChapterIndex> chapters) {
  expect(validChapterRanges(chapters, text.length), isTrue);
  final bytes = utf8.encode(text);
  for (final chapter in chapters) {
    expect(chapter.title.trim(), isNotEmpty);
    expect(_bodyOf(text, chapter).trim(), isNotEmpty);
    expect(
      chapter.byteOffset,
      utf8.encode(text.substring(0, chapter.offset)).length,
    );
    expect(
      utf8.decode(
        bytes.sublist(
          chapter.byteOffset,
          chapter.byteOffset + chapter.byteLength,
        ),
      ),
      _bodyOf(text, chapter),
    );
  }
}

void main() {
  test('the comparison corpus has 53 headings and 26 prose samples', () {
    expect(chapterRuleCases, hasLength(79));
    expect(chapterRuleCases.map((sample) => sample.id).toSet(), hasLength(79));
    expect(
      chapterRuleCases.where((sample) => sample.id.startsWith('H')),
      hasLength(53),
    );
    expect(
      chapterRuleCases.where((sample) => sample.id.startsWith('P')),
      hasLength(26),
    );
  });

  for (final sample in chapterRuleCases) {
    test('${sample.id} fixed v5/v6 result: ${sample.line}', () {
      final text = '${sample.line}\n$_body\n${sample.line}\n$_body\n';
      for (final enabled in [false, true]) {
        final chapters = splitLocalChapters(
          text,
          enableChapterExtensions: enabled,
        );
        final hit =
            chapterRuleUpstreamAdditions.contains(sample.id) ||
            (enabled ? sample.v4 : sample.v3);
        expect(chapters.length, hit ? 2 : 1, reason: 'extensions=$enabled');
        if (!hit) {
          expect(chapters.single.title, '正文');
          expect(_bodyOf(text, chapters.single), text);
        } else {
          expect(
            chapters.map((chapter) => chapter.title),
            List.filled(2, _displayTitles[sample.id] ?? sample.line),
          );
          expect(
            chapters.every((chapter) => _bodyOf(text, chapter) == '$_body\n'),
            isTrue,
          );
        }
        _checkCoordinates(text, chapters);
      }
    });
  }

  test('explicit front matter titles need no second matching heading', () {
    for (final title in [
      '扉页',
      '简介',
      '内容简介',
      '文章简介',
      '书籍简介',
      '文案',
      '作品相关',
      for (final position in ['首', '尾', '末'])
        for (final kind in ['语', '总结', '感言']) '卷$position$kind',
    ]) {
      final text = '$title\n$_body\n';
      final chapters = splitLocalChapters(text);
      expect(chapters.single.title, title);
      expect(chapters.single.volume, isEmpty);
      expect(_bodyOf(text, chapters.single), '$_body\n');
      _checkCoordinates(text, chapters);
    }
  });

  test(
    'extension tails require an explicit delimiter and at most 20 code points',
    () {
      for (final separator in [
        '：',
        ':',
        '；',
        ';',
        '—',
        '·',
        '｜',
        '–',
        '.',
        '|',
        '-',
      ]) {
        final title = '简介 $separator 旅途😀';
        expect(splitLocalChapters('$title\n$_body').single.title, title);
        final boundary = '简介$separator${'😀' * 20}';
        final chapter = splitLocalChapters('$boundary\n$_body').single;
        expect(chapter.title, boundary);
        expect(_bodyOf('$boundary\n$_body', chapter), _body);
      }
      final boundary = '简介：${'😀' * 20}';
      expect(splitLocalChapters('$boundary\n$_body').single.title, boundary);
      for (final title in [
        '简介：第一章之旅',
        '作品相关：Chapter IV',
        '卷首语：第一卷',
        '卷首语：第一章',
      ]) {
        final chapter = splitLocalChapters('$title\n$_body').single;
        expect(chapter.title, title);
        expect(chapter.volume, isEmpty);
      }
      const legacyPrefix = '简介 第一章 开始';
      expect(
        splitLocalChapters('$legacyPrefix\n$_body').single.title,
        legacyPrefix,
      );
      for (final line in [
        '简介旅途',
        '简介 旅途',
        '简介：他推开了门。',
        '简介：真的吗？',
        '简介：${'题' * 21}',
        '简介：${'😀' * 21}',
        '卷首语写得很好',
        '作品相关资料正在整理',
        '扉页${' ' * 3000}这里是正文',
        '简介${' ' * 3000}',
        '文案：${'字' * 100000}',
      ]) {
        final text = '$line\n$_body\n';
        final chapters = splitLocalChapters(text);
        expect(
          chapters.single.title,
          '正文',
          reason: line.substring(0, line.length.clamp(0, 80)),
        );
        expect(_bodyOf(text, chapters.single), text);
      }
    },
  );

  test(
    'front matter, author announcements and unheaded opening retain their text',
    () {
      const opening = '没有标题的开场😀\n';
      const text =
          '$opening扉页\n作者：张三\n简介：旅途\n旅途从这里开始。\n'
          '上架感言\n请假一天\n感谢大家支持\n更新说明\n'
          '第一章起点\n第一节课是数学课\n  后来他请假一天回家\n'
          '  我们感谢大家支持\n这份简介写得很好\n第二章夜雨\n结束。\n';
      final chapters = splitLocalChapters(text);
      expect(chapters.map((chapter) => chapter.title), [
        '前言',
        '扉页',
        '简介：旅途',
        '第一章起点',
        '第二章夜雨',
      ]);
      expect(_bodyOf(text, chapters[0]), opening);
      expect(_bodyOf(text, chapters[1]), '作者：张三\n');
      expect(
        _bodyOf(text, chapters[2]),
        '旅途从这里开始。\n上架感言\n请假一天\n感谢大家支持\n更新说明\n',
      );
      expect(
        _bodyOf(text, chapters[3]),
        '第一节课是数学课\n  后来他请假一天回家\n  我们感谢大家支持\n这份简介写得很好\n',
      );
      _checkCoordinates(text, chapters);
    },
  );

  test(
    'directory duplicates, empty headings and multiple volumes share v3 filtering',
    () {
      const text =
          '目录\n扉页\n简介\n第一卷 风起\n第一章 起点\n第二卷 雨落\n第二章 夜雨\n'
          '扉页\n作者：张三\n简介\n这是一段内容简介。\n'
          '第一卷 风起\n卷首语\n这是第一卷的开场。\n第一章 起点\n正文甲。\n'
          '第二卷 雨落\n卷首语\n这是第二卷的开场。\n第二章 夜雨\n正文乙。\n'
          '作品相关\n文案\n';
      final chapters = splitLocalChapters(text);
      expect(chapters.map((chapter) => chapter.title), [
        '前言',
        '扉页',
        '简介',
        '卷首语',
        '第一章 起点',
        '卷首语',
        '第二章 夜雨',
      ]);
      expect(chapters[3].volume, '第一卷 风起');
      expect(chapters[4].volume, '第一卷 风起');
      expect(chapters[5].volume, '第二卷 雨落');
      expect(chapters[6].volume, '第二卷 雨落');
      expect(_bodyOf(text, chapters.first), startsWith('目录\n扉页\n简介\n'));
      _checkCoordinates(text, chapters);
      for (final text in ['扉页\n简介\n文案\n', '没有任何标题。\n  只有正文😀\n']) {
        final fallback = splitLocalChapters(text);
        expect(fallback.single.title, '正文');
        expect(_bodyOf(text, fallback.single), text);
      }
    },
  );

  test(
    'extensions do not supply weak evidence for bare numbers and in-body lists',
    () {
      const text =
          '简介\n$_body\n第一章 开场\n一、甲\n二、乙\n三、丙\n'
          '1.单个弱标题\n$_body\n第二章 结束\n$_body';
      expect(splitLocalChapters(text).map((chapter) => chapter.title), [
        '简介',
        '第一章 开场',
        '第二章 结束',
      ]);
    },
  );

  test(
    'CRLF, emoji and arbitrary chunk boundaries keep all source coordinates',
    () {
      final text = normalizeLocalText(
        '\uFEFF开场😀\r\n${'　' * 5000}扉页\r\n作者：张三😀\r\n'
        '简介：😀远航\r\n正文😀\u2028卷首语\u2029卷的开场😀\r第一章开始\r\n正文末尾😀',
      );
      for (final enabled in [false, true]) {
        final expected = splitLocalChapters(
          text,
          enableChapterExtensions: enabled,
        );
        _checkCoordinates(text, expected);
        for (final size in [1, 2, 3, 7, 1024, 65536]) {
          final index = ChapterTextIndex(enableChapterExtensions: enabled);
          for (var offset = 0; offset < text.length; offset += size) {
            index.add(
              text.substring(offset, (offset + size).clamp(0, text.length)),
            );
          }
          expect(
            index.finish().map((chapter) => chapter.toJson()),
            expected.map((chapter) => chapter.toJson()),
            reason: 'enabled=$enabled chunk=$size',
          );
        }
      }
    },
  );

  test(
    'bounded line prefixes never turn truncated prose into an extension title',
    () {
      final text =
          '简介${' ' * 65536}这里不是标题。\n扉页\n$_body\n文案：${'字' * 200000}\n$_body';
      final expected = splitLocalChapters(text);
      expect(expected.map((chapter) => chapter.title), ['前言', '扉页']);
      for (final size in [31, 1024, 65536]) {
        final index = ChapterTextIndex();
        for (var offset = 0; offset < text.length; offset += size) {
          index.add(
            text.substring(offset, (offset + size).clamp(0, text.length)),
          );
        }
        expect(
          index.finish().map((chapter) => chapter.toJson()),
          expected.map((chapter) => chapter.toJson()),
        );
      }
      _checkCoordinates(text, expected);
    },
  );

  test(
    'mid-line and end-of-line glued strong headings split cleanly without breaking dialogue',
    () {
      const text =
          '第一章 开端\n'
          '前文结束，他说“第二章写得真好”随后合上书卷缓步离开。第二章 夜雨　　'
          '夜雨淅沥落下，打湿了长街尽头的青石板路！”第三章 破晓\n'
          '东方天色微亮，晨风吹散了整夜未歇的浓雾……第四章 远行\n'
          '旅途继续向前延伸，远山在朝阳下格外清晰。\n';
      final expected = splitLocalChapters(text);
      expect(expected.map((c) => c.title), [
        '第一章 开端',
        '第二章 夜雨',
        '第三章 破晓',
        '第四章 远行',
      ]);
      expect(_bodyOf(text, expected[0]), '前文结束，他说“第二章写得真好”随后合上书卷缓步离开。');
      expect(_bodyOf(text, expected[1]).trim(), '夜雨淅沥落下，打湿了长街尽头的青石板路！”');
      expect(_bodyOf(text, expected[2]), '东方天色微亮，晨风吹散了整夜未歇的浓雾……');
      expect(_bodyOf(text, expected[3]), '旅途继续向前延伸，远山在朝阳下格外清晰。\n');
      _checkCoordinates(text, expected);
      for (final size in [1, 2, 3, 7, 64]) {
        final index = ChapterTextIndex();
        for (var offset = 0; offset < text.length; offset += size) {
          index.add(
            text.substring(offset, (offset + size).clamp(0, text.length)),
          );
        }
        expect(
          index.finish().map((c) => c.toJson()),
          expected.map((c) => c.toJson()),
          reason: 'chunk=$size',
        );
      }
    },
  );

  test(
    'split-volume markers, middle-dot specials, combined volume headings and single strong chapters work',
    () {
      const splitVolumeText = '分卷阅读1\n$_body\n分卷阅读 2\n$_body\n分节阅读3\n$_body\n';
      final splitVolumeChapters = splitLocalChapters(splitVolumeText);
      expect(splitVolumeChapters.map((c) => c.title), [
        '分卷阅读1',
        '分卷阅读 2',
        '分节阅读3',
      ]);
      _checkCoordinates(splitVolumeText, splitVolumeChapters);

      const specialDotText =
          '楔子·风起\n$_body\n第一章 启程\n$_body\n番外·故人归\n$_body\n尾声・灯火\n$_body\n';
      final specialDotChapters = splitLocalChapters(specialDotText);
      expect(specialDotChapters.map((c) => c.title), [
        '楔子·风起',
        '第一章 启程',
        '番外·故人归',
        '尾声・灯火',
      ]);
      _checkCoordinates(specialDotText, specialDotChapters);

      const combinedVolText =
          '第一卷 风起 第一章 初见\n$_body\n第二章 同行\n$_body\n第二卷 云涌 第三章 转折\n$_body\n';
      final combinedVolChapters = splitLocalChapters(combinedVolText);
      expect(combinedVolChapters.map((c) => c.title), [
        '第一卷 风起 第一章 初见',
        '第二章 同行',
        '第二卷 云涌 第三章 转折',
      ]);
      expect(combinedVolChapters.map((c) => c.volume), [
        '第一卷 风起',
        '第一卷 风起',
        '第二卷 云涌',
      ]);
      _checkCoordinates(combinedVolText, combinedVolChapters);

      const singleStrongText = '第一章 独篇故事\n$_body\n';
      final singleStrong = splitLocalChapters(singleStrongText);
      expect(singleStrong.single.title, '第一章 独篇故事');
      _checkCoordinates(singleStrongText, singleStrong);

      const unmarkedTocText =
          '第一章 起点\n第二章 夜雨\n第三章 晨光\n'
          '第一章 起点\n$_body\n第二章 夜雨\n$_body\n第三章 晨光\n$_body\n';
      final unmarkedToc = splitLocalChapters(unmarkedTocText);
      expect(unmarkedToc.map((c) => c.title), [
        '前言',
        '第一章 起点',
        '第二章 夜雨',
        '第三章 晨光',
      ]);
      _checkCoordinates(unmarkedTocText, unmarkedToc);
    },
  );
}

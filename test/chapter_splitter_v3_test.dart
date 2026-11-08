import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/chapter_splitter.dart';

void main() {
  String body(String text, LocalChapterIndex c) =>
      text.substring(c.offset, c.offset + c.length);
  test(
    'format families, decorations and arbitrary indentation keep UTF16 offsets',
    () {
      final families = <List<String>>[
        ['（01）晨钟', '（02）夜雨'],
        ['1.暗室', '2.明灯'],
        ['九章：画', '十章：梦'],
        ['01 标题', '02 标题'],
        ['一、起点', '二、终点'],
        ['百花盛放 第01章', '百花盛放 第02章'],
        ['正文 第002章', '【正文】第三章'],
        ['【书名】（13）', '【书名】（14）'],
        ['Chapter IV', 'CHAPTER V'],
        ['chapter １', 'CHAPTER ２'],
        ['第一節', '第兩話'],
        ['第壹章', '第贰章'],
        ['第一折', '第二折'],
        ['序幕', '后日谈'],
        ['外篇：早春', '外传：暮夏'],
        ['上篇', '下篇（END）'],
        ['【美母的信念】（1-128）第零章', '【美母的信念】（1-128）第一章'],
        ['【01】', '【02】'],
        ['[01] 破晓', '[02] 暮色'],
        ['《锦衣群芳录》（01）', '《锦衣群芳录》（02）'],
        ['丝袜警花妈妈与我的同班同学（1）', '丝袜警花妈妈与我的同班同学（2）'],
        ['重活一世-从玩弄媳妇开始(1)', '重活一世-从玩弄媳妇开始(2)'],
        ['第一卷 潜龙在渊 第一章 初入江湖', '第一卷 潜龙在渊 第二章 风起云涌'],
        ['第一集05回：携云', '第一集06回：听雨'],
        ['第1-2章 合章', '第3-4章 续篇'],
        ['第廿一章 廿字回', '第卅二章 卅字回'],
        ['【书名】（第一章）', '【书名】（第二章）'],
        ['《妈妈，请再爱我一次》第一章', '《妈妈，请再爱我一次》第二章'],
        ['第1——5章 开篇', '第6——10章 续篇'],
        ['（1——5）开篇', '（6——10）续篇'],
        ['丝袜警花妈妈（1）初识', '丝袜警花妈妈（2）重逢'],
        ['美母攻略 01', '美母攻略 02'],
        ['美母攻略 - 01 初遇', '美母攻略 - 02 夜谈'],
        ['（1）第一节课', '（2）第一部作品'],
        ['01. 她的第一部电影，也是最后一部', '02. 久违的晴天，微风轻拂'],
        ['第一部分', '第二部分'],
        ['第一章 完本感言', '第二章 后记与鸣谢'],
      ];
      for (final headings in families) {
        final text =
            '${' ' * 120}\uFEFF\u00a0#🍎 ${headings[0]}\n这是第一段独立正文，完整保留😀。\n\n'
            '${'　' * 70}${headings[1]}\n这是第二段独立正文，完整保留。\n';
        final chapters = splitLocalChapters(text);
        expect(chapters.length, 2, reason: headings.toString());
        expect(body(text, chapters.first), contains('第一段独立正文'));
        expect(body(text, chapters.last), contains('第二段独立正文'));
        expect(validChapterRanges(chapters, text.length), isTrue);
      }
    },
  );
  test('long titles, forum suffix and glued prose take distinct body ranges', () {
    final longTitle = '第一章 ${'标题' * 24}';
    const glued = '第30章：包装才女马车带着烟尘，向南而去我怔了一会儿，忽然一道动听悦耳的声音从我背后传来。';
    final text =
        '$longTitle\n正文甲。\n$glued\n正文乙。\n第31章 [bbs]viewthread.php?tid=10904118&page=1#pid107855814[/bbs]\n正文丙。';
    final chapters = splitLocalChapters(text);
    expect(chapters.first.title, longTitle);
    expect(chapters[1].title, '第30章');
    expect(body(text, chapters[1]), startsWith('：包装才女马车'));
    expect(body(text, chapters[1]), contains('从我背后传来。'));
    expect(chapters.last.title, '第31章');
    expect(body(text, chapters.last), '正文丙。');
  });
  test(
    'TOC entries and empty volumes do not open chapters; volume is metadata',
    () {
      const text =
          '目录\n第一卷\n第一章 起点\n第二章 终点\n\n第一卷\n第一章 起点\n真实正文一。\n第二章 终点\n真实正文二。\n【第一卷完】\n';
      final chapters = splitLocalChapters(text);
      expect(chapters.map((c) => c.title), ['前言', '第一章 起点', '第二章 终点']);
      expect(chapters[1].volume, '第一卷');
      expect(chapters[2].volume, '第一卷');
      expect(chapters.every((c) => body(text, c).trim().isNotEmpty), isTrue);

      final intro = '内容简介\n${'这是一段很长的内容简介，介绍了故事的背景与主要人物。' * 12}\n';
      final multiVolText =
          '$intro目录\n第一卷 初入江湖\n第一章 起点\n第二章 终点\n第二卷 风起云涌\n第三章 破晓\n\n'
          '第一卷 初入江湖\n第一章 起点\n真实正文一。\n第二章 终点\n真实正文二。\n'
          '第二卷 风起云涌\n第三章 破晓\n真实正文三。\n';
      final multiVolChapters = splitLocalChapters(multiVolText);
      expect(multiVolChapters.map((c) => c.title), [
        '内容简介',
        '第一章 起点',
        '第二章 终点',
        '第三章 破晓',
      ]);
      expect(multiVolChapters[1].volume, '第一卷 初入江湖');
      expect(multiVolChapters[2].volume, '第一卷 初入江湖');
      expect(multiVolChapters[3].volume, '第二卷 风起云涌');
    },
  );
  test('whole-word prose and inline lists never create chapters', () {
    final text =
        '第一章 早晨\n${['第一回来此，手忙脚乱难免有些差池。', '第三回合的比赛前认真准备。', '第一节课是数学课', '第一部分内容继续', '尾声渐渐消失。', '三部AV里出现了长长的正文。', '一、甲', '二、乙', '三、丙'].join('\n')}\n第二章 夜晚\n结束。';
    final chapters = splitLocalChapters(text);
    expect(chapters.map((c) => c.title), ['第一章 早晨', '第二章 夜晚']);
  });
  test('unheaded opening and single heading both remain readable', () {
    final opening = '开场😀\n' * 60000;
    final text = '$opening第一章 唯一\n末尾正文';
    final chapters = splitLocalChapters(text);
    expect(chapters.map((c) => c.title), ['前言', '第一章 唯一']);
    expect(body(text, chapters.first), opening);
  });
  test(
    'streaming chunk boundaries never change headings or surrogate coordinates',
    () {
      final text = normalizeLocalText(
        '\uFEFF开场😀\r\n${'　' * 5000}第一章 首\u2028正文\u2029第二章 尾\r末尾',
      );
      final expected = splitLocalChapters(text).map((c) => c.toJson()).toList();
      for (final size in [1, 2, 3, 7, 1024, 65536]) {
        final index = ChapterTextIndex();
        for (var i = 0; i < text.length; i += size) {
          index.add(text.substring(i, (i + size).clamp(0, text.length)));
        }
        expect(
          index.finish().map((c) => c.toJson()),
          expected,
          reason: 'chunk $size',
        );
      }
    },
  );
  test(
    'inline chapter headings at end of paragraph split cleanly across chunks',
    () {
      const text =
          '第一章 晨雾\n'
          '清晨的雾气笼罩着山谷，两人相视一笑。第二章 暗流涌动\n'
          '夜色渐渐深沉，远处的灯火闪烁不定！”第三章 破晓时分\n'
          '天边终于泛起了鱼肚白。\n';
      final chapters = splitLocalChapters(text);
      expect(chapters.map((c) => c.title), [
        '第一章 晨雾',
        '第二章 暗流涌动',
        '第三章 破晓时分',
      ]);
      expect(body(text, chapters[0]), '清晨的雾气笼罩着山谷，两人相视一笑。');
      expect(body(text, chapters[1]), '夜色渐渐深沉，远处的灯火闪烁不定！”');
      expect(body(text, chapters[2]), '天边终于泛起了鱼肚白。\n');
      expect(validChapterRanges(chapters, text.length), isTrue);
      final expected = chapters.map((c) => c.toJson()).toList();
      for (final size in [1, 2, 3, 5, 11]) {
        final index = ChapterTextIndex();
        for (var i = 0; i < text.length; i += size) {
          index.add(text.substring(i, (i + size).clamp(0, text.length)));
        }
        expect(
          index.finish().map((c) => c.toJson()),
          expected,
          reason: 'chunk $size',
        );
      }
    },
  );
}

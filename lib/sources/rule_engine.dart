import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../regex_safety.dart';
import 'book_source.dart';
import 'network_url_safety.dart';
import 'source_image_cache.dart';

class ExtractedBookItem {
  const ExtractedBookItem({
    required this.title,
    required this.bookUrl,
    this.author = '',
    this.genre = '',
    this.summary = '',
    this.coverUrl,
    this.latestChapter = '',
    this.wordCount = '',
  });

  final String title;
  final String bookUrl;
  final String author;
  final String genre;
  final String summary;
  final String? coverUrl;
  final String latestChapter;
  final String wordCount;
}

class ExtractedBookDetail {
  const ExtractedBookDetail({
    this.title,
    this.author,
    this.genre,
    this.summary,
    this.coverUrl,
    this.latestChapter,
    this.tocUrl,
  });

  final String? title;
  final String? author;
  final String? genre;
  final String? summary;
  final String? coverUrl;
  final String? latestChapter;
  final String? tocUrl;
}

class RawExtractedChapter {
  const RawExtractedChapter({
    required this.title,
    required this.url,
    this.isVolume = false,
  });

  final String title;
  final String url;
  final bool isVolume;
}

class ExtractedTocPage {
  const ExtractedTocPage({
    required this.chapters,
    this.nextTocUrl,
  });

  final List<RawExtractedChapter> chapters;
  final String? nextTocUrl;
}

class ExtractedChapterPage {
  const ExtractedChapterPage({
    required this.body,
    this.nextContentUrl,
  });

  final String body;
  final String? nextContentUrl;
}

/// Pure-Dart, Isolate-safe static rule evaluator supporting CSS, Legado Jsoup
/// chains, XPath subset, JSONPath subset, Regex extraction/replacement, and
/// combinators (`||`, `&&`, `%%`).
abstract final class SourceRuleEngine {
  static const Duration defaultIsolateTimeout = Duration(seconds: 4);

  /// Runs [parseSearchOrExploreDirect] in a background [Isolate] when payload
  /// is non-trivial so expensive HTML/Regex parsing never blocks UI frames.
  static Future<List<ExtractedBookItem>> parseBookList({
    required String body,
    required String baseUrl,
    required SourceListRule rule,
    Duration timeout = defaultIsolateTimeout,
  }) async {
    if (body.trim().isEmpty || rule.isEmpty) return const [];
    if (body.length < 24 * 1024) {
      return parseBookListDirect(body: body, baseUrl: baseUrl, rule: rule);
    }
    return NetworkUrlSafety.runInIsolate(
      () => parseBookListDirect(body: body, baseUrl: baseUrl, rule: rule),
    ).timeout(
      timeout,
      onTimeout: () => throw TimeoutException('解析搜索/分类结果超时'),
    );
  }

  static Future<ExtractedBookDetail> parseBookDetail({
    required String body,
    required String pageUrl,
    required SourceBookInfoRule rule,
    Duration timeout = defaultIsolateTimeout,
  }) async {
    if (body.trim().isEmpty) return const ExtractedBookDetail();
    if (body.length < 24 * 1024) {
      return parseBookDetailDirect(body: body, pageUrl: pageUrl, rule: rule);
    }
    return NetworkUrlSafety.runInIsolate(
      () => parseBookDetailDirect(body: body, pageUrl: pageUrl, rule: rule),
    ).timeout(
      timeout,
      onTimeout: () => throw TimeoutException('解析书籍详情超时'),
    );
  }

  static Future<ExtractedTocPage> parseTocPage({
    required String body,
    required String pageUrl,
    required SourceTocRule rule,
    Duration timeout = defaultIsolateTimeout,
  }) async {
    if (body.trim().isEmpty || rule.isEmpty) {
      return const ExtractedTocPage(chapters: []);
    }
    if (body.length < 24 * 1024) {
      return parseTocPageDirect(body: body, pageUrl: pageUrl, rule: rule);
    }
    return NetworkUrlSafety.runInIsolate(
      () => parseTocPageDirect(body: body, pageUrl: pageUrl, rule: rule),
    ).timeout(
      timeout,
      onTimeout: () => throw TimeoutException('解析章节目录超时'),
    );
  }

  static Future<ExtractedChapterPage> parseChapterPage({
    required String body,
    required String pageUrl,
    required SourceContentRule rule,
    required SourceContentType contentType,
    Duration timeout = defaultIsolateTimeout,
  }) async {
    if (body.trim().isEmpty || rule.isEmpty) {
      throw const FormatException('正文响应为空或缺少正文提取规则');
    }
    if (body.length < 24 * 1024) {
      return parseChapterPageDirect(
        body: body,
        pageUrl: pageUrl,
        rule: rule,
        contentType: contentType,
      );
    }
    return NetworkUrlSafety.runInIsolate(
      () => parseChapterPageDirect(
        body: body,
        pageUrl: pageUrl,
        rule: rule,
        contentType: contentType,
      ),
    ).timeout(
      timeout,
      onTimeout: () => throw TimeoutException('解析章节正文超时'),
    );
  }

  static List<ExtractedBookItem> parseBookListDirect({
    required String body,
    required String baseUrl,
    required SourceListRule rule,
  }) {
    final root = RuleContext.fromBody(body, baseUrl: baseUrl);
    final items = evalContexts(root, rule.bookList);
    final results = <ExtractedBookItem>[];
    final seenUrls = <String>{};

    for (final ctx in items) {
      final title = _cleanSingleLine(evalString(ctx, rule.name));
      if (title.isEmpty) continue;
      final rawUrl = rule.bookUrl.isEmpty
          ? (ctx.element?.attributes['href'] ??
                ctx.element?.querySelector('a')?.attributes['href'] ??
                '')
          : evalString(ctx, rule.bookUrl).trim();
      final resolvedBookUrl = _resolveHttpUrl(
        baseUrl,
        rawUrl.isNotEmpty ? rawUrl : baseUrl,
      );
      if (resolvedBookUrl == null || !seenUrls.add(resolvedBookUrl)) continue;

      final author = _cleanSingleLine(
        evalString(ctx, rule.author),
      ).replaceFirst(RegExp(r'^(?:作者|著|作\s*者)[:：\s]*'), '');
      final kindParts = evalStringList(ctx, rule.kind)
          .map(_cleanSingleLine)
          .where((s) => s.isNotEmpty)
          .toList();
      final genre = kindParts.join(' · ');
      final latest = _cleanSingleLine(evalString(ctx, rule.lastChapter));
      final wordCount = _cleanSingleLine(evalString(ctx, rule.wordCount));
      final intro = _cleanMultilineSummary(evalString(ctx, rule.intro));
      final rawCover = evalString(ctx, rule.coverUrl, preferImageSrc: true);
      final coverUrl = _resolveImageSpecUrl(baseUrl, rawCover);

      results.add(
        ExtractedBookItem(
          title: title,
          bookUrl: resolvedBookUrl,
          author: author,
          genre: genre,
          summary: intro,
          coverUrl: coverUrl,
          latestChapter: latest,
          wordCount: wordCount,
        ),
      );
    }
    return results;
  }

  static ExtractedBookDetail parseBookDetailDirect({
    required String body,
    required String pageUrl,
    required SourceBookInfoRule rule,
  }) {
    var ctx = RuleContext.fromBody(body, baseUrl: pageUrl);
    if (rule.init.trim().isNotEmpty) {
      final sub = evalContexts(ctx, rule.init);
      if (sub.isNotEmpty) ctx = sub.first;
    }

    String? nonEmpty(String s) {
      final cleaned = s.trim();
      return cleaned.isEmpty ? null : cleaned;
    }

    final title = nonEmpty(_cleanSingleLine(evalString(ctx, rule.name)));
    final rawAuthor = _cleanSingleLine(evalString(ctx, rule.author))
        .replaceFirst(RegExp(r'^(?:作者|著|作\s*者)[:：\s]*'), '');
    final author = nonEmpty(rawAuthor);
    final kindParts = evalStringList(ctx, rule.kind)
        .map(_cleanSingleLine)
        .where((s) => s.isNotEmpty)
        .toList();
    final genre = nonEmpty(kindParts.join(' · '));
    final intro = nonEmpty(_cleanMultilineSummary(evalString(ctx, rule.intro)));
    final latest = nonEmpty(_cleanSingleLine(evalString(ctx, rule.lastChapter)));
    final rawCover = evalString(ctx, rule.coverUrl, preferImageSrc: true);
    final coverUrl = _resolveImageSpecUrl(pageUrl, rawCover);
    final rawToc = evalString(ctx, rule.tocUrl).trim();
    final tocUrl = rawToc.isEmpty ? null : _resolveHttpUrl(pageUrl, rawToc);

    return ExtractedBookDetail(
      title: title,
      author: author,
      genre: genre,
      summary: intro,
      coverUrl: coverUrl,
      latestChapter: latest,
      tocUrl: tocUrl,
    );
  }

  static ExtractedTocPage parseTocPageDirect({
    required String body,
    required String pageUrl,
    required SourceTocRule rule,
  }) {
    final root = RuleContext.fromBody(body, baseUrl: pageUrl);
    final nodes = evalContexts(root, rule.chapterList);
    final chapters = <RawExtractedChapter>[];

    for (final node in nodes) {
      final title = _cleanSingleLine(evalString(node, rule.chapterName));
      if (title.isEmpty) continue;
      final isVolRaw = rule.isVolume.isEmpty
          ? ''
          : evalString(node, rule.isVolume).trim().toLowerCase();
      final isVolumeFlag =
          isVolRaw == 'true' || isVolRaw == '1' || isVolRaw == title.toLowerCase();
      final rawUrl = rule.chapterUrl.isEmpty
          ? (node.element?.attributes['href'] ??
                node.element?.querySelector('a')?.attributes['href'] ??
                '')
          : evalString(node, rule.chapterUrl).trim();
      if (isVolumeFlag || rawUrl.isEmpty || rawUrl.startsWith('javascript:')) {
        if (isVolumeFlag) {
          chapters.add(RawExtractedChapter(title: title, url: '', isVolume: true));
        }
        continue;
      }
      final resolvedUrl = _resolveHttpUrl(pageUrl, rawUrl);
      if (resolvedUrl == null) continue;
      chapters.add(RawExtractedChapter(title: title, url: resolvedUrl));
    }

    String? nextUrl;
    if (rule.nextTocUrl.trim().isNotEmpty) {
      final candidates = evalStringList(root, rule.nextTocUrl);
      for (final c in candidates) {
        final resolved = _resolveHttpUrl(pageUrl, c);
        if (resolved != null && resolved != pageUrl) {
          nextUrl = resolved;
          break;
        }
      }
    }

    return ExtractedTocPage(chapters: chapters, nextTocUrl: nextUrl);
  }

  static ExtractedChapterPage parseChapterPageDirect({
    required String body,
    required String pageUrl,
    required SourceContentRule rule,
    required SourceContentType contentType,
  }) {
    final root = RuleContext.fromBody(body, baseUrl: pageUrl);

    String? nextUrl;
    if (rule.nextContentUrl.trim().isNotEmpty) {
      for (final candidate in evalStringList(root, rule.nextContentUrl)) {
        final resolved = _resolveHttpUrl(pageUrl, candidate);
        if (resolved != null && resolved != pageUrl) {
          nextUrl = resolved;
          break;
        }
      }
    }

    if (contentType == SourceContentType.manga) {
      final imageLines = _extractMangaImageParagraphs(root, rule, pageUrl);
      return ExtractedChapterPage(
        body: imageLines.join('\n\n'),
        nextContentUrl: nextUrl,
      );
    }

    final textBody = _extractNovelBody(root, rule, pageUrl);
    return ExtractedChapterPage(body: textBody, nextContentUrl: nextUrl);
  }

  static List<String> _extractMangaImageParagraphs(
    RuleContext root,
    SourceContentRule rule,
    String pageUrl,
  ) {
    final rawUrls = <String>[];
    final ruleStr = rule.content.trim();

    // First try evaluating as sub-contexts to inspect `<img>` elements directly
    // (automatically picking lazy-load attributes `data-original`, `data-src`, etc.).
    final hasExplicitTerminal = RegExp(
      r'@(?:src|data-[a-z0-9_-]+|href|text|html|json)\b|^@json:|^\$\.|^//',
      caseSensitive: false,
    ).hasMatch(ruleStr);

    if (!hasExplicitTerminal && root.element != null) {
      final subContexts = evalContexts(root, ruleStr);
      for (final sub in subContexts) {
        final el = sub.element;
        if (el == null) continue;
        if (el.localName == 'img') {
          final src = _bestImageAttribute(el);
          if (src != null) rawUrls.add(src);
        } else {
          for (final img in el.querySelectorAll('img')) {
            final src = _bestImageAttribute(img);
            if (src != null) rawUrls.add(src);
          }
        }
      }
    }

    if (rawUrls.isEmpty) {
      final strings = evalStringList(root, ruleStr, preferImageSrc: true);
      for (final item in strings) {
        // An extracted HTML snippet may contain `<img src="...">` tags.
        if (item.contains('<img')) {
          final frag = html_parser.parseFragment(item);
          for (final img in frag.querySelectorAll('img')) {
            final src = _bestImageAttribute(img);
            if (src != null) rawUrls.add(src);
          }
        } else {
          for (final line in item.split(RegExp(r'[\r\n]+'))) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty) rawUrls.add(trimmed);
          }
        }
      }
    }

    final encoded = <String>[];
    String? prevUrl;
    for (var raw in rawUrls) {
      if (rule.replaceRegex.trim().isNotEmpty) {
        raw = _applyReplaceRegexBlock(raw, rule.replaceRegex);
      }
      final resolved = _resolveImageSpecUrl(
        pageUrl,
        raw,
        defaultReferer: pageUrl,
      );
      if (resolved == null || resolved == prevUrl) continue;
      prevUrl = resolved;
      final spec = tryParseSourceImageSpec(resolved);
      if (spec != null) {
        encoded.add(
          encodeSourceImageParagraph(spec.url, headers: spec.headers),
        );
      }
    }
    return encoded;
  }

  static String _extractNovelBody(
    RuleContext root,
    SourceContentRule rule,
    String pageUrl,
  ) {
    final ruleStr = rule.content.trim();
    final paragraphs = <String>[];

    final looksJsonOrRegex =
        root.isJson ||
        ruleStr.startsWith('@json:') ||
        ruleStr.startsWith(r'$.') ||
        ruleStr.startsWith(r'$[') ||
        ruleStr.startsWith(':');

    // If HTML rule doesn't end with an explicit `@text`, extract via DOM walker
    // so `<p>`, `<br>`, and inline `<img>` illustrations are all preserved!
    final explicitTextTerminal = RegExp(
      r'@(?:text|textNodes|ownText|html|all)(?:##|$)',
      caseSensitive: false,
    ).hasMatch(ruleStr);

    if (!looksJsonOrRegex && !explicitTextTerminal && root.element != null) {
      final parts = _splitRegexSuffix(ruleStr);
      final contexts = evalContexts(root, parts.selector);
      for (final ctx in contexts) {
        if (ctx.element != null) {
          paragraphs.addAll(_domElementToParagraphs(ctx.element!, pageUrl));
        } else if (ctx.value != null) {
          paragraphs.addAll(_plainTextToParagraphs('${ctx.value}'));
        }
      }
      var joined = paragraphs.join('\n\n');
      if (parts.regexPattern != null) {
        joined = _applySingleRegex(
          joined,
          parts.regexPattern!,
          parts.replacement ?? '',
          firstOnly: parts.extractFirstOnly,
        );
      }
      if (rule.replaceRegex.trim().isNotEmpty) {
        joined = _applyReplaceRegexBlock(joined, rule.replaceRegex);
      }
      return _normalizeFinalNovelBody(joined);
    }

    final rawStrings = evalStringList(root, ruleStr);
    for (final chunk in rawStrings) {
      if (chunk.contains('<') &&
          RegExp(r'<(?:p|br|div|img|span)\b', caseSensitive: false)
              .hasMatch(chunk)) {
        final frag = html_parser.parseFragment(chunk);
        final wrapper = dom.Element.tag('div')..nodes.addAll(frag.nodes.toList());
        paragraphs.addAll(_domElementToParagraphs(wrapper, pageUrl));
      } else {
        paragraphs.addAll(_plainTextToParagraphs(chunk));
      }
    }

    var joined = paragraphs.join('\n\n');
    if (rule.replaceRegex.trim().isNotEmpty) {
      joined = _applyReplaceRegexBlock(joined, rule.replaceRegex);
    }
    return _normalizeFinalNovelBody(joined);
  }

  static List<String> _domElementToParagraphs(
    dom.Element root,
    String pageUrl,
  ) {
    final result = <String>[];
    final currentLine = StringBuffer();

    void flushLine() {
      final raw = currentLine.toString();
      currentLine.clear();
      final cleaned = raw
          .replaceAll('\u00a0', ' ')
          .replaceAll(RegExp(r'[ \t\f\v]+'), ' ')
          .replaceFirst(RegExp(r'^[\s\u3000]+'), '')
          .trimRight();
      if (cleaned.isNotEmpty) {
        result.add(cleaned);
      }
    }

    const ignoredTags = {
      'script',
      'style',
      'noscript',
      'iframe',
      'svg',
      'canvas',
      'button',
      'form',
      'input',
      'select',
    };

    const blockTags = {
      'p',
      'div',
      'section',
      'article',
      'li',
      'tr',
      'blockquote',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'dd',
      'dt',
    };

    void walk(dom.Node node) {
      if (node is dom.Text) {
        final text = node.data.replaceAll(RegExp(r'\r?\n'), ' ');
        currentLine.write(text);
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName?.toLowerCase() ?? '';
      if (ignoredTags.contains(tag)) return;
      final style = (node.attributes['style'] ?? '').toLowerCase();
      if (style.contains('display:none') || style.contains('display: none')) {
        return;
      }
      if (tag == 'br') {
        flushLine();
        return;
      }
      if (tag == 'img') {
        flushLine();
        final src = _bestImageAttribute(node);
        final resolved = src == null ? null : _resolveImageSpecUrl(pageUrl, src);
        if (resolved != null) {
          final spec = tryParseSourceImageSpec(resolved);
          if (spec != null) {
            result.add(
              encodeSourceImageParagraph(spec.url, headers: spec.headers),
            );
          }
        }
        return;
      }
      final isBlock = blockTags.contains(tag);
      if (isBlock) flushLine();
      for (final child in node.nodes) {
        walk(child);
      }
      if (isBlock) flushLine();
    }

    walk(root);
    flushLine();
    return result;
  }

  static List<String> _plainTextToParagraphs(String raw) {
    final out = <String>[];
    for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
      final trimmed = line
          .replaceFirst(RegExp(r'^[\s\u3000]+'), '')
          .trimRight();
      if (trimmed.isNotEmpty) out.add(trimmed);
    }
    return out;
  }

  static String _normalizeFinalNovelBody(String raw) {
    final paragraphs = <String>[];
    for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
      final trimmed = line
          .replaceFirst(RegExp(r'^[\s\u3000]+'), '')
          .trimRight();
      if (trimmed.isEmpty) continue;
      paragraphs.add(trimmed);
    }
    return paragraphs.join('\n\n');
  }

  static String? _bestImageAttribute(dom.Element img) {
    for (final attr in const [
      'data-original',
      'data-src',
      'data-lazy-src',
      'data-echo',
      'data-url',
      'data-ks-lazyload',
      'data-actualsrc',
      'src',
    ]) {
      final val = img.attributes[attr]?.trim();
      if (val != null &&
          val.isNotEmpty &&
          !val.startsWith('data:') &&
          !val.startsWith('javascript:')) {
        return val;
      }
    }
    return null;
  }

  static String? _resolveHttpUrl(String baseUrl, String rawTarget) {
    final trimmed = rawTarget.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('javascript:') ||
        trimmed.startsWith('data:') ||
        trimmed.startsWith('mailto:')) {
      return null;
    }
    try {
      final base = Uri.parse(baseUrl);
      final resolved = base.resolve(trimmed);
      return NetworkUrlSafety.parsePublicHttpUrl(
        resolved.toString(),
        allowHttp: true,
      ).toString();
    } catch (_) {
      return null;
    }
  }

  static String? _resolveImageSpecUrl(
    String baseUrl,
    String rawTarget, {
    String? defaultReferer,
  }) {
    final trimmed = rawTarget.trim();
    if (trimmed.isEmpty || trimmed.startsWith('data:')) return null;

    var urlPart = trimmed;
    String? optionsSuffix;
    final split = RegExp(r',\s*\{').firstMatch(trimmed);
    if (split != null) {
      urlPart = trimmed.substring(0, split.start).trim();
      optionsSuffix = trimmed.substring(split.start);
    }
    final resolvedUrl = _resolveHttpUrl(baseUrl, urlPart);
    if (resolvedUrl == null) return null;
    if (optionsSuffix != null) {
      final spec = tryParseSourceImageSpec('$resolvedUrl$optionsSuffix');
      return spec?.toRawSpec() ?? resolvedUrl;
    }
    if (defaultReferer != null && defaultReferer.isNotEmpty) {
      return SourceImageSpec(
        url: resolvedUrl,
        headers: {'Referer': defaultReferer},
      ).toRawSpec();
    }
    return resolvedUrl;
  }

  /// Evaluates [rule] against [ctx] and returns sub-contexts (elements or JSON values).
  static List<RuleContext> evalContexts(RuleContext ctx, String rawRule) {
    final rule = rawRule.trim();
    if (rule.isEmpty) return const [];

    final orParts = _splitTopLevelCombinator(rule, '||');
    if (orParts.length > 1) {
      for (final part in orParts) {
        final res = evalContexts(ctx, part);
        if (res.isNotEmpty) return res;
      }
      return const [];
    }

    final zipParts = _splitTopLevelCombinator(rule, '%%');
    if (zipParts.length > 1) {
      final lists = [for (final part in zipParts) evalContexts(ctx, part)];
      return _interleaveLists(lists);
    }

    final andParts = _splitTopLevelCombinator(rule, '&&');
    if (andParts.length > 1) {
      return [
        for (final part in andParts) ...evalContexts(ctx, part),
      ];
    }

    final stripped = _splitRegexSuffix(rule).selector.trim();
    if (stripped.startsWith(':')) {
      final pattern = stripped.substring(1);
      if (detectUnsafeRegexPattern(pattern) != null) return const [];
      try {
        final reg = _compileSafeRegex(pattern);
        if (reg == null) return const [];
        return [
          for (final m in reg.allMatches(ctx.rawText))
            RuleContext.fromRegexMatch(m, baseUrl: ctx.baseUrl),
        ];
      } catch (_) {
        return const [];
      }
    }

    if (stripped.startsWith('@json:') ||
        stripped.startsWith(r'$.') ||
        stripped.startsWith(r'$[') ||
        (ctx.isJson && !stripped.startsWith('@css:') && !stripped.startsWith('//'))) {
      final path = stripped.startsWith('@json:')
          ? stripped.substring(6).trim()
          : stripped;
      final values = _evalJsonPath(ctx.jsonValue, path);
      return [
        for (final v in values) RuleContext.fromJson(v, baseUrl: ctx.baseUrl),
      ];
    }

    if (stripped.startsWith('@XPath:') ||
        stripped.startsWith('@xpath:') ||
        stripped.startsWith('//') ||
        stripped.startsWith('./')) {
      final xp = stripped.replaceFirst(
        RegExp(r'^@xpath:', caseSensitive: false),
        '',
      ).trim();
      final el = ctx.element;
      if (el == null) return const [];
      final matched = _evalXPathElements(el, xp);
      return [
        for (final e in matched)
          RuleContext.fromElement(e, baseUrl: ctx.baseUrl),
      ];
    }

    final el = ctx.element;
    if (el == null) return const [];

    if (stripped.startsWith('@css:')) {
      final css = stripped.substring(5).trim();
      return [
        for (final e in _safeQueryAll(el, css))
          RuleContext.fromElement(e, baseUrl: ctx.baseUrl),
      ];
    }

    final matched = _evalJsoupChainElements(el, stripped);
    return [
      for (final e in matched)
        RuleContext.fromElement(e, baseUrl: ctx.baseUrl),
    ];
  }

  /// Evaluates [rawRule] against [ctx] and returns the joined string result.
  static String evalString(
    RuleContext ctx,
    String rawRule, {
    bool preferImageSrc = false,
  }) {
    final list = evalStringList(ctx, rawRule, preferImageSrc: preferImageSrc);
    if (list.isEmpty) return '';
    return list.join('\n').trim();
  }

  /// Evaluates [rawRule] against [ctx] and returns a list of extracted strings.
  static List<String> evalStringList(
    RuleContext ctx,
    String rawRule, {
    bool preferImageSrc = false,
  }) {
    final rule = rawRule.trim();
    if (rule.isEmpty) return const [];

    // Handle `||`, `%%`, `&&` combinators first.
    final orParts = _splitTopLevelCombinator(rule, '||');
    if (orParts.length > 1) {
      for (final part in orParts) {
        final res = evalStringList(
          ctx,
          part,
          preferImageSrc: preferImageSrc,
        );
        if (res.any((s) => s.trim().isNotEmpty)) return res;
      }
      return const [];
    }

    final zipParts = _splitTopLevelCombinator(rule, '%%');
    if (zipParts.length > 1) {
      final lists = [
        for (final part in zipParts)
          evalStringList(ctx, part, preferImageSrc: preferImageSrc),
      ];
      return _interleaveLists(lists);
    }

    final andParts = _splitTopLevelCombinator(rule, '&&');
    if (andParts.length > 1) {
      return [
        for (final part in andParts)
          ...evalStringList(ctx, part, preferImageSrc: preferImageSrc),
      ];
    }

    final regexSplit = _splitRegexSuffix(rule);
    final selector = regexSplit.selector.trim();

    List<String> rawValues;

    // Regex capture group reference (`$1`, `$2`) on a `:regex` match context!
    if (ctx.regexMatch != null && RegExp(r'^\$\d+$').hasMatch(selector)) {
      final groupIdx = int.parse(selector.substring(1));
      final m = ctx.regexMatch!;
      final val = groupIdx <= m.groupCount ? (m.group(groupIdx) ?? '') : '';
      rawValues = val.isEmpty ? const [] : [val];
    } else if (selector.contains('{{') && selector.contains('}}')) {
      // String template containing embedded expressions like `/book/{{$.id}}.html`
      final interpolated = selector.replaceAllMapped(
        RegExp(r'\{\{([^{}]+)\}\}'),
        (m) => evalString(ctx, m.group(1)!.trim()),
      );
      rawValues = interpolated.trim().isEmpty ? const [] : [interpolated];
    } else if (selector.startsWith(':')) {
      final pattern = selector.substring(1);
      final reg = _compileSafeRegex(pattern);
      if (reg == null) {
        rawValues = const [];
      } else {
        rawValues = [
          for (final m in reg.allMatches(ctx.rawText))
            (m.groupCount >= 1 ? m.group(1) : m.group(0)) ?? '',
        ];
      }
    } else if (selector.isEmpty) {
      final single = ctx.asScalarString(preferImageSrc: preferImageSrc);
      rawValues = single.isEmpty ? const [] : [single];
    } else if (selector.startsWith('@json:') ||
        selector.startsWith(r'$.') ||
        selector.startsWith(r'$[') ||
        (ctx.isJson &&
            !selector.startsWith('@css:') &&
            !selector.startsWith('//'))) {
      final path = selector.startsWith('@json:')
          ? selector.substring(6).trim()
          : selector;
      final vals = _evalJsonPath(ctx.jsonValue, path);
      rawValues = [
        for (final v in vals)
          if (v != null && '$v'.trim().isNotEmpty) '$v'.trim(),
      ];
    } else if (selector.startsWith('@XPath:') ||
        selector.startsWith('@xpath:') ||
        selector.startsWith('//') ||
        selector.startsWith('./')) {
      final xp = selector
          .replaceFirst(RegExp(r'^@xpath:', caseSensitive: false), '')
          .trim();
      rawValues = ctx.element == null
          ? const []
          : _evalXPathStrings(
              ctx.element!,
              xp,
              preferImageSrc: preferImageSrc,
            );
    } else if (selector.startsWith('@css:')) {
      final cssBody = selector.substring(5).trim();
      rawValues = ctx.element == null
          ? const []
          : _evalCssWithAttr(
              ctx.element!,
              cssBody,
              preferImageSrc: preferImageSrc,
            );
    } else if (ctx.element != null) {
      rawValues = _evalJsoupChainStrings(
        ctx.element!,
        selector,
        preferImageSrc: preferImageSrc,
      );
    } else {
      rawValues = const [];
    }

    if (regexSplit.regexPattern == null) {
      return rawValues;
    }

    final transformed = <String>[];
    for (final item in rawValues) {
      final next = _applySingleRegex(
        item,
        regexSplit.regexPattern!,
        regexSplit.replacement ?? '',
        firstOnly: regexSplit.extractFirstOnly,
      );
      if (next.isNotEmpty) transformed.add(next);
    }
    return transformed;
  }

  static List<T> _interleaveLists<T>(List<List<T>> lists) {
    var maxLen = 0;
    for (final l in lists) {
      if (l.length > maxLen) maxLen = l.length;
    }
    final out = <T>[];
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    return out;
  }

  static List<String> _splitTopLevelCombinator(String input, String op) {
    if (!input.contains(op)) return [input];
    final parts = <String>[];
    var bracketDepth = 0;
    var parenDepth = 0;
    var braceDepth = 0;
    String? quote;
    var start = 0;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (quote != null) {
        if (ch == r'\' && i + 1 < input.length) {
          i++;
          continue;
        }
        if (ch == quote) quote = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      // Stop splitting combinators once inside a trailing `##regex` section!
      if (bracketDepth == 0 &&
          parenDepth == 0 &&
          braceDepth == 0 &&
          i + 1 < input.length &&
          input.startsWith('##', i)) {
        break;
      }
      if (ch == '[') {
        bracketDepth++;
      } else if (ch == ']' && bracketDepth > 0) {
        bracketDepth--;
      } else if (ch == '(') {
        parenDepth++;
      } else if (ch == ')' && parenDepth > 0) {
        parenDepth--;
      } else if (ch == '{') {
        braceDepth++;
      } else if (ch == '}' && braceDepth > 0) {
        braceDepth--;
      } else if (bracketDepth == 0 &&
          parenDepth == 0 &&
          braceDepth == 0 &&
          input.startsWith(op, i)) {
        parts.add(input.substring(start, i));
        i += op.length - 1;
        start = i + 1;
      }
    }
    if (parts.isEmpty) return [input];
    parts.add(input.substring(start));
    return parts;
  }

  static ({
    String selector,
    String? regexPattern,
    String? replacement,
    bool extractFirstOnly,
  })
  _splitRegexSuffix(String rule) {
    final idx = rule.indexOf('##');
    if (idx < 0) {
      return (
        selector: rule,
        regexPattern: null,
        replacement: null,
        extractFirstOnly: false,
      );
    }
    final selector = rule.substring(0, idx);
    var rest = rule.substring(idx + 2);
    var extractFirst = false;
    if (rest.endsWith('###')) {
      extractFirst = true;
      rest = rest.substring(0, rest.length - 3);
    }
    final secondIdx = rest.indexOf('##');
    if (secondIdx < 0) {
      return (
        selector: selector,
        regexPattern: rest,
        replacement: '',
        extractFirstOnly: extractFirst,
      );
    }
    return (
      selector: selector,
      regexPattern: rest.substring(0, secondIdx),
      replacement: rest.substring(secondIdx + 2),
      extractFirstOnly: extractFirst,
    );
  }

  static RegExp? _compileSafeRegex(String pattern) {
    if (pattern.isEmpty || detectUnsafeRegexPattern(pattern) != null) {
      return null;
    }
    try {
      var src = pattern;
      var caseSensitive = true;
      var dotAll = false;
      final flagMatch = RegExp(r'^\(\?([ims]+)\)').firstMatch(src);
      if (flagMatch != null) {
        final flags = flagMatch.group(1)!;
        caseSensitive = !flags.contains('i');
        dotAll = flags.contains('s');
        src = src.substring(flagMatch.end);
      }
      return RegExp(
        src,
        multiLine: true,
        caseSensitive: caseSensitive,
        dotAll: dotAll,
      );
    } on FormatException {
      return null;
    }
  }

  static String _expandCaptureGroups(Match match, String replacement) {
    if (!replacement.contains(r'$') && !replacement.contains(r'\')) {
      return replacement;
    }
    final out = StringBuffer();
    for (var i = 0; i < replacement.length; i++) {
      final ch = replacement[i];
      if (ch == r'\' && i + 1 < replacement.length) {
        final next = replacement[++i];
        out.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => next,
        });
      } else if (ch == r'$' &&
          i + 1 < replacement.length &&
          RegExp(r'\d').hasMatch(replacement[i + 1])) {
        final g = int.parse(replacement[++i]);
        out.write(g <= match.groupCount ? (match.group(g) ?? '') : '');
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  static String _applySingleRegex(
    String input,
    String pattern,
    String replacement, {
    bool firstOnly = false,
  }) {
    if (pattern.isEmpty || input.isEmpty) return input;
    final reg = _compileSafeRegex(pattern);
    if (reg == null) return input;
    if (firstOnly) {
      final m = reg.firstMatch(input);
      if (m == null) return '';
      if (replacement.isEmpty && m.groupCount >= 1) {
        return m.group(1) ?? m.group(0) ?? '';
      }
      return _expandCaptureGroups(m, replacement);
    }
    final buf = StringBuffer();
    var cursor = 0;
    for (final m in reg.allMatches(input)) {
      buf
        ..write(input.substring(cursor, m.start))
        ..write(_expandCaptureGroups(m, replacement));
      cursor = m.end;
    }
    if (cursor == 0) return input;
    buf.write(input.substring(cursor));
    return buf.toString();
  }

  static String _applyReplaceRegexBlock(String input, String block) {
    var current = input;
    for (final rawLine in block.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('##')) {
        final spec = _splitRegexSuffix(line);
        if (spec.regexPattern != null) {
          current = _applySingleRegex(
            current,
            spec.regexPattern!,
            spec.replacement ?? '',
            firstOnly: spec.extractFirstOnly,
          );
        }
      } else if (line.contains('##')) {
        final idx = line.indexOf('##');
        final pat = line.substring(0, idx);
        final rep = line.substring(idx + 2);
        current = _applySingleRegex(current, pat, rep);
      } else {
        current = _applySingleRegex(current, line, '');
      }
    }
    return current;
  }

  // -------------------- CSS & Legado Jsoup Chain --------------------

  static List<String> _splitAtChain(String rule) {
    final parts = <String>[];
    var bracketDepth = 0;
    var parenDepth = 0;
    String? quote;
    var start = 0;
    for (var i = 0; i < rule.length; i++) {
      final ch = rule[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '[') {
        bracketDepth++;
      } else if (ch == ']' && bracketDepth > 0) {
        bracketDepth--;
      } else if (ch == '(') {
        parenDepth++;
      } else if (ch == ')' && parenDepth > 0) {
        parenDepth--;
      } else if (ch == '@' && bracketDepth == 0 && parenDepth == 0) {
        parts.add(rule.substring(start, i).trim());
        start = i + 1;
      }
    }
    parts.add(rule.substring(start).trim());
    return parts.where((p) => p.isNotEmpty).toList();
  }

  static const Set<String> _knownTerminalExtractors = {
    'text',
    'textnodes',
    'owntext',
    'html',
    'all',
    'href',
    'src',
    'content',
    'title',
    'alt',
    'value',
    'style',
    'data-src',
    'data-original',
    'data-lazy-src',
    'data-echo',
    'data-url',
    'data-id',
    'data-bid',
    'abs:href',
    'abs:src',
  };

  static bool _isTerminalAttributeSegment(String seg) {
    final lower = seg.toLowerCase();
    if (_knownTerminalExtractors.contains(lower)) return true;
    if (lower.startsWith('data-') || lower.startsWith('abs:')) return true;
    return false;
  }

  static List<String> _evalCssWithAttr(
    dom.Element root,
    String cssRule, {
    bool preferImageSrc = false,
  }) {
    final chain = _splitAtChain(cssRule);
    if (chain.isEmpty) return const [];
    String? attr;
    String selector;
    if (chain.length >= 2 && _isTerminalAttributeSegment(chain.last)) {
      attr = chain.last;
      selector = chain.sublist(0, chain.length - 1).join('@');
    } else {
      selector = cssRule;
    }
    final elements = selector.isEmpty ? [root] : _safeQueryAll(root, selector);
    return [
      for (final el in elements)
        if (_extractFromElement(el, attr, preferImageSrc: preferImageSrc)
            case final String s when s.isNotEmpty)
          s,
    ];
  }

  static List<dom.Element> _evalJsoupChainElements(
    dom.Element root,
    String rule,
  ) {
    final chain = _splitAtChain(rule);
    if (chain.isEmpty) return [root];
    var current = <dom.Element>[root];
    for (final step in chain) {
      if (_isTerminalAttributeSegment(step)) break;
      final next = <dom.Element>[];
      for (final el in current) {
        next.addAll(_evalSingleJsoupStep(el, step));
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  static List<String> _evalJsoupChainStrings(
    dom.Element root,
    String rule, {
    bool preferImageSrc = false,
  }) {
    final chain = _splitAtChain(rule);
    if (chain.isEmpty) return const [];
    String? terminalAttr;
    List<String> elementSteps = chain;
    if (_isTerminalAttributeSegment(chain.last)) {
      terminalAttr = chain.last;
      elementSteps = chain.sublist(0, chain.length - 1);
    }

    var current = <dom.Element>[root];
    for (final step in elementSteps) {
      final next = <dom.Element>[];
      for (final el in current) {
        next.addAll(_evalSingleJsoupStep(el, step));
      }
      current = next;
      if (current.isEmpty) return const [];
    }

    return [
      for (final el in current)
        if (_extractFromElement(
          el,
          terminalAttr,
          preferImageSrc: preferImageSrc,
        ) case final String val when val.isNotEmpty)
          val,
    ];
  }

  static List<dom.Element> _evalSingleJsoupStep(
    dom.Element scope,
    String rawStep,
  ) {
    final step = rawStep.trim();
    if (step.isEmpty || step == '.' || step == 'this') return [scope];
    if (step == 'children') return scope.children.toList();

    // Parse optional trailing exclusion `!0:1:2` or bracket/dot index `.0`, `.-1`, `[0]`, `[!0:1]`.
    final (:core, :indexFilter) = _stripIndexFilter(step);
    List<dom.Element> matched;

    if (core.startsWith('class.')) {
      final classes = core
          .substring(6)
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .map((c) => '.$c')
          .join();
      matched = classes.isEmpty ? const [] : _safeQueryAll(scope, classes);
    } else if (core.startsWith('id.')) {
      final id = core.substring(3).trim();
      matched = id.isEmpty ? const [] : _safeQueryAll(scope, '#$id');
    } else if (core.startsWith('tag.')) {
      final tag = core.substring(4).trim();
      matched = tag.isEmpty ? const [] : _safeQueryAll(scope, tag);
    } else if (core.startsWith('text.')) {
      final needle = core.substring(5).trim();
      matched = [
        for (final el in scope.querySelectorAll('*'))
          if (el.text.contains(needle)) el,
      ];
    } else {
      matched = _safeQueryAll(scope, core);
    }

    return indexFilter == null ? matched : _applyIndexFilter(matched, indexFilter);
  }

  static ({String core, String? indexFilter}) _stripIndexFilter(String step) {
    // Exclude pattern e.g. `tag.dd!0:1:2` or `li!-1`
    final bangMatch = RegExp(r'!(-?\d+(?::-?\d+)*)$').firstMatch(step);
    if (bangMatch != null) {
      return (
        core: step.substring(0, bangMatch.start).trim(),
        indexFilter: '!${bangMatch.group(1)!}',
      );
    }
    // Bracket index pattern at end e.g. `a[0]`, `dd[1:5]`, `dd[!0:1]`
    // (Distinct from CSS attribute `[href]` because inside is pure digits / `!` / `:`).
    final bracketIdx = RegExp(
      r'\[(!?-?\d+(?::-?\d+)*)\]$',
    ).firstMatch(step);
    if (bracketIdx != null) {
      return (
        core: step.substring(0, bracketIdx.start).trim(),
        indexFilter: bracketIdx.group(1)!,
      );
    }
    // Dot index pattern in Legado Jsoup e.g. `tag.a.0`, `class.item.-1`, `a.0`
    final dotIdx = RegExp(r'\.(-?\d+)$').firstMatch(step);
    if (dotIdx != null) {
      return (
        core: step.substring(0, dotIdx.start).trim(),
        indexFilter: dotIdx.group(1)!,
      );
    }
    return (core: step, indexFilter: null);
  }

  static List<T> _applyIndexFilter<T>(List<T> items, String spec) {
    if (items.isEmpty) return items;
    final len = items.length;
    int resolveIdx(int raw) => raw < 0 ? len + raw : raw;

    if (spec.startsWith('!')) {
      final excluded = <int>{};
      for (final token in spec.substring(1).split(':')) {
        final parsed = int.tryParse(token);
        if (parsed != null) excluded.add(resolveIdx(parsed));
      }
      return [
        for (var i = 0; i < len; i++)
          if (!excluded.contains(i)) items[i],
      ];
    }

    if (spec.contains(':')) {
      final parts = spec.split(':');
      if (parts.length == 2) {
        final start = parts[0].isEmpty
            ? 0
            : resolveIdx(int.tryParse(parts[0]) ?? 0).clamp(0, len);
        final end = parts[1].isEmpty
            ? len
            : (resolveIdx(int.tryParse(parts[1]) ?? len) + 1).clamp(0, len);
        if (start >= end) return const [];
        return items.sublist(start, end);
      }
      final picked = <T>[];
      for (final token in parts) {
        final p = int.tryParse(token);
        if (p == null) continue;
        final idx = resolveIdx(p);
        if (idx >= 0 && idx < len) picked.add(items[idx]);
      }
      return picked;
    }

    final single = int.tryParse(spec);
    if (single == null) return items;
    final idx = resolveIdx(single);
    return (idx >= 0 && idx < len) ? [items[idx]] : const [];
  }

  static List<dom.Element> _safeQueryAll(dom.Element scope, String selector) {
    final trimmed = selector.trim();
    if (trimmed.isEmpty) return [scope];
    try {
      // Handle `> child` relative selectors cleanly via temporary wrapper or direct children.
      if (trimmed.startsWith('>')) {
        final rest = trimmed.substring(1).trim();
        if (rest.isEmpty) return scope.children.toList();
        return [
          for (final child in scope.children)
            if (_elementMatchesSimpleSelector(child, rest)) child,
        ];
      }
      final found = scope.querySelectorAll(trimmed);
      if (found.isNotEmpty) return found;
      if (_elementMatchesSimpleSelector(scope, trimmed)) return [scope];
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static bool _elementMatchesSimpleSelector(dom.Element el, String selector) {
    final s = selector.trim();
    if (s == '*') return true;
    if (s.startsWith('.')) {
      return el.classes.contains(s.substring(1));
    }
    if (s.startsWith('#')) {
      return el.id == s.substring(1);
    }
    return el.localName?.toLowerCase() == s.toLowerCase();
  }

  static String _extractFromElement(
    dom.Element el,
    String? rawAttr, {
    bool preferImageSrc = false,
  }) {
    final attr = rawAttr?.toLowerCase().replaceFirst(RegExp(r'^abs:'), '');
    if (attr == null || attr == 'text') {
      if (preferImageSrc && el.localName == 'img') {
        return _bestImageAttribute(el) ?? '';
      }
      return el.text.trim();
    }
    if (attr == 'owntext') {
      return el.nodes
          .whereType<dom.Text>()
          .map((t) => t.data.trim())
          .where((s) => s.isNotEmpty)
          .join('\n');
    }
    if (attr == 'textnodes') {
      final lines = <String>[];
      void collect(dom.Node node) {
        if (node is dom.Text) {
          final t = node.data.trim();
          if (t.isNotEmpty) lines.add(t);
        } else if (node is dom.Element &&
            node.localName != 'script' &&
            node.localName != 'style') {
          for (final c in node.nodes) {
            collect(c);
          }
        }
      }
      collect(el);
      return lines.join('\n');
    }
    if (attr == 'html' || attr == 'all') {
      return attr == 'all' ? el.outerHtml : el.innerHtml;
    }
    if (attr == 'src' && (preferImageSrc || el.localName == 'img')) {
      return _bestImageAttribute(el) ?? el.attributes['src']?.trim() ?? '';
    }
    return el.attributes[attr]?.trim() ?? '';
  }

  // -------------------- XPath Subset Evaluator --------------------

  static List<dom.Element> _evalXPathElements(dom.Element root, String xpath) {
    final (:elementPath, terminal: _) = _splitXPathTerminal(xpath);
    final steps = _tokenizeXPathSteps(elementPath);
    var current = <dom.Element>[root];
    for (final step in steps) {
      current = _stepXPath(current, step);
      if (current.isEmpty) break;
    }
    return current;
  }

  static List<String> _evalXPathStrings(
    dom.Element root,
    String xpath, {
    bool preferImageSrc = false,
  }) {
    final (:elementPath, :terminal) = _splitXPathTerminal(xpath);
    final elements = elementPath.isEmpty
        ? [root]
        : _evalXPathElements(root, elementPath);
    final out = <String>[];
    for (final el in elements) {
      final val = switch (terminal) {
        null || 'text()' => _extractFromElement(
          el,
          'text',
          preferImageSrc: preferImageSrc,
        ),
        'node()' => el.innerHtml,
        final String a when a.startsWith('@') => _extractFromElement(
          el,
          a.substring(1),
          preferImageSrc: preferImageSrc,
        ),
        _ => el.text.trim(),
      };
      if (val.isNotEmpty) out.add(val);
    }
    return out;
  }

  static ({String elementPath, String? terminal}) _splitXPathTerminal(
    String xpath,
  ) {
    final trimmed = xpath.trim();
    for (final suffix in const ['/text()', '/node()']) {
      if (trimmed.endsWith(suffix)) {
        return (
          elementPath: trimmed.substring(0, trimmed.length - suffix.length),
          terminal: suffix.substring(1),
        );
      }
    }
    final attrMatch = RegExp(r'/(@[a-zA-Z0-9_:-]+)$').firstMatch(trimmed);
    if (attrMatch != null) {
      return (
        elementPath: trimmed.substring(0, attrMatch.start),
        terminal: attrMatch.group(1)!,
      );
    }
    return (elementPath: trimmed, terminal: null);
  }

  static List<({bool descendant, String tag, List<String> predicates})>
  _tokenizeXPathSteps(String path) {
    var p = path.trim();
    if (p.startsWith('./')) p = p.substring(1);
    final result = <({bool descendant, String tag, List<String> predicates})>[];
    var i = 0;
    while (i < p.length) {
      var descendant = false;
      if (p.startsWith('//', i)) {
        descendant = true;
        i += 2;
      } else if (p[i] == '/') {
        i += 1;
      }
      if (i >= p.length) break;

      final tagStart = i;
      while (i < p.length && p[i] != '/' && p[i] != '[') {
        i++;
      }
      final tag = p.substring(tagStart, i).trim();
      final preds = <String>[];
      while (i < p.length && p[i] == '[') {
        var depth = 0;
        String? quote;
        final predStart = i + 1;
        for (; i < p.length; i++) {
          final ch = p[i];
          if (quote != null) {
            if (ch == quote) quote = null;
            continue;
          }
          if (ch == '"' || ch == "'") {
            quote = ch;
          } else if (ch == '[') {
            depth++;
          } else if (ch == ']') {
            depth--;
            if (depth == 0) {
              preds.add(p.substring(predStart, i).trim());
              i++;
              break;
            }
          }
        }
      }
      if (tag.isNotEmpty) {
        result.add((descendant: descendant, tag: tag, predicates: preds));
      }
    }
    return result;
  }

  static List<dom.Element> _stepXPath(
    List<dom.Element> current,
    ({bool descendant, String tag, List<String> predicates}) step,
  ) {
    final out = <dom.Element>[];
    final seen = <dom.Element>{};
    for (final base in current) {
      Iterable<dom.Element> candidates;
      if (step.tag == '.') {
        candidates = [base];
      } else if (step.descendant) {
        candidates = base.querySelectorAll(step.tag == '*' ? '*' : step.tag);
      } else {
        candidates = base.children.where(
          (c) =>
              step.tag == '*' ||
              c.localName?.toLowerCase() == step.tag.toLowerCase(),
        );
      }
      var list = candidates.toList();
      for (final pred in step.predicates) {
        list = _filterXPathPredicate(list, pred);
      }
      for (final item in list) {
        if (seen.add(item)) out.add(item);
      }
    }
    return out;
  }

  static List<dom.Element> _filterXPathPredicate(
    List<dom.Element> items,
    String pred,
  ) {
    if (items.isEmpty || pred.isEmpty) return items;
    // 1-based positional index `[1]`, `[last()]`, `[position()>1]`
    final pos = int.tryParse(pred);
    if (pos != null) {
      return (pos >= 1 && pos <= items.length) ? [items[pos - 1]] : const [];
    }
    if (pred == 'last()') {
      return [items.last];
    }
    final posGt = RegExp(r'^position\(\)\s*>\s*(\d+)$').firstMatch(pred);
    if (posGt != null) {
      final n = int.parse(posGt.group(1)!);
      return n >= items.length ? const [] : items.sublist(n);
    }

    return [
      for (final el in items)
        if (_evalXPathCondition(el, pred)) el,
    ];
  }

  static bool _evalXPathCondition(dom.Element el, String cond) {
    final trimmed = cond.trim();
    if (trimmed.startsWith('not(') && trimmed.endsWith(')')) {
      return !_evalXPathCondition(
        el,
        trimmed.substring(4, trimmed.length - 1),
      );
    }
    final containsAttr = RegExp(
      r'''^contains\(\s*@([a-zA-Z0-9_:-]+)\s*,\s*['"]([^'"]*)['"]\s*\)$''',
    ).firstMatch(trimmed);
    if (containsAttr != null) {
      final attrVal = el.attributes[containsAttr.group(1)!] ?? '';
      return attrVal.contains(containsAttr.group(2)!);
    }
    final containsText = RegExp(
      r'''^contains\(\s*(?:text\(\)|\.)\s*,\s*['"]([^'"]*)['"]\s*\)$''',
    ).firstMatch(trimmed);
    if (containsText != null) {
      return el.text.contains(containsText.group(1)!);
    }
    final eqAttr = RegExp(
      r'''^@([a-zA-Z0-9_:-]+)\s*=\s*['"]([^'"]*)['"]$''',
    ).firstMatch(trimmed);
    if (eqAttr != null) {
      return (el.attributes[eqAttr.group(1)!] ?? '') == eqAttr.group(2)!;
    }
    if (trimmed.startsWith('@')) {
      return el.attributes.containsKey(trimmed.substring(1));
    }
    return true;
  }

  // -------------------- JSONPath Subset Evaluator --------------------

  static List<Object?> _evalJsonPath(Object? root, String rawPath) {
    if (root == null) return const [];
    var path = rawPath.trim();
    if (path.isEmpty || path == r'$') return [root];
    if (path.startsWith(r'$')) path = path.substring(1);

    var current = <Object?>[root];
    var i = 0;

    while (i < path.length && current.isNotEmpty) {
      // Recursive descent `..field`
      if (path.startsWith('..', i)) {
        i += 2;
        final start = i;
        while (i < path.length && path[i] != '.' && path[i] != '[') {
          i++;
        }
        final key = path.substring(start, i);
        if (key.isEmpty) break;
        final found = <Object?>[];
        void descend(Object? node) {
          if (node is Map) {
            if (node.containsKey(key)) found.add(node[key]);
            for (final v in node.values) {
              descend(v);
            }
          } else if (node is List) {
            for (final item in node) {
              descend(item);
            }
          }
        }
        for (final c in current) {
          descend(c);
        }
        current = found;
        continue;
      }

      if (path[i] == '.') {
        i++;
        if (i < path.length && path[i] == '*') {
          i++;
          final next = <Object?>[];
          for (final c in current) {
            if (c is Map) next.addAll(c.values);
            if (c is List) next.addAll(c);
          }
          current = next;
          continue;
        }
        final start = i;
        while (i < path.length && path[i] != '.' && path[i] != '[') {
          i++;
        }
        final key = path.substring(start, i);
        if (key.isEmpty) continue;
        final next = <Object?>[];
        for (final c in current) {
          if (c is Map && c.containsKey(key)) {
            next.add(c[key]);
          } else if (c is List) {
            for (final item in c) {
              if (item is Map && item.containsKey(key)) next.add(item[key]);
            }
          }
        }
        current = next;
        continue;
      }

      if (path[i] == '[') {
        final endBracket = path.indexOf(']', i + 1);
        if (endBracket < 0) break;
        final inside = path.substring(i + 1, endBracket).trim();
        i = endBracket + 1;
        if (inside == '*') {
          final next = <Object?>[];
          for (final c in current) {
            if (c is List) {
              next.addAll(c);
            } else if (c is Map) {
              next.addAll(c.values);
            }
          }
          current = next;
        } else if ((inside.startsWith("'") && inside.endsWith("'")) ||
            (inside.startsWith('"') && inside.endsWith('"'))) {
          final key = inside.substring(1, inside.length - 1);
          current = [
            for (final c in current)
              if (c is Map && c.containsKey(key)) c[key],
          ];
        } else {
          final next = <Object?>[];
          for (final c in current) {
            if (c is List) {
              next.addAll(_applyIndexFilter(c, inside));
            }
          }
          current = next;
        }
        continue;
      }

      // Bare leading property name (`data.books[*]`)
      final start = i;
      while (i < path.length && path[i] != '.' && path[i] != '[') {
        i++;
      }
      final key = path.substring(start, i);
      current = [
        for (final c in current)
          if (c is Map && c.containsKey(key)) c[key],
      ];
    }

    // Auto-flatten one level of List when leaf values are lists of scalars.
    final flattened = <Object?>[];
    for (final v in current) {
      if (v is List && v.every((e) => e is! Map && e is! List)) {
        flattened.addAll(v);
      } else {
        flattened.add(v);
      }
    }
    return flattened;
  }

  static String _cleanSingleLine(String input) => input
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _cleanMultilineSummary(String input) {
    final lines = <String>[];
    for (final line in input.replaceAll('\r\n', '\n').split('\n')) {
      final cleaned = line
          .replaceAll('\u00a0', ' ')
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .trim();
      if (cleaned.isNotEmpty) lines.add(cleaned);
    }
    return lines.join('\n');
  }
}

class RuleContext {
  const RuleContext._({
    required this.baseUrl,
    this.element,
    this.value,
    this.regexMatch,
    this.rawOverride,
  });

  final String baseUrl;
  final dom.Element? element;
  final Object? value;
  final Match? regexMatch;
  final String? rawOverride;

  bool get isJson => value != null && element == null;
  Object? get jsonValue => value;

  String get rawText =>
      rawOverride ??
      (element != null
          ? element!.outerHtml
          : value is String
          ? value as String
          : value != null
          ? jsonEncode(value)
          : '');

  String asScalarString({bool preferImageSrc = false}) {
    if (value != null) {
      if (value is String) return (value as String).trim();
      if (value is num || value is bool) return '$value';
      return jsonEncode(value);
    }
    if (element != null) {
      if (preferImageSrc && element!.localName == 'img') {
        return SourceRuleEngine._bestImageAttribute(element!) ?? '';
      }
      return element!.text.trim();
    }
    if (regexMatch != null) {
      return regexMatch!.group(0) ?? '';
    }
    return '';
  }

  factory RuleContext.fromBody(String body, {required String baseUrl}) {
    final trimmed = body.trim();
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        final decoded = jsonDecode(trimmed);
        return RuleContext._(
          baseUrl: baseUrl,
          value: decoded,
          rawOverride: body,
        );
      } catch (_) {}
    }
    final doc = html_parser.parse(body);
    return RuleContext._(
      baseUrl: baseUrl,
      element: doc.documentElement ?? dom.Element.tag('html'),
      rawOverride: body,
    );
  }

  factory RuleContext.fromElement(dom.Element el, {required String baseUrl}) =>
      RuleContext._(baseUrl: baseUrl, element: el);

  factory RuleContext.fromJson(Object? val, {required String baseUrl}) {
    if (val is String) {
      final t = val.trim();
      if (t.startsWith('<') && t.contains('>')) {
        final doc = html_parser.parseFragment(t);
        final wrapper = dom.Element.tag('div')..nodes.addAll(doc.nodes.toList());
        return RuleContext._(
          baseUrl: baseUrl,
          element: wrapper,
          value: val,
          rawOverride: val,
        );
      }
    }
    return RuleContext._(baseUrl: baseUrl, value: val);
  }

  factory RuleContext.fromRegexMatch(Match m, {required String baseUrl}) =>
      RuleContext._(
        baseUrl: baseUrl,
        regexMatch: m,
        rawOverride: m.group(0) ?? '',
      );
}

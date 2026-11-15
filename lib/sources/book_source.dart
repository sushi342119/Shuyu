import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../gbk_codec.dart';
import '../regex_safety.dart';
import 'network_url_safety.dart';

enum SourceContentType {
  text(0, '小说'),
  manga(2, '漫画'),
  unsupportedAudio(1, '有声(暂不支持)'),
  unsupportedFile(3, '文件(暂不支持)');

  const SourceContentType(this.legadoType, this.label);
  final int legadoType;
  final String label;

  static SourceContentType fromLegadoType(Object? raw) {
    final code = switch (raw) {
      final int n => n,
      final num n => n.toInt(),
      final String s => switch (s.trim().toLowerCase()) {
        '2' || 'manga' || 'comic' || 'image' => 2,
        '1' || 'audio' => 1,
        '3' || 'file' => 3,
        _ => 0,
      },
      _ => 0,
    };
    return switch (code) {
      2 => SourceContentType.manga,
      1 => SourceContentType.unsupportedAudio,
      3 => SourceContentType.unsupportedFile,
      _ => SourceContentType.text,
    };
  }

  bool get isSupported =>
      this == SourceContentType.text || this == SourceContentType.manga;
}

enum SourceCompatibility {
  full('完全兼容'),
  partial('部分兼容'),
  requiresJs('需脚本暂不支持'),
  unsupportedType('类型暂不支持');

  const SourceCompatibility(this.label);
  final String label;

  bool get canEnable =>
      this == SourceCompatibility.full || this == SourceCompatibility.partial;
}

class SourceExploreKind {
  const SourceExploreKind({required this.title, required this.url});

  final String title;
  final String url;

  /// Whether [url] contains a Legado pagination placeholder (`{{page}}`,
  /// `{{page-1}}`, `<,page_2.html>`, etc.) rather than a static single-page feed.
  bool get supportsPagination {
    final lower = url.toLowerCase();
    return lower.contains('{{page') ||
        lower.contains('<,') ||
        RegExp(r'\{\{[^}]*\bpage\b[^}]*\}\}').hasMatch(lower);
  }

  Map<String, Object?> toJson() => {'title': title, 'url': url};

  static SourceExploreKind? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = '${raw['title'] ?? ''}'.trim();
    final url = '${raw['url'] ?? ''}'.trim();
    if (title.isEmpty || url.isEmpty) return null;
    return SourceExploreKind(title: title, url: url);
  }
}

class SourceListRule {
  const SourceListRule({
    this.bookList = '',
    this.name = '',
    this.author = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.intro = '',
    this.coverUrl = '',
    this.bookUrl = '',
    this.checkKeyWord = '',
  });

  final String bookList;
  final String name;
  final String author;
  final String kind;
  final String wordCount;
  final String lastChapter;
  final String intro;
  final String coverUrl;
  final String bookUrl;
  final String checkKeyWord;

  bool get isEmpty => bookList.trim().isEmpty || name.trim().isEmpty;

  Map<String, Object?> toJson() => {
    if (bookList.isNotEmpty) 'bookList': bookList,
    if (name.isNotEmpty) 'name': name,
    if (author.isNotEmpty) 'author': author,
    if (kind.isNotEmpty) 'kind': kind,
    if (wordCount.isNotEmpty) 'wordCount': wordCount,
    if (lastChapter.isNotEmpty) 'lastChapter': lastChapter,
    if (intro.isNotEmpty) 'intro': intro,
    if (coverUrl.isNotEmpty) 'coverUrl': coverUrl,
    if (bookUrl.isNotEmpty) 'bookUrl': bookUrl,
    if (checkKeyWord.isNotEmpty) 'checkKeyWord': checkKeyWord,
  };

  factory SourceListRule.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const SourceListRule();
    String s(String k, [String alt = '']) =>
        '${map[k] ?? (alt.isEmpty ? '' : map[alt]) ?? ''}'.trim();
    return SourceListRule(
      bookList: s('bookList', 'list'),
      name: s('name', 'title'),
      author: s('author'),
      kind: s('kind', 'genre'),
      wordCount: s('wordCount'),
      lastChapter: s('lastChapter', 'latestChapter'),
      intro: s('intro', 'summary'),
      coverUrl: s('coverUrl', 'cover'),
      bookUrl: s('bookUrl', 'url'),
      checkKeyWord: s('checkKeyWord'),
    );
  }
}

class SourceBookInfoRule {
  const SourceBookInfoRule({
    this.init = '',
    this.name = '',
    this.author = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.intro = '',
    this.coverUrl = '',
    this.tocUrl = '',
  });

  final String init;
  final String name;
  final String author;
  final String kind;
  final String wordCount;
  final String lastChapter;
  final String intro;
  final String coverUrl;
  final String tocUrl;

  Map<String, Object?> toJson() => {
    if (init.isNotEmpty) 'init': init,
    if (name.isNotEmpty) 'name': name,
    if (author.isNotEmpty) 'author': author,
    if (kind.isNotEmpty) 'kind': kind,
    if (wordCount.isNotEmpty) 'wordCount': wordCount,
    if (lastChapter.isNotEmpty) 'lastChapter': lastChapter,
    if (intro.isNotEmpty) 'intro': intro,
    if (coverUrl.isNotEmpty) 'coverUrl': coverUrl,
    if (tocUrl.isNotEmpty) 'tocUrl': tocUrl,
  };

  factory SourceBookInfoRule.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const SourceBookInfoRule();
    String s(String k, [String alt = '']) =>
        '${map[k] ?? (alt.isEmpty ? '' : map[alt]) ?? ''}'.trim();
    return SourceBookInfoRule(
      init: s('init'),
      name: s('name', 'title'),
      author: s('author'),
      kind: s('kind', 'genre'),
      wordCount: s('wordCount'),
      lastChapter: s('lastChapter', 'latestChapter'),
      intro: s('intro', 'summary'),
      coverUrl: s('coverUrl', 'cover'),
      tocUrl: s('tocUrl'),
    );
  }
}

enum TocReverseMode {
  auto('auto'),
  ascending('false'),
  descending('true');

  const TocReverseMode(this.code);
  final String code;

  static TocReverseMode fromRaw(Object? raw) {
    if (raw == true) return TocReverseMode.descending;
    if (raw == false) return TocReverseMode.ascending;
    final text = '${raw ?? ''}'.trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'desc') {
      return TocReverseMode.descending;
    }
    if (text == 'false' || text == '0' || text == 'asc') {
      return TocReverseMode.ascending;
    }
    return TocReverseMode.auto;
  }
}

class SourceTocRule {
  const SourceTocRule({
    this.chapterList = '',
    this.chapterName = '',
    this.chapterUrl = '',
    this.isVolume = '',
    this.updateTime = '',
    this.nextTocUrl = '',
    this.reverse = TocReverseMode.auto,
  });

  final String chapterList;
  final String chapterName;
  final String chapterUrl;
  final String isVolume;
  final String updateTime;
  final String nextTocUrl;
  final TocReverseMode reverse;

  bool get isEmpty =>
      chapterList.trim().isEmpty || chapterName.trim().isEmpty;

  Map<String, Object?> toJson() => {
    if (chapterList.isNotEmpty) 'chapterList': chapterList,
    if (chapterName.isNotEmpty) 'chapterName': chapterName,
    if (chapterUrl.isNotEmpty) 'chapterUrl': chapterUrl,
    if (isVolume.isNotEmpty) 'isVolume': isVolume,
    if (updateTime.isNotEmpty) 'updateTime': updateTime,
    if (nextTocUrl.isNotEmpty) 'nextTocUrl': nextTocUrl,
    if (reverse != TocReverseMode.auto) 'reverse': reverse.code,
  };

  factory SourceTocRule.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const SourceTocRule();
    String s(String k, [String alt = '']) =>
        '${map[k] ?? (alt.isEmpty ? '' : map[alt]) ?? ''}'.trim();
    var listRule = s('chapterList', 'list');
    var explicitReverse = map['reverse'];
    // Legado prefixes `-` on `chapterList` to reverse a descending TOC!
    if (listRule.startsWith('-') && listRule.length > 1) {
      listRule = listRule.substring(1).trim();
      explicitReverse ??= true;
    }
    return SourceTocRule(
      chapterList: listRule,
      chapterName: s('chapterName', 'name'),
      chapterUrl: s('chapterUrl', 'url'),
      isVolume: s('isVolume'),
      updateTime: s('updateTime'),
      nextTocUrl: s('nextTocUrl', 'nextUrl'),
      reverse: TocReverseMode.fromRaw(explicitReverse),
    );
  }
}

class SourceContentRule {
  const SourceContentRule({
    this.content = '',
    this.nextContentUrl = '',
    this.sourceRegex = '',
    this.replaceRegex = '',
    this.imageStyle = '',
    this.imageDecode = '',
  });

  final String content;
  final String nextContentUrl;
  final String sourceRegex;
  final String replaceRegex;
  final String imageStyle;
  final String imageDecode;

  bool get isEmpty => content.trim().isEmpty;

  Map<String, Object?> toJson() => {
    if (content.isNotEmpty) 'content': content,
    if (nextContentUrl.isNotEmpty) 'nextContentUrl': nextContentUrl,
    if (sourceRegex.isNotEmpty) 'sourceRegex': sourceRegex,
    if (replaceRegex.isNotEmpty) 'replaceRegex': replaceRegex,
    if (imageStyle.isNotEmpty) 'imageStyle': imageStyle,
    if (imageDecode.isNotEmpty) 'imageDecode': imageDecode,
  };

  factory SourceContentRule.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const SourceContentRule();
    String s(String k, [String alt = '']) =>
        '${map[k] ?? (alt.isEmpty ? '' : map[alt]) ?? ''}'.trim();
    return SourceContentRule(
      content: s('content'),
      nextContentUrl: s('nextContentUrl', 'nextUrl'),
      sourceRegex: s('sourceRegex'),
      replaceRegex: s('replaceRegex'),
      imageStyle: s('imageStyle'),
      imageDecode: s('imageDecode'),
    );
  }
}

class ResolvedSourceRequest {
  const ResolvedSourceRequest({
    required this.uri,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.charset,
    this.requiresWebView = false,
  });

  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final String? charset;
  final bool requiresWebView;
}

class BookSource {
  const BookSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.group = '',
    this.comment = '',
    this.contentType = SourceContentType.text,
    this.enabled = true,
    this.enabledExplore = true,
    this.weight = 0,
    this.minIntervalMs = 350,
    this.headers = const {},
    this.searchUrl = '',
    this.exploreKinds = const [],
    this.ruleSearch = const SourceListRule(),
    this.ruleExplore = const SourceListRule(),
    this.ruleBookInfo = const SourceBookInfoRule(),
    this.ruleToc = const SourceTocRule(),
    this.ruleContent = const SourceContentRule(),
    this.compatibility = SourceCompatibility.full,
    this.compatibilityNotes = const [],
    this.importOrigin = '',
  });

  final String id;
  final String name;
  final String baseUrl;
  final String group;
  final String comment;
  final SourceContentType contentType;
  final bool enabled;
  final bool enabledExplore;
  final int weight;
  final int minIntervalMs;
  final Map<String, String> headers;
  final String searchUrl;
  final List<SourceExploreKind> exploreKinds;
  final SourceListRule ruleSearch;
  final SourceListRule ruleExplore;
  final SourceBookInfoRule ruleBookInfo;
  final SourceTocRule ruleToc;
  final SourceContentRule ruleContent;
  final SourceCompatibility compatibility;
  final List<String> compatibilityNotes;
  final String importOrigin;

  bool get isManga => contentType == SourceContentType.manga;
  bool get isHttpCleartext => baseUrl.toLowerCase().startsWith('http://');
  bool get canSearch =>
      compatibility.canEnable &&
      searchUrl.trim().isNotEmpty &&
      !containsScriptDirective(searchUrl) &&
      !_urlOptionUsesWebView(searchUrl) &&
      !ruleSearch.isEmpty &&
      !containsScriptDirective(ruleSearch.bookList) &&
      !containsScriptDirective(ruleSearch.name) &&
      !containsScriptDirective(ruleSearch.bookUrl);
  bool get canExplore {
    final exploreRule = effectiveExploreRule;
    return compatibility.canEnable &&
        enabledExplore &&
        exploreKinds.isNotEmpty &&
        !exploreRule.isEmpty &&
        !containsScriptDirective(exploreRule.bookList) &&
        !containsScriptDirective(exploreRule.name) &&
        !containsScriptDirective(exploreRule.bookUrl);
  }

  SourceListRule get effectiveExploreRule =>
      ruleExplore.isEmpty ? ruleSearch : ruleExplore;

  BookSource copyWith({
    String? name,
    String? group,
    String? comment,
    bool? enabled,
    bool? enabledExplore,
    int? weight,
    int? minIntervalMs,
    Map<String, String>? headers,
  }) => BookSource(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl,
    group: group ?? this.group,
    comment: comment ?? this.comment,
    contentType: contentType,
    enabled: (enabled ?? this.enabled) && compatibility.canEnable,
    enabledExplore: enabledExplore ?? this.enabledExplore,
    weight: weight ?? this.weight,
    minIntervalMs: minIntervalMs ?? this.minIntervalMs,
    headers: headers ?? this.headers,
    searchUrl: searchUrl,
    exploreKinds: exploreKinds,
    ruleSearch: ruleSearch,
    ruleExplore: ruleExplore,
    ruleBookInfo: ruleBookInfo,
    ruleToc: ruleToc,
    ruleContent: ruleContent,
    compatibility: compatibility,
    compatibilityNotes: compatibilityNotes,
    importOrigin: importOrigin,
  );

  Map<String, Object?> toJson({bool stripSensitiveHeaders = false}) {
    final cleanHeaders = stripSensitiveHeaders
        ? {
            for (final entry in headers.entries)
              if (!_isSensitiveHeaderName(entry.key)) entry.key: entry.value,
          }
        : headers;
    return {
      'id': id,
      'bookSourceName': name,
      'bookSourceUrl': baseUrl,
      'bookSourceType': contentType.legadoType,
      if (group.isNotEmpty) 'bookSourceGroup': group,
      if (comment.isNotEmpty) 'bookSourceComment': comment,
      'enabled': enabled && compatibility.canEnable,
      'enabledExplore': enabledExplore,
      if (weight != 0) 'weight': weight,
      'minIntervalMs': minIntervalMs,
      if (cleanHeaders.isNotEmpty) 'headers': cleanHeaders,
      if (searchUrl.isNotEmpty) 'searchUrl': searchUrl,
      if (exploreKinds.isNotEmpty)
        'exploreKinds': [for (final k in exploreKinds) k.toJson()],
      'ruleSearch': ruleSearch.toJson(),
      if (!ruleExplore.isEmpty) 'ruleExplore': ruleExplore.toJson(),
      'ruleBookInfo': ruleBookInfo.toJson(),
      'ruleToc': ruleToc.toJson(),
      'ruleContent': ruleContent.toJson(),
      'compatibility': compatibility.name,
      if (compatibilityNotes.isNotEmpty)
        'compatibilityNotes': compatibilityNotes,
      if (importOrigin.isNotEmpty) 'importOrigin': importOrigin,
    };
  }

  static bool _isSensitiveHeaderName(String name) {
    final lower = name.trim().toLowerCase();
    return lower == 'cookie' ||
        lower == 'authorization' ||
        lower == 'proxy-authorization' ||
        lower == 'x-api-key' ||
        lower == 'token';
  }

  static final RegExp _jsDirectivePattern = RegExp(
    r'(?:^|\n)\s*@js:|<js>[\s\S]*?</js>|\{\{[\s\S]*?(?:java\.|cookie\.|source\.)',
    caseSensitive: false,
  );

  static bool containsScriptDirective(String value) {
    if (value.isEmpty) return false;
    return _jsDirectivePattern.hasMatch(value);
  }

  static String computeSourceId(String normalizedBaseUrl, String name) {
    final digest = sha256
        .convert(utf8.encode('${normalizedBaseUrl.toLowerCase()}\n$name'))
        .toString();
    return 'src_${digest.substring(0, 16)}';
  }

  /// Parses either a Legado 3.0 book-source map or a Shuyu native book-source map.
  static BookSource? fromAnyMap(
    Map<String, dynamic> raw, {
    String importOrigin = '',
    bool? overrideEnabled,
  }) {
    final rawName = '${raw['bookSourceName'] ?? raw['name'] ?? ''}'.trim();
    final rawBaseUrl = '${raw['bookSourceUrl'] ?? raw['baseUrl'] ?? ''}'.trim();
    if (rawName.isEmpty || rawBaseUrl.isEmpty) return null;

    Uri baseUri;
    try {
      // Legado `bookSourceUrl` occasionally appends `#tag` comments (e.g. `https://a.com#优选`).
      final hashIndex = rawBaseUrl.indexOf('#');
      final cleanBase = hashIndex > 0
          ? rawBaseUrl.substring(0, hashIndex).trim()
          : rawBaseUrl;
      baseUri = NetworkUrlSafety.parsePublicHttpUrl(cleanBase, allowHttp: true);
    } on FormatException {
      return null;
    }

    final normalizedBaseUrl = baseUri.toString();
    final contentType = SourceContentType.fromLegadoType(
      raw['bookSourceType'] ?? raw['contentType'],
    );
    final group = '${raw['bookSourceGroup'] ?? raw['group'] ?? ''}'.trim();
    final comment =
        '${raw['bookSourceComment'] ?? raw['comment'] ?? ''}'.trim();
    final searchUrl = '${raw['searchUrl'] ?? ''}'.trim();

    Map<String, dynamic>? asMap(Object? v) {
      if (v is Map<String, dynamic>) return v;
      if (v is Map) {
        return {for (final e in v.entries) '${e.key}': e.value};
      }
      if (v is String && v.trim().startsWith('{')) {
        try {
          final d = jsonDecode(v);
          if (d is Map) {
            return {for (final e in d.entries) '${e.key}': e.value};
          }
        } catch (_) {}
      }
      return null;
    }

    Map<String, String> parseHeaders(Object? rawHeader) {
      if (rawHeader == null) return const {};
      if (rawHeader is String) {
        final trimmed = rawHeader.trim();
        if (trimmed.isEmpty || containsScriptDirective(trimmed)) {
          return const {};
        }
        final decoded = asMap(trimmed);
        if (decoded != null) {
          return {
            for (final e in decoded.entries)
              if (e.key.trim().isNotEmpty && e.value != null)
                e.key.trim(): '${e.value}'.trim(),
          };
        }
        return const {};
      }
      final map = asMap(rawHeader);
      if (map == null) return const {};
      return {
        for (final e in map.entries)
          if (e.key.trim().isNotEmpty && e.value != null)
            e.key.trim(): '${e.value}'.trim(),
      };
    }

    final headers = <String, String>{
      ...parseHeaders(raw['header']),
      ...parseHeaders(raw['headers']),
    };
    final userAgent = '${raw['userAgent'] ?? ''}'.trim();
    if (userAgent.isNotEmpty &&
        !headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = userAgent;
    }

    final notes = <String>[];
    var exploreHasJs = false;
    final exploreKinds = <SourceExploreKind>[];
    void addSafeExploreKind(SourceExploreKind k) {
      if (containsScriptDirective(k.url) || _urlOptionUsesWebView(k.url)) {
        exploreHasJs = true;
        return;
      }
      exploreKinds.add(k);
    }

    if (raw['exploreKinds'] is List) {
      for (final item in raw['exploreKinds'] as List) {
        final k = SourceExploreKind.fromJson(item);
        if (k != null) addSafeExploreKind(k);
      }
    } else if (raw['exploreUrl'] != null) {
      final rawExplore = '${raw['exploreUrl']}'.trim();
      if (rawExplore.isNotEmpty) {
        if (containsScriptDirective(rawExplore)) {
          exploreHasJs = true;
          notes.add('发现分类使用动态脚本生成，已自动隐藏分类榜单');
        } else {
          for (final k in _parseLegadoExploreUrl(rawExplore)) {
            addSafeExploreKind(k);
          }
          if (exploreHasJs && exploreKinds.isEmpty) {
            notes.add('发现分类依赖动态渲染，已自动隐藏分类榜单');
          }
        }
      }
    }

    final rawRuleSearch = SourceListRule.fromMap(asMap(raw['ruleSearch']));
    final rawRuleExplore = SourceListRule.fromMap(asMap(raw['ruleExplore']));
    final rawRuleInfo = SourceBookInfoRule.fromMap(asMap(raw['ruleBookInfo']));
    final rawRuleToc = SourceTocRule.fromMap(asMap(raw['ruleToc']));
    final rawRuleContent = SourceContentRule.fromMap(asMap(raw['ruleContent']));

    // Sanitize optional fields if only optional metadata uses `@js:`, while
    // strictly flagging core pipeline stages (`search`, `toc`, `content`).
    String cleanOptional(String value, String fieldLabel) {
      if (containsScriptDirective(value)) {
        notes.add('$fieldLabel 含脚本规则，已跳过该辅助字段');
        return '';
      }
      return value;
    }

    final ruleSearch = SourceListRule(
      bookList: rawRuleSearch.bookList,
      name: rawRuleSearch.name,
      author: cleanOptional(rawRuleSearch.author, '搜索作者字段'),
      kind: cleanOptional(rawRuleSearch.kind, '搜索分类字段'),
      wordCount: cleanOptional(rawRuleSearch.wordCount, '搜索字数字段'),
      lastChapter: cleanOptional(rawRuleSearch.lastChapter, '搜索最新章字段'),
      intro: cleanOptional(rawRuleSearch.intro, '搜索简介字段'),
      coverUrl: cleanOptional(rawRuleSearch.coverUrl, '搜索封面字段'),
      bookUrl: rawRuleSearch.bookUrl,
      checkKeyWord: rawRuleSearch.checkKeyWord,
    );

    final ruleExplore = SourceListRule(
      bookList: rawRuleExplore.bookList,
      name: rawRuleExplore.name,
      author: cleanOptional(rawRuleExplore.author, '发现作者字段'),
      kind: cleanOptional(rawRuleExplore.kind, '发现分类字段'),
      wordCount: cleanOptional(rawRuleExplore.wordCount, '发现字数字段'),
      lastChapter: cleanOptional(rawRuleExplore.lastChapter, '发现最新章字段'),
      intro: cleanOptional(rawRuleExplore.intro, '发现简介字段'),
      coverUrl: cleanOptional(rawRuleExplore.coverUrl, '发现封面字段'),
      bookUrl: rawRuleExplore.bookUrl,
      checkKeyWord: rawRuleExplore.checkKeyWord,
    );

    final ruleBookInfo = SourceBookInfoRule(
      init: cleanOptional(rawRuleInfo.init, '详情初始化规则'),
      name: cleanOptional(rawRuleInfo.name, '详情书名字段'),
      author: cleanOptional(rawRuleInfo.author, '详情作者字段'),
      kind: cleanOptional(rawRuleInfo.kind, '详情分类字段'),
      wordCount: cleanOptional(rawRuleInfo.wordCount, '详情字数字段'),
      lastChapter: cleanOptional(rawRuleInfo.lastChapter, '详情最新章字段'),
      intro: cleanOptional(rawRuleInfo.intro, '详情简介字段'),
      coverUrl: cleanOptional(rawRuleInfo.coverUrl, '详情封面字段'),
      tocUrl: rawRuleInfo.tocUrl,
    );

    final ruleToc = SourceTocRule(
      chapterList: rawRuleToc.chapterList,
      chapterName: rawRuleToc.chapterName,
      chapterUrl: rawRuleToc.chapterUrl,
      isVolume: cleanOptional(rawRuleToc.isVolume, '分卷识别字段'),
      updateTime: cleanOptional(rawRuleToc.updateTime, '章节时间字段'),
      nextTocUrl: cleanOptional(rawRuleToc.nextTocUrl, '目录翻页规则'),
      reverse: rawRuleToc.reverse,
    );

    var safeReplaceRegex = rawRuleContent.replaceRegex;
    if (containsScriptDirective(safeReplaceRegex)) {
      notes.add('正文净化规则含脚本，已跳过该替换项');
      safeReplaceRegex = '';
    } else if (safeReplaceRegex.isNotEmpty) {
      for (final line in safeReplaceRegex.split('\n')) {
        final pat = line.split('##').first.trim();
        if (pat.isNotEmpty && detectUnsafeRegexPattern(pat) != null) {
          notes.add('正文替换包含高风险回溯正则，已自动过滤');
          safeReplaceRegex = '';
          break;
        }
      }
    }

    final ruleContent = SourceContentRule(
      content: rawRuleContent.content,
      nextContentUrl: cleanOptional(rawRuleContent.nextContentUrl, '正文翻页规则'),
      sourceRegex: rawRuleContent.sourceRegex,
      replaceRegex: safeReplaceRegex,
      imageStyle: rawRuleContent.imageStyle,
      imageDecode: rawRuleContent.imageDecode,
    );

    final effectiveExplore = ruleExplore.isEmpty ? ruleSearch : ruleExplore;
    final hasStaticExplore =
        exploreKinds.isNotEmpty &&
        !effectiveExplore.isEmpty &&
        !containsScriptDirective(effectiveExplore.bookList) &&
        !containsScriptDirective(effectiveExplore.name) &&
        !containsScriptDirective(effectiveExplore.bookUrl);

    final searchProblems = <String>[];
    if (searchUrl.isNotEmpty) {
      if (containsScriptDirective(searchUrl)) {
        searchProblems.add('搜索地址依赖 @js 动态签名');
      }
      if (_urlOptionUsesWebView(searchUrl)) {
        searchProblems.add('搜索请求依赖 WebView 渲染');
      }
      if (ruleSearch.isEmpty ||
          containsScriptDirective(ruleSearch.bookList) ||
          containsScriptDirective(ruleSearch.name) ||
          containsScriptDirective(ruleSearch.bookUrl)) {
        searchProblems.add('搜索列表核心提取规则依赖脚本或为空');
      }
    }
    final hasStaticSearch = searchUrl.isNotEmpty && searchProblems.isEmpty;

    final coreBrokenReasons = <String>[];
    if (!contentType.isSupported) {
      coreBrokenReasons.add('当前仅支持小说(0)与漫画(2)书源');
    } else {
      if (!hasStaticSearch && !hasStaticExplore) {
        if (searchProblems.isNotEmpty) {
          coreBrokenReasons.addAll(searchProblems);
        } else {
          coreBrokenReasons.add('缺少可用的静态搜索地址或发现分类规则');
        }
      } else if (!hasStaticSearch && searchProblems.isNotEmpty) {
        notes.add('搜索功能依赖脚本或动态渲染，仅支持分类榜单浏览');
      }
      if (containsScriptDirective(ruleBookInfo.tocUrl)) {
        coreBrokenReasons.add('目录入口地址依赖 @js 脚本');
      }
      if (ruleToc.isEmpty ||
          containsScriptDirective(ruleToc.chapterList) ||
          containsScriptDirective(ruleToc.chapterName) ||
          containsScriptDirective(ruleToc.chapterUrl)) {
        coreBrokenReasons.add('章节目录核心提取规则依赖脚本或为空');
      }
      if (ruleContent.isEmpty || containsScriptDirective(ruleContent.content)) {
        coreBrokenReasons.add('正文/图片提取规则依赖脚本或为空');
      }
      if (ruleContent.imageDecode.trim().isNotEmpty) {
        coreBrokenReasons.add('该漫画源图片经过脚本字节加密(imageDecode)，暂不支持');
      }
    }

    final compatibility = !contentType.isSupported
        ? SourceCompatibility.unsupportedType
        : coreBrokenReasons.isNotEmpty
        ? SourceCompatibility.requiresJs
        : (exploreHasJs || notes.isNotEmpty)
        ? SourceCompatibility.partial
        : SourceCompatibility.full;

    final allNotes = <String>[...coreBrokenReasons, ...notes];

    final rawEnabled = overrideEnabled ?? (raw['enabled'] != false);
    final rawEnabledExplore = raw['enabledExplore'] != false;
    final rawId = '${raw['id'] ?? ''}'.trim();
    final id = rawId.isNotEmpty
        ? rawId
        : computeSourceId(normalizedBaseUrl, rawName);

    final rawRate = raw['concurrentRate'];
    var minIntervalMs = raw['minIntervalMs'] is int
        ? (raw['minIntervalMs'] as int).clamp(100, 10000)
        : 350;
    if (rawRate is String && rawRate.contains('/')) {
      final parts = rawRate.split('/');
      final count = int.tryParse(parts.first.trim()) ?? 1;
      final ms = int.tryParse(parts.last.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      if (count > 0 && ms > 0) {
        minIntervalMs = (ms ~/ count).clamp(150, 10000);
      }
    }

    return BookSource(
      id: id,
      name: rawName,
      baseUrl: normalizedBaseUrl,
      group: group,
      comment: comment,
      contentType: contentType,
      enabled: rawEnabled && compatibility.canEnable,
      enabledExplore: rawEnabledExplore && hasStaticExplore,
      weight: raw['weight'] is num ? (raw['weight'] as num).toInt() : 0,
      minIntervalMs: minIntervalMs,
      headers: Map.unmodifiable(headers),
      searchUrl: searchUrl,
      exploreKinds: List.unmodifiable(exploreKinds),
      ruleSearch: ruleSearch,
      ruleExplore: ruleExplore,
      ruleBookInfo: ruleBookInfo,
      ruleToc: ruleToc,
      ruleContent: ruleContent,
      compatibility: compatibility,
      compatibilityNotes: List.unmodifiable(allNotes),
      importOrigin: importOrigin,
    );
  }

  static bool _urlOptionUsesWebView(String spec) {
    final idx = RegExp(r',\s*\{').firstMatch(spec);
    if (idx == null) return false;
    try {
      final jsonPart = spec.substring(idx.start + 1).trim();
      final decoded = jsonDecode(jsonPart);
      return decoded is Map &&
          (decoded['webView'] == true || decoded['webView'] == 'true');
    } catch (_) {
      return false;
    }
  }

  static List<SourceExploreKind> _parseLegadoExploreUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return [
            for (final item in decoded)
              if (item is Map)
                if ('${item['title'] ?? ''}'.trim().isNotEmpty &&
                    '${item['url'] ?? ''}'.trim().isNotEmpty)
                  SourceExploreKind(
                    title: '${item['title']}'.trim(),
                    url: '${item['url']}'.trim(),
                  ),
          ];
        }
      } catch (_) {}
    }

    final kinds = <SourceExploreKind>[];
    for (final line in trimmed.split(RegExp(r'(?:\r?\n|&&)+'))) {
      final entry = line.trim();
      if (entry.isEmpty) continue;
      final sep = entry.indexOf('::');
      if (sep <= 0) continue;
      final title = entry.substring(0, sep).trim();
      final url = entry.substring(sep + 2).trim();
      if (title.isEmpty || url.isEmpty) continue;
      kinds.add(SourceExploreKind(title: title, url: url));
    }
    return kinds;
  }

  /// Resolves a Legado URL template (`searchUrl`, `exploreUrl`, or relative URL
  /// with trailing `,{"method":"POST","body":...,"charset":"GBK"}`) into an
  /// executable [ResolvedSourceRequest].
  ResolvedSourceRequest buildRequest(
    String templateOrUrl, {
    String keyword = '',
    int page = 1,
    String? baseOverride,
  }) {
    final raw = templateOrUrl.trim();
    if (raw.isEmpty) {
      throw const FormatException('请求地址模板为空');
    }

    var urlTemplate = raw;
    Map<String, dynamic>? options;
    final splitMatch = RegExp(r',\s*\{').firstMatch(raw);
    if (splitMatch != null) {
      final candidateJson = raw.substring(splitMatch.start + 1).trim();
      try {
        final parsed = jsonDecode(candidateJson);
        if (parsed is Map) {
          urlTemplate = raw.substring(0, splitMatch.start).trim();
          options = {for (final e in parsed.entries) '${e.key}': e.value};
        }
      } catch (_) {}
    }

    final charset = options?['charset'] is String
        ? (options!['charset'] as String).trim()
        : null;
    final method = '${options?['method'] ?? 'GET'}'.trim().toUpperCase();
    final requiresWebView =
        options?['webView'] == true || options?['webView'] == 'true';

    final mergedHeaders = <String, String>{...headers};
    final optHeaders = options?['headers'] ?? options?['header'];
    if (optHeaders is Map) {
      for (final e in optHeaders.entries) {
        if ('${e.key}'.trim().isNotEmpty && e.value != null) {
          mergedHeaders['${e.key}'.trim()] = '${e.value}'.trim();
        }
      }
    } else if (optHeaders is String && optHeaders.trim().startsWith('{')) {
      try {
        final inner = jsonDecode(optHeaders);
        if (inner is Map) {
          for (final e in inner.entries) {
            if ('${e.key}'.trim().isNotEmpty && e.value != null) {
              mergedHeaders['${e.key}'.trim()] = '${e.value}'.trim();
            }
          }
        }
      } catch (_) {}
    }

    final expandedUrl = _expandTemplate(
      urlTemplate,
      keyword: keyword,
      page: page,
      charset: charset,
      urlEncodeKeyword: true,
    );

    final effectiveBase = (baseOverride != null && baseOverride.isNotEmpty)
        ? Uri.parse(baseOverride)
        : Uri.parse(baseUrl);
    final resolvedUri = NetworkUrlSafety.parsePublicHttpUrl(
      effectiveBase.resolve(expandedUrl).toString(),
      allowHttp: true,
    );

    String? body;
    if (options != null && options['body'] != null) {
      final rawBody = options['body'];
      final bodyTemplate = rawBody is String ? rawBody : jsonEncode(rawBody);
      final looksJson = bodyTemplate.trimLeft().startsWith('{') ||
          bodyTemplate.trimLeft().startsWith('[');
      body = _expandTemplate(
        bodyTemplate,
        keyword: keyword,
        page: page,
        charset: charset,
        urlEncodeKeyword: !looksJson,
      );
      if (!mergedHeaders.keys.any((k) => k.toLowerCase() == 'content-type')) {
        mergedHeaders['Content-Type'] = looksJson
            ? 'application/json; charset=${charset ?? 'utf-8'}'
            : 'application/x-www-form-urlencoded; charset=${charset ?? 'utf-8'}';
      }
    }

    return ResolvedSourceRequest(
      uri: resolvedUri,
      method: method == 'POST' ? 'POST' : 'GET',
      headers: Map.unmodifiable(mergedHeaders),
      body: body,
      charset: charset,
      requiresWebView: requiresWebView,
    );
  }

  static String _expandTemplate(
    String template, {
    required String keyword,
    required int page,
    required String? charset,
    required bool urlEncodeKeyword,
  }) {
    var result = template;

    // 1. Legado angle-bracket page alternation: `<firstPage,page2Plus>`
    // e.g. `/sort/1/<index.html,{{page}}.html>` or `/list_<,{{page}}>.html`
    result = result.replaceAllMapped(RegExp(r'<([^<>]*?,[^<>]*?)>'), (m) {
      final choices = m.group(1)!.split(',');
      final idx = (page - 1).clamp(0, choices.length - 1);
      return choices[idx];
    });

    final encodedKey = urlEncodeKeyword
        ? encodeQueryValueWithCharset(keyword, charset: charset)
        : keyword.replaceAll('"', r'\"');

    // 2. Replace `{{...}}` placeholders (including `{{key}}`, `{{page}}`, `{{page-1}}`, `{{(page-1)*20}}`).
    result = result.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (m) {
      final expr = m.group(1)!.trim();
      if (expr == 'key' || expr == 'searchKey') return encodedKey;
      if (expr == 'page') return '$page';
      final pageMath = _evalSafePageExpression(expr, page);
      if (pageMath != null) return '$pageMath';
      if (expr.contains('key')) {
        return expr.replaceAll('key', encodedKey).replaceAll('page', '$page');
      }
      return m.group(0)!;
    });

    // Legacy Legado 2.x fallback tokens `searchKey` / `searchPage`
    if (result.contains('searchKey')) {
      result = result.replaceAll('searchKey', encodedKey);
    }
    if (result.contains('searchPage-1')) {
      result = result.replaceAll('searchPage-1', '${page - 1}');
    }
    if (result.contains('searchPage')) {
      result = result.replaceAll('searchPage', '$page');
    }

    return result;
  }

  /// Evaluates simple integer arithmetic over `page` such as `page-1`, `page+1`,
  /// `(page-1)*20`, `page*10` without any script interpreter.
  static int? _evalSafePageExpression(String expr, int page) {
    final compact = expr.replaceAll(' ', '');
    final m1 = RegExp(r'^page([+-])(\d+)$').firstMatch(compact);
    if (m1 != null) {
      final n = int.parse(m1.group(2)!);
      return m1.group(1) == '+' ? page + n : page - n;
    }
    final m2 = RegExp(r'^\(page([+-])(\d+)\)\*(\d+)$').firstMatch(compact);
    if (m2 != null) {
      final delta = int.parse(m2.group(2)!);
      final mult = int.parse(m2.group(3)!);
      final base = m2.group(1) == '+' ? page + delta : page - delta;
      return base * mult;
    }
    final m3 = RegExp(r'^page\*(\d+)([+-]\d+)?$').firstMatch(compact);
    if (m3 != null) {
      final mult = int.parse(m3.group(1)!);
      final offset = m3.group(2) != null ? int.parse(m3.group(2)!) : 0;
      return page * mult + offset;
    }
    return null;
  }
}

/// Parses a JSON string (single object or list of objects) into [BookSource]s.
({
  List<BookSource> sources,
  int fullCount,
  int partialCount,
  int unsupportedCount,
  int invalidCount,
})
parseBookSourcesJson(String rawJson, {String importOrigin = ''}) {
  final clean = rawJson.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
  if (clean.isEmpty) {
    throw const FormatException('书源内容为空');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(clean);
  } on FormatException {
    throw const FormatException('书源内容不是有效的 JSON 格式');
  }

  final List<Object?> rawItems = switch (decoded) {
    final List<Object?> list => list,
    final Map<Object?, Object?> map when map['sources'] is List =>
      map['sources'] as List<Object?>,
    final Map<Object?, Object?> map => [map],
    _ => throw const FormatException('未识别的书源 JSON 结构'),
  };

  if (rawItems.length > 5000) {
    throw const FormatException('单次导入书源数量超出上限（最多 5000 条）');
  }

  final parsed = <BookSource>[];
  var full = 0;
  var partial = 0;
  var unsupported = 0;
  var invalid = 0;

  for (final item in rawItems) {
    if (item is! Map) {
      invalid++;
      continue;
    }
    final map = <String, dynamic>{
      for (final e in item.entries) '${e.key}': e.value,
    };
    final src = BookSource.fromAnyMap(map, importOrigin: importOrigin);
    if (src == null) {
      invalid++;
      continue;
    }
    switch (src.compatibility) {
      case SourceCompatibility.full:
        full++;
      case SourceCompatibility.partial:
        partial++;
      case SourceCompatibility.requiresJs ||
          SourceCompatibility.unsupportedType:
        unsupported++;
    }
    parsed.add(src);
  }

  return (
    sources: parsed,
    fullCount: full,
    partialCount: partial,
    unsupportedCount: unsupported,
    invalidCount: invalid,
  );
}

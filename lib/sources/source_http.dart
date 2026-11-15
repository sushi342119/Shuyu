import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../gbk_codec.dart';
import '../http_download.dart';
import 'book_source.dart';
import 'network_url_safety.dart';

class SourceChallengeException implements Exception {
  const SourceChallengeException([
    this.message =
        '目标站点触发了人机验证或防爬保护，暂无法直接访问。可在「在线书源」中配置 Cookie / User-Agent 或更换书源。',
  ]);

  final String message;

  @override
  String toString() => message;
}

class SourceWebViewRequiredException implements Exception {
  const SourceWebViewRequiredException([
    this.message = '该书源请求依赖浏览器动态渲染（webView），当前纯静态引擎暂不支持。',
  ]);

  final String message;

  @override
  String toString() => message;
}

class SourceHttpResponse {
  const SourceHttpResponse({
    required this.finalUri,
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final Uri finalUri;
  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

class _SourceRateGate {
  DateTime _nextAllowed = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future<void>.value();

  Future<T> schedule<T>(int minIntervalMs, Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.catchError((Object _) {}).then((_) async {
      final now = DateTime.now();
      if (now.isBefore(_nextAllowed)) {
        await Future<void>.delayed(_nextAllowed.difference(now));
      }
      _nextAllowed = DateTime.now().add(
        Duration(milliseconds: minIntervalMs.clamp(0, 10000)),
      );
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

typedef SourceHttpTransport =
    Future<SourceHttpResponse> Function(ResolvedSourceRequest request);

/// Executes HTTP/HTTPS `GET` and `POST` requests for [BookSource] pipelines with
/// SSRF validation, per-source rate limiting, UTF-8/GBK auto-decoding, and
/// honest anti-bot challenge detection (never solving/bypassing CAPTCHAs).
class SourceHttpClient {
  SourceHttpClient({
    HttpClient Function()? clientFactory,
    SourceHttpTransport? transport,
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 15),
    this.streamTimeout = const Duration(seconds: 20),
  }) : _clientFactory = clientFactory,
       _transport = transport;

  static SourceHttpClient shared = SourceHttpClient();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  final HttpClient Function()? _clientFactory;
  final SourceHttpTransport? _transport;
  final int maxResponseBytes;
  final Duration requestTimeout;
  final Duration streamTimeout;

  final Map<String, _SourceRateGate> _gates = <String, _SourceRateGate>{};

  Future<SourceHttpResponse> send(
    ResolvedSourceRequest request, {
    int minIntervalMs = 250,
    String? rateKey,
  }) async {
    if (request.requiresWebView) {
      throw const SourceWebViewRequiredException();
    }
    await NetworkUrlSafety.ensureSafeDestination(
      request.uri,
      allowHttp: true,
    );

    final custom = _transport;
    if (custom != null) {
      return custom(request);
    }

    final key = (rateKey ?? request.uri.host).toLowerCase();
    final gate = _gates.putIfAbsent(key, _SourceRateGate.new);
    return gate.schedule(minIntervalMs, () => _execute(request));
  }

  Future<SourceHttpResponse> _execute(ResolvedSourceRequest initial) async {
    final client =
        (_clientFactory != null ? _clientFactory() : HttpClient())
          ..connectionTimeout = requestTimeout
          ..autoUncompress = true;

    try {
      var currentUri = initial.uri;
      var currentMethod = initial.method.toUpperCase();
      var currentBody = initial.body;

      for (var hop = 0; hop <= 5; hop++) {
        await NetworkUrlSafety.ensureSafeDestination(
          currentUri,
          allowHttp: true,
        );

        final req = await client
            .openUrl(currentMethod, currentUri)
            .timeout(requestTimeout);
        req.followRedirects = false;
        try {
          req.maxRedirects = 0;
        } catch (_) {}

        final mergedHeaders = <String, String>{
          HttpHeaders.userAgentHeader: defaultUserAgent,
          HttpHeaders.acceptHeader:
              'text/html,application/xhtml+xml,application/json,application/xml;q=0.9,*/*;q=0.8',
          HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9,en;q=0.8',
          'Referer': '${currentUri.scheme}://${currentUri.authority}/',
        };
        for (final entry in initial.headers.entries) {
          final k = entry.key.trim();
          final v = entry.value.trim();
          if (k.isEmpty || v.isEmpty) continue;
          mergedHeaders.removeWhere(
            (existing, _) => existing.toLowerCase() == k.toLowerCase(),
          );
          mergedHeaders[k] = v;
        }
        mergedHeaders.forEach(req.headers.set);

        if (currentMethod == 'POST' && currentBody != null) {
          final bodyBytes = _encodeBodyBytes(currentBody, initial.charset);
          req.contentLength = bodyBytes.length;
          req.add(bodyBytes);
        }

        final res = await req.close().timeout(requestTimeout);
        if (HttpDownload.redirectStatuses.contains(res.statusCode)) {
          final loc = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (loc == null || hop == 5) {
            throw const FormatException('站点重定向次数过多或地址无效');
          }
          currentUri = NetworkUrlSafety.parsePublicHttpUrl(
            currentUri.resolve(loc).toString(),
            allowHttp: true,
          );
          if (res.statusCode == 301 ||
              res.statusCode == 302 ||
              res.statusCode == 303) {
            currentMethod = 'GET';
            currentBody = null;
          }
          continue;
        }

        final bytes = await HttpDownload.readBytes(
          res,
          maxBytes: maxResponseBytes,
          streamTimeout: streamTimeout,
          onLimitExceeded: () => const FormatException('页面响应超出 8 MB 安全上限'),
        );

        final contentType =
            res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
        final decodedBody = decodeResponseBytes(
          bytes,
          contentTypeHeader: contentType,
          fallbackCharset: initial.charset,
        );

        if (res.statusCode == 403 ||
            res.statusCode == 429 ||
            res.statusCode == 503) {
          if (_looksLikeAntiBotChallenge(decodedBody, res.headers)) {
            throw const SourceChallengeException();
          }
          throw HttpException('站点拒绝访问或请求过快（HTTP ${res.statusCode}）');
        }

        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('站点请求失败（HTTP ${res.statusCode}）');
        }

        if (_looksLikeAntiBotChallenge(decodedBody, res.headers)) {
          throw const SourceChallengeException();
        }

        final respHeaders = <String, String>{};
        res.headers.forEach((name, values) {
          if (values.isNotEmpty) {
            respHeaders[name.toLowerCase()] = values.join(', ');
          }
        });

        return SourceHttpResponse(
          finalUri: currentUri,
          statusCode: res.statusCode,
          body: decodedBody,
          headers: respHeaders,
        );
      }
      throw const FormatException('站点重定向次数过多');
    } finally {
      client.close(force: true);
    }
  }

  static Uint8List _encodeBodyBytes(String body, String? charset) {
    final norm = (charset ?? 'utf-8').trim().toLowerCase();
    if (norm.contains('gbk') ||
        norm.contains('gb2312') ||
        norm.contains('gb18030')) {
      return encodeGbkBytes(body);
    }
    return Uint8List.fromList(utf8.encode(body));
  }

  static final RegExp _headerCharsetPattern = RegExp(
    r'charset\s*=\s*["\x27]?([a-zA-Z0-9_-]+)',
    caseSensitive: false,
  );
  static final RegExp _metaCharsetPattern = RegExp(
    r'<meta[^>]+charset\s*=\s*["\x27]?\s*([a-zA-Z0-9_-]+)',
    caseSensitive: false,
  );

  /// Decodes HTML/JSON bytes with automatic UTF-8 / GBK / GB2312 detection.
  static String decodeResponseBytes(
    Uint8List bytes, {
    String contentTypeHeader = '',
    String? fallbackCharset,
  }) {
    if (bytes.isEmpty) return '';

    // UTF-8 BOM check.
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }

    String? declared = _headerCharsetPattern
        .firstMatch(contentTypeHeader)
        ?.group(1)
        ?.toLowerCase();

    if (declared == null) {
      final headLen = bytes.length < 2048 ? bytes.length : 2048;
      final asciiHead = latin1.decode(bytes.sublist(0, headLen));
      declared = _metaCharsetPattern
          .firstMatch(asciiHead)
          ?.group(1)
          ?.toLowerCase();
    }

    declared ??= fallbackCharset?.trim().toLowerCase();

    if (declared != null &&
        (declared.contains('gbk') ||
            declared.contains('gb2312') ||
            declared.contains('gb18030'))) {
      // Some sites declare charset=gbk in old templates while actually serving UTF-8!
      // Check strict UTF-8 validity first if non-ASCII bytes are present.
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        return decodeGbkBytes(bytes);
      }
    }

    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return decodeGbkBytes(bytes);
    }
  }

  static bool _looksLikeAntiBotChallenge(String body, HttpHeaders? headers) {
    final cfMitigated = headers?.value('cf-mitigated')?.toLowerCase() ?? '';
    if (cfMitigated.contains('challenge')) return true;
    if (body.length > 48 * 1024) return false;
    final lower = body.toLowerCase();
    if ((lower.contains('just a moment...') ||
            lower.contains('请稍候') ||
            lower.contains('正在验证您的浏览器')) &&
        (lower.contains('cf-chl') ||
            lower.contains('challenge-platform') ||
            lower.contains('turnstile'))) {
      return true;
    }
    if (lower.contains('g-recaptcha') &&
        lower.contains('<form') &&
        body.length < 12000) {
      return true;
    }
    return false;
  }
}

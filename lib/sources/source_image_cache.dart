import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../http_download.dart';
import 'network_url_safety.dart';

class EncryptedOrInvalidImageException implements Exception {
  const EncryptedOrInvalidImageException([
    this.message = '图片数据非标准格式（可能受防盗链拦截或经过站点脚本混淆加密）',
  ]);

  final String message;

  @override
  String toString() => message;
}

class SourceImageSpec {
  const SourceImageSpec({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;

  String toRawSpec() {
    if (headers.isEmpty) return url;
    return '$url,${jsonEncode({'headers': headers})}';
  }
}

/// Parses either a plain URL or a Legado URL with trailing JSON options such as
/// `https://img.example.com/1.jpg,{"headers":{"Referer":"https://example.com/"}}`.
SourceImageSpec? tryParseSourceImageSpec(
  String raw, {
  bool allowHttp = true,
}) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  for (final marker in const ['<!--source-image-->', '<!--image-->']) {
    if (text.startsWith(marker) &&
        text.endsWith(marker) &&
        text.length > marker.length * 2) {
      text = text.substring(marker.length, text.length - marker.length).trim();
      break;
    }
  }

  Map<String, String> parsedHeaders = const {};
  var urlPart = text;

  final jsonSplit = RegExp(r',\s*\{').firstMatch(text);
  if (jsonSplit != null) {
    final candidateUrl = text.substring(0, jsonSplit.start).trim();
    final candidateJson = text.substring(jsonSplit.start + 1).trim();
    try {
      final decoded = jsonDecode(candidateJson);
      if (decoded is Map) {
        urlPart = candidateUrl;
        final rawHeaders = decoded['headers'] ?? decoded['header'];
        if (rawHeaders is Map) {
          parsedHeaders = {
            for (final entry in rawHeaders.entries)
              if ('${entry.key}'.trim().isNotEmpty && entry.value != null)
                '${entry.key}'.trim(): '${entry.value}'.trim(),
          };
        } else if (rawHeaders is String && rawHeaders.trim().startsWith('{')) {
          final inner = jsonDecode(rawHeaders);
          if (inner is Map) {
            parsedHeaders = {
              for (final entry in inner.entries)
                if ('${entry.key}'.trim().isNotEmpty && entry.value != null)
                  '${entry.key}'.trim(): '${entry.value}'.trim(),
            };
          }
        }
      }
    } catch (_) {
      // Keep original text when `,` is simply part of a regular URL path/query.
    }
  }

  try {
    final uri = NetworkUrlSafety.parsePublicHttpUrl(
      urlPart,
      allowHttp: allowHttp,
    );
    return SourceImageSpec(
      url: uri.toString(),
      headers: Map.unmodifiable(parsedHeaders),
    );
  } on FormatException {
    return null;
  }
}

String encodeSourceImageParagraph(
  String url, {
  Map<String, String> headers = const {},
}) {
  final spec = SourceImageSpec(url: url.trim(), headers: headers);
  return '<!--source-image-->${spec.toRawSpec()}<!--source-image-->';
}

/// Verifies standard raster image magic bytes so HTML challenge pages or
/// XOR-encrypted manga buffers fail with an explicit, honest message.
bool isRecognizedImageBytes(Uint8List bytes) {
  if (bytes.length < 4) return false;
  // JPEG: FF D8 FF
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return true;
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return true;
  }
  // GIF87a / GIF89a
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // WebP: RIFF....WEBP
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  // BMP: BM
  if (bytes[0] == 0x42 && bytes[1] == 0x4d) return true;
  // ISO BMFF (AVIF / HEIF): ....ftyp
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    return true;
  }
  // ICO: 00 00 01 00
  if (bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x01 &&
      bytes[3] == 0x00) {
    return true;
  }
  return false;
}

class _HostLimiter {
  _HostLimiter(this.maxConcurrent);
  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= maxConcurrent) {
      final gate = Completer<void>();
      _waiters.addLast(gate);
      await gate.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      }
    }
  }
}

typedef SourceImageTransport =
    Future<Uint8List> Function(Uri url, Map<String, String> headers, int maxBytes);

/// Pure-Dart memory + disk image cache for online book covers, inline novel
/// illustrations, and manga episode pages with anti-hotlink header injection.
class SourceImageCache {
  SourceImageCache({
    Future<Directory> Function()? rootDirectoryProvider,
    SourceImageTransport? transport,
    this.enableDiskCache = true,
    this.maxMemoryBytes = 36 * 1024 * 1024,
    this.maxCoverBytes = 8 * 1024 * 1024,
    this.maxPageImageBytes = 15 * 1024 * 1024,
    this.maxConcurrentPerHost = 6,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _rootDirectoryProvider = rootDirectoryProvider,
       _transport = transport;

  static SourceImageCache shared = SourceImageCache();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  final Future<Directory> Function()? _rootDirectoryProvider;
  final SourceImageTransport? _transport;
  final bool enableDiskCache;
  final int maxMemoryBytes;
  final int maxCoverBytes;
  final int maxPageImageBytes;
  final int maxConcurrentPerHost;
  final Duration requestTimeout;

  /// Optional resolver supplied by the book-source layer to look up a book's
  /// cover URL and custom request headers (`User-Agent`, `Referer`, `Cookie`).
  ({String? coverUrl, Map<String, String> headers}) Function(int bookId)?
  bookContextResolver;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List>> _inFlight =
      <String, Future<Uint8List>>{};
  final Map<String, _HostLimiter> _hostLimiters = <String, _HostLimiter>{};
  final Map<String, DateTime> _failedCovers = <String, DateTime>{};
  static const Duration _failedCoverCooldown = Duration(seconds: 45);
  HttpClient? _sharedHttpClient;
  Directory? _resolvedRoot;
  int _memoryBytes = 0;

  int get memoryBytes => _memoryBytes;

  HttpClient _obtainHttpClient() {
    final existing = _sharedHttpClient;
    if (existing != null) return existing;
    final created = HttpClient()
      ..connectionTimeout = requestTimeout
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = maxConcurrentPerHost;
    _sharedHttpClient = created;
    return created;
  }

  Future<Directory?> _rootDir() async {
    if (!enableDiskCache) return null;
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    try {
      final base = _rootDirectoryProvider != null
          ? await _rootDirectoryProvider()
          : Directory(
              '${(await getApplicationSupportDirectory()).path}/source-images-v1',
            );
      await base.create(recursive: true);
      _resolvedRoot = base;
      return base;
    } catch (_) {
      return null;
    }
  }

  Uint8List? peek(String rawUrlOrSpec) {
    final spec = tryParseSourceImageSpec(rawUrlOrSpec);
    if (spec == null) return null;
    return _touchMemory(_cacheKeyForSpec(spec));
  }

  Uint8List? _touchMemory(String key) {
    final found = _memory.remove(key);
    if (found != null) {
      _memory[key] = found;
    }
    return found;
  }

  void _storeMemory(String key, Uint8List bytes) {
    final prev = _memory.remove(key);
    if (prev != null) _memoryBytes -= prev.length;
    if (bytes.length > maxMemoryBytes) return;
    final view = bytes.asUnmodifiableView();
    _memory[key] = view;
    _memoryBytes += view.length;
    while (_memoryBytes > maxMemoryBytes && _memory.isNotEmpty) {
      final evicted = _memory.remove(_memory.keys.first)!;
      _memoryBytes -= evicted.length;
    }
  }

  void clearMemory() {
    _memory.clear();
    _failedCovers.clear();
    _memoryBytes = 0;
  }

  String _cacheKeyForSpec(SourceImageSpec spec) {
    if (spec.headers.isEmpty) return spec.url;
    final sorted = spec.headers.keys.toList()..sort();
    final digestInput = StringBuffer(spec.url);
    for (final k in sorted) {
      digestInput
        ..write('\x00')
        ..write(k.toLowerCase())
        ..write('=')
        ..write(spec.headers[k]);
    }
    return sha256.convert(utf8.encode(digestInput.toString())).toString();
  }

  String _hashFileName(String key) =>
      '${sha256.convert(utf8.encode(key))}.img';

  Map<String, String> _buildHeaders(
    Uri targetUri, {
    int? bookId,
    String? referer,
    Map<String, String> baseHeaders = const {},
    Map<String, String> specHeaders = const {},
  }) {
    final bookCtx = bookId != null ? bookContextResolver?.call(bookId) : null;
    final merged = <String, String>{
      HttpHeaders.userAgentHeader: defaultUserAgent,
      HttpHeaders.acceptHeader:
          'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
    };

    void mergeCaseInsensitive(Map<String, String> incoming) {
      for (final entry in incoming.entries) {
        final key = entry.key.trim();
        final val = entry.value.trim();
        if (key.isEmpty || val.isEmpty) continue;
        merged.removeWhere((k, _) => k.toLowerCase() == key.toLowerCase());
        merged[key] = val;
      }
    }

    if (bookCtx != null) {
      mergeCaseInsensitive(bookCtx.headers);
    }
    mergeCaseInsensitive(baseHeaders);
    final hasExplicitReferer = merged.keys.any(
      (k) => k.toLowerCase() == 'referer',
    );
    if (!hasExplicitReferer) {
      final fallbackReferer = (referer != null && referer.trim().isNotEmpty)
          ? referer.trim()
          : '${targetUri.scheme}://${targetUri.authority}/';
      merged['Referer'] = fallbackReferer;
    }
    mergeCaseInsensitive(specHeaders);
    return merged;
  }

  Future<Uint8List> _downloadBytes(
    Uri initialUri,
    Map<String, String> headers, {
    required int maxBytes,
  }) async {
    final custom = _transport;
    if (custom != null) {
      await NetworkUrlSafety.ensureSafeDestination(initialUri);
      final bytes = await custom(initialUri, headers, maxBytes);
      if (!isRecognizedImageBytes(bytes)) {
        throw const EncryptedOrInvalidImageException();
      }
      return bytes;
    }

    await NetworkUrlSafety.ensureSafeDestination(initialUri);
    final hostKey = initialUri.host.toLowerCase();
    final limiter = _hostLimiters.putIfAbsent(
      hostKey,
      () => _HostLimiter(maxConcurrentPerHost),
    );
    return limiter.run(() async {
      final client = _obtainHttpClient();
      var currentUri = initialUri;
      for (var hop = 0; hop <= 4; hop++) {
        await NetworkUrlSafety.ensureSafeDestination(currentUri);
        final req = await client
            .getUrl(currentUri)
            .timeout(requestTimeout);
        req.followRedirects = false;
        try {
          req.maxRedirects = 0;
        } catch (_) {}
        headers.forEach(req.headers.set);
        final res = await req.close().timeout(requestTimeout);
        if (HttpDownload.redirectStatuses.contains(res.statusCode)) {
          final loc = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (loc == null || hop == 4) {
            throw const FormatException('图片地址重定向过多或无效');
          }
          currentUri = NetworkUrlSafety.parsePublicHttpUrl(
            currentUri.resolve(loc).toString(),
          );
          continue;
        }
        if (res.statusCode != HttpStatus.ok) {
          await res.drain<void>();
          if (res.statusCode == HttpStatus.forbidden ||
              res.statusCode == 429 ||
              res.statusCode == 503) {
            throw HttpException(
              '图源拒绝访问或触发限流（HTTP ${res.statusCode}）',
            );
          }
          throw HttpException('图片下载失败（HTTP ${res.statusCode}）');
        }
        final bytes = await HttpDownload.readBytes(
          res,
          maxBytes: maxBytes,
          streamTimeout: requestTimeout,
          onLimitExceeded: () =>
              const FormatException('图片体积超出安全上限'),
        );
        if (!isRecognizedImageBytes(bytes)) {
          throw const EncryptedOrInvalidImageException();
        }
        return bytes;
      }
      throw const FormatException('图片地址重定向过多');
    });
  }

  Future<void> _atomicWriteFile(File target, Uint8List bytes) async {
    try {
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      // Best-effort disk cache; memory result still succeeds.
    }
  }

  /// Loads a cover image for an online source book (`isSourceNovelId`), falling
  /// back to the local disk cover file when offline.
  Future<Uint8List> fetchCover(
    int bookId, {
    String? coverUrl,
    Map<String, String> extraHeaders = const {},
  }) async {
    final memKey = 'cover:$bookId:${coverUrl ?? ''}';
    final fromMem = _touchMemory(memKey);
    if (fromMem != null) return fromMem;

    final failedAt = _failedCovers[memKey];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < _failedCoverCooldown) {
        throw const HttpException('封面加载失败（短期冷却中）');
      }
      _failedCovers.remove(memKey);
    }

    final root = await _rootDir();
    final diskFile = root == null
        ? null
        : File('${root.path}/covers/c_$bookId.img');
    if (diskFile != null && await diskFile.exists()) {
      try {
        final diskBytes = await diskFile.readAsBytes();
        if (isRecognizedImageBytes(diskBytes)) {
          _storeMemory(memKey, diskBytes);
          return diskBytes.asUnmodifiableView();
        }
      } catch (_) {}
    }

    final ctx = bookContextResolver?.call(bookId);
    final effectiveCover = (coverUrl != null && coverUrl.trim().isNotEmpty)
        ? coverUrl.trim()
        : ctx?.coverUrl;
    if (effectiveCover == null || effectiveCover.isEmpty) {
      throw const FormatException('该书籍暂无可用封面地址');
    }

    final inflight = _inFlight[memKey];
    if (inflight != null) return inflight;

    final future = () async {
      final spec = tryParseSourceImageSpec(effectiveCover);
      if (spec == null) {
        throw const FormatException('封面地址格式不受支持');
      }
      final uri = Uri.parse(spec.url);
      final headers = _buildHeaders(
        uri,
        bookId: bookId,
        baseHeaders: extraHeaders,
        specHeaders: spec.headers,
      );
      final bytes = await _downloadBytes(
        uri,
        headers,
        maxBytes: maxCoverBytes,
      );
      if (diskFile != null) {
        await _atomicWriteFile(diskFile, bytes);
      }
      _failedCovers.remove(memKey);
      _storeMemory(memKey, bytes);
      return bytes.asUnmodifiableView();
    }();

    _inFlight[memKey] = future;
    try {
      return await future;
    } catch (_) {
      _failedCovers[memKey] = DateTime.now();
      if (_failedCovers.length > 512) {
        _failedCovers.remove(_failedCovers.keys.first);
      }
      rethrow;
    } finally {
      if (identical(_inFlight[memKey], future)) {
        _inFlight.remove(memKey);
      }
    }
  }

  /// Loads an inline novel illustration or manga page image, honoring source
  /// `Referer` / `Cookie` / `User-Agent` headers and optional offline pinning.
  Future<Uint8List> fetchImage(
    String rawUrlOrSpec, {
    int? bookId,
    String? referer,
    Map<String, String> baseHeaders = const {},
    bool pinOffline = false,
  }) async {
    final spec = tryParseSourceImageSpec(rawUrlOrSpec);
    if (spec == null) {
      throw const FormatException('图片地址格式无效或不受允许');
    }
    final key = _cacheKeyForSpec(spec);
    final fromMem = _touchMemory(key);
    if (fromMem != null && !pinOffline) return fromMem;

    final root = await _rootDir();
    final fileName = _hashFileName(key);
    final pinnedFile = (root != null && bookId != null)
        ? File('${root.path}/pinned/book_$bookId/$fileName')
        : null;
    final transientFile = root != null
        ? File('${root.path}/transient/$fileName')
        : null;

    if (pinnedFile != null && await pinnedFile.exists()) {
      try {
        final bytes = await pinnedFile.readAsBytes();
        if (isRecognizedImageBytes(bytes)) {
          _storeMemory(key, bytes);
          return bytes.asUnmodifiableView();
        }
      } catch (_) {}
    }

    if (transientFile != null && await transientFile.exists()) {
      try {
        final bytes = await transientFile.readAsBytes();
        if (isRecognizedImageBytes(bytes)) {
          if (pinOffline && pinnedFile != null) {
            await _atomicWriteFile(pinnedFile, bytes);
          }
          _storeMemory(key, bytes);
          return bytes.asUnmodifiableView();
        }
      } catch (_) {}
    }

    if (fromMem != null && pinOffline && pinnedFile != null) {
      await _atomicWriteFile(pinnedFile, fromMem);
      return fromMem;
    }

    final flightKey = 'img:${bookId ?? 0}:$key';
    final inflight = _inFlight[flightKey];
    if (inflight != null) {
      final bytes = await inflight;
      if (pinOffline && pinnedFile != null) {
        await _atomicWriteFile(pinnedFile, bytes);
      }
      return bytes;
    }

    final future = () async {
      final uri = Uri.parse(spec.url);
      final headers = _buildHeaders(
        uri,
        bookId: bookId,
        referer: referer,
        baseHeaders: baseHeaders,
        specHeaders: spec.headers,
      );
      final bytes = await _downloadBytes(
        uri,
        headers,
        maxBytes: maxPageImageBytes,
      );
      if (pinOffline && pinnedFile != null) {
        await _atomicWriteFile(pinnedFile, bytes);
      } else if (transientFile != null) {
        await _atomicWriteFile(transientFile, bytes);
      }
      _storeMemory(key, bytes);
      return bytes.asUnmodifiableView();
    }();

    _inFlight[flightKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[flightKey], future)) {
        _inFlight.remove(flightKey);
      }
    }
  }

  /// Creates a [ReaderIllustrationCache]-compatible request callback bound to
  /// [bookId] and optional [referer].
  Future<Uint8List> Function(String url) illustrationLoaderFor({
    required int bookId,
    String? referer,
    Map<String, String> baseHeaders = const {},
  }) =>
      (url) => fetchImage(
        url,
        bookId: bookId,
        referer: referer,
        baseHeaders: baseHeaders,
      );

  Future<void> deleteBookImages(int bookId) async {
    final root = await _rootDir();
    if (root == null) return;
    final pinnedDir = Directory('${root.path}/pinned/book_$bookId');
    if (await pinnedDir.exists()) {
      try {
        await pinnedDir.delete(recursive: true);
      } catch (_) {}
    }
    final coverFile = File('${root.path}/covers/c_$bookId.img');
    if (await coverFile.exists()) {
      try {
        await coverFile.delete();
      } catch (_) {}
    }
  }

  Future<void> clearTransientCache() async {
    clearMemory();
    final root = await _rootDir();
    if (root == null) return;
    final dir = Directory('${root.path}/transient');
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> clearAllImages() async {
    clearMemory();
    final root = await _rootDir();
    if (root == null) return;
    for (final sub in const ['transient', 'pinned', 'covers']) {
      final dir = Directory('${root.path}/$sub');
      if (await dir.exists()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}

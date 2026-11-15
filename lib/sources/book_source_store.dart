import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../gbk_codec.dart';
import '../http_download.dart';
import 'book_source.dart';
import 'network_url_safety.dart';

class SourceImportSummary {
  const SourceImportSummary({
    required this.added,
    required this.updated,
    required this.fullCount,
    required this.partialCount,
    required this.unsupportedCount,
    required this.invalidCount,
  });

  final int added;
  final int updated;
  final int fullCount;
  final int partialCount;
  final int unsupportedCount;
  final int invalidCount;

  int get totalImported => added + updated;

  String describe() {
    final parts = <String>[];
    if (added > 0) parts.add('新增 $added 条');
    if (updated > 0) parts.add('更新 $updated 条');
    if (parts.isEmpty) parts.add('未导入有效书源');
    final compat = <String>[];
    if (fullCount > 0) compat.add('完全兼容 $fullCount');
    if (partialCount > 0) compat.add('部分兼容 $partialCount');
    if (unsupportedCount > 0) compat.add('需脚本/暂不支持 $unsupportedCount');
    if (invalidCount > 0) compat.add('跳过无效项 $invalidCount');
    return compat.isEmpty
        ? parts.join('，')
        : '${parts.join('，')}（${compat.join(' · ')}）';
  }
}

/// Manages user-imported [BookSource] definitions, compatibility metadata,
/// master toggle state, and isolated secret headers (`Cookie`/`Authorization`).
class BookSourceStore extends ChangeNotifier {
  BookSourceStore({
    Future<Directory> Function()? directoryProvider,
    HttpClient Function()? httpClientFactory,
  }) : _directoryProvider = directoryProvider,
       _httpClientFactory = httpClientFactory;

  static BookSourceStore shared = BookSourceStore();

  static const int maxImportPayloadBytes = 8 * 1024 * 1024;

  final Future<Directory> Function()? _directoryProvider;
  final HttpClient Function()? _httpClientFactory;

  final List<BookSource> _sources = <BookSource>[];
  final Map<String, BookSource> _byId = <String, BookSource>{};
  final Map<String, Map<String, String>> _secretHeadersById =
      <String, Map<String, String>>{};

  Directory? _resolvedDir;
  bool _loaded = false;
  bool _onlineSourcesEnabled = true;
  Future<void> _writeChain = Future<void>.value();

  bool get isLoaded => _loaded;
  bool get onlineSourcesEnabled => _onlineSourcesEnabled;

  List<BookSource> get sources => List.unmodifiable(_sources);

  int get totalCount => _sources.length;
  int get enabledCount =>
      _sources.where((s) => s.enabled && s.compatibility.canEnable).length;

  /// `true` only when the master switch is on and at least one compatible
  /// book source is enabled. Pure-local users with 0 active sources see no
  /// online UI clutter anywhere in the app.
  bool get hasActiveSources => _onlineSourcesEnabled && enabledCount > 0;

  List<BookSource> get activeSources {
    if (!_onlineSourcesEnabled) return const [];
    final active = _sources
        .where((s) => s.enabled && s.compatibility.canEnable)
        .toList();
    active.sort((a, b) => b.weight.compareTo(a.weight));
    return active;
  }

  List<BookSource> get activeSearchSources =>
      activeSources.where((s) => s.canSearch).toList(growable: false);

  List<BookSource> get activeExploreSources =>
      activeSources.where((s) => s.canExplore).toList(growable: false);

  List<String> get groups {
    final set = <String>{};
    for (final src in _sources) {
      for (final part in src.group.split(RegExp(r'[,，;；\s]+'))) {
        final trimmed = part.trim();
        if (trimmed.isNotEmpty) set.add(trimmed);
      }
    }
    final list = set.toList()..sort();
    return list;
  }

  BookSource? byId(String id) => _byId[id];

  BookSource? findByBaseUrl(String baseUrl) {
    final normalized = _normalizeBaseKey(baseUrl);
    if (normalized.isEmpty) return null;
    for (final src in _sources) {
      if (_normalizeBaseKey(src.baseUrl) == normalized) {
        if (src.enabled && src.compatibility.canEnable) return src;
      }
    }
    for (final src in _sources) {
      if (_normalizeBaseKey(src.baseUrl) == normalized) return src;
    }
    return null;
  }

  static String _normalizeBaseKey(String raw) {
    var s = raw.trim().toLowerCase();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static bool _isSecretHeader(String key) {
    final lower = key.trim().toLowerCase();
    return lower == 'cookie' ||
        lower == 'authorization' ||
        lower == 'proxy-authorization' ||
        lower == 'x-api-key' ||
        lower == 'token';
  }

  /// Returns merged non-secret + secret headers for [source].
  Map<String, String> effectiveHeadersFor(BookSource source) {
    final secrets = _secretHeadersById[source.id];
    if (secrets == null || secrets.isEmpty) return source.headers;
    final merged = <String, String>{...source.headers};
    for (final entry in secrets.entries) {
      merged.removeWhere(
        (k, _) => k.toLowerCase() == entry.key.toLowerCase(),
      );
      merged[entry.key] = entry.value;
    }
    return Map.unmodifiable(merged);
  }

  /// Returns a copy of [source] hydrated with its secret headers for execution.
  BookSource hydrated(BookSource source) {
    final merged = effectiveHeadersFor(source);
    if (identical(merged, source.headers)) return source;
    return source.copyWith(headers: merged);
  }

  Map<String, String> secretHeadersFor(String sourceId) =>
      Map.unmodifiable(_secretHeadersById[sourceId] ?? const {});

  Future<Directory> _dir() async {
    final existing = _resolvedDir;
    if (existing != null) return existing;
    final dir = _directoryProvider != null
        ? await _directoryProvider()
        : Directory(
            '${(await getApplicationSupportDirectory()).path}/sources',
          );
    await dir.create(recursive: true);
    _resolvedDir = dir;
    return dir;
  }

  Future<void> load() async {
    final dir = await _dir();
    final mainFile = File('${dir.path}/book_sources_v1.json');
    final secretFile = File('${dir.path}/book_source_secrets_v1.json');

    _sources.clear();
    _byId.clear();
    _secretHeadersById.clear();
    _onlineSourcesEnabled = true;

    if (await secretFile.exists()) {
      try {
        final raw = jsonDecode(await secretFile.readAsString());
        if (raw is Map) {
          for (final entry in raw.entries) {
            if (entry.value is Map) {
              final map = <String, String>{
                for (final h in (entry.value as Map).entries)
                  if ('${h.key}'.trim().isNotEmpty && h.value != null)
                    '${h.key}'.trim(): '${h.value}'.trim(),
              };
              if (map.isNotEmpty) {
                _secretHeadersById['${entry.key}'] = map;
              }
            }
          }
        }
      } catch (_) {}
    }

    if (await mainFile.exists()) {
      try {
        final decoded = jsonDecode(await mainFile.readAsString());
        if (decoded is Map) {
          _onlineSourcesEnabled = decoded['onlineSourcesEnabled'] != false;
          final rawList = decoded['sources'];
          if (rawList is List) {
            for (final item in rawList) {
              if (item is! Map) continue;
              final src = BookSource.fromAnyMap({
                for (final e in item.entries) '${e.key}': e.value,
              });
              if (src != null && !_byId.containsKey(src.id)) {
                _sources.add(src);
                _byId[src.id] = src;
              }
            }
          }
        }
      } catch (_) {}
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() {
    _writeChain = _writeChain.catchError((Object _) {}).then((_) async {
      final dir = await _dir();
      final mainFile = File('${dir.path}/book_sources_v1.json');
      final secretFile = File('${dir.path}/book_source_secrets_v1.json');

      final payload = jsonEncode({
        'version': 1,
        'onlineSourcesEnabled': _onlineSourcesEnabled,
        'sources': [
          for (final s in _sources) s.toJson(stripSensitiveHeaders: true),
        ],
      });
      await _atomicWriteString(mainFile, payload);

      if (_secretHeadersById.isEmpty) {
        if (await secretFile.exists()) {
          try {
            await secretFile.delete();
          } catch (_) {}
        }
      } else {
        await _atomicWriteString(secretFile, jsonEncode(_secretHeadersById));
      }
    });
    return _writeChain;
  }

  static Future<void> _atomicWriteString(File target, String content) async {
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target.path);
  }

  void _splitAndStoreSource(BookSource incoming, {BookSource? previous}) {
    final publicHeaders = <String, String>{};
    final incomingSecrets = <String, String>{
      ...?_secretHeadersById[incoming.id],
    };
    for (final entry in incoming.headers.entries) {
      if (_isSecretHeader(entry.key)) {
        incomingSecrets[entry.key] = entry.value;
      } else {
        publicHeaders[entry.key] = entry.value;
      }
    }
    if (incomingSecrets.isEmpty) {
      _secretHeadersById.remove(incoming.id);
    } else {
      _secretHeadersById[incoming.id] = incomingSecrets;
    }

    final clean = incoming.copyWith(
      enabled: previous != null ? previous.enabled : incoming.enabled,
      headers: Map.unmodifiable(publicHeaders),
    );
    final existingIdx = _sources.indexWhere((s) => s.id == clean.id);
    if (existingIdx >= 0) {
      _sources[existingIdx] = clean;
    } else {
      _sources.add(clean);
    }
    _byId[clean.id] = clean;
  }

  /// Imports book sources from a raw JSON string (single object, Legado array,
  /// or Shuyu backup wrapper).
  Future<SourceImportSummary> importFromJsonText(
    String rawJson, {
    String importOrigin = '',
  }) async {
    final parsed = parseBookSourcesJson(rawJson, importOrigin: importOrigin);
    var added = 0;
    var updated = 0;

    for (final src in parsed.sources) {
      final prev = _byId[src.id];
      if (prev == null) {
        added++;
      } else {
        updated++;
      }
      _splitAndStoreSource(src, previous: prev);
    }

    if (added > 0 || updated > 0) {
      await _persist();
      notifyListeners();
    }

    return SourceImportSummary(
      added: added,
      updated: updated,
      fullCount: parsed.fullCount,
      partialCount: parsed.partialCount,
      unsupportedCount: parsed.unsupportedCount,
      invalidCount: parsed.invalidCount,
    );
  }

  /// Imports book sources from an HTTP(S) URL, automatically unwrapping
  /// Coolapk/Zhihu/QQ jump links and `legado://import/bookSource?src=...` links.
  Future<SourceImportSummary> importFromUrl(String rawInput) async {
    final unwrapped = NetworkUrlSafety.unwrapImportSourceUrl(rawInput);
    if (unwrapped.isEmpty) {
      throw const FormatException('请输入有效的书源订阅网址');
    }
    final initialUri = await NetworkUrlSafety.ensureSafeDestination(
      NetworkUrlSafety.parsePublicHttpUrl(unwrapped, allowHttp: true),
    );

    final client = (_httpClientFactory != null ? _httpClientFactory() : HttpClient())
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      var currentUri = initialUri;
      for (var hop = 0; hop <= 5; hop++) {
        await NetworkUrlSafety.ensureSafeDestination(currentUri);
        final request = await client
            .getUrl(currentUri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        try {
          request.maxRedirects = 0;
        } catch (_) {}
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/json, text/plain, */*',
        );
        final response = await request
            .close()
            .timeout(const Duration(seconds: 20));
        if (HttpDownload.redirectStatuses.contains(response.statusCode)) {
          final loc = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (loc == null || hop == 5) {
            throw const FormatException('书源地址重定向过多或无效');
          }
          final nextRaw = NetworkUrlSafety.unwrapImportSourceUrl(
            currentUri.resolve(loc).toString(),
          );
          currentUri = NetworkUrlSafety.parsePublicHttpUrl(
            nextRaw,
            allowHttp: true,
          );
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException('下载书源失败（HTTP ${response.statusCode}）');
        }
        final bytes = await HttpDownload.readBytes(
          response,
          maxBytes: maxImportPayloadBytes,
          streamTimeout: const Duration(seconds: 25),
          onLimitExceeded: () => const FormatException('书源文件超过 8 MB 安全上限'),
        );
        final text = _decodeTextBytes(bytes);
        return importFromJsonText(text, importOrigin: currentUri.toString());
      }
      throw const FormatException('书源地址重定向过多');
    } finally {
      client.close(force: true);
    }
  }

  static String _decodeTextBytes(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return decodeGbkBytes(bytes);
    }
  }

  Future<void> setOnlineSourcesEnabled(bool value) async {
    if (_onlineSourcesEnabled == value) return;
    _onlineSourcesEnabled = value;
    await _persist();
    notifyListeners();
  }

  Future<void> setSourceEnabled(String id, bool enabled) async {
    final existing = _byId[id];
    if (existing == null) return;
    if (enabled && !existing.compatibility.canEnable) return;
    final updated = existing.copyWith(enabled: enabled);
    if (updated.enabled == existing.enabled) return;
    final idx = _sources.indexWhere((s) => s.id == id);
    if (idx >= 0) _sources[idx] = updated;
    _byId[id] = updated;
    await _persist();
    notifyListeners();
  }

  Future<void> setAllCompatibleEnabled(bool enabled) async {
    var changed = false;
    for (var i = 0; i < _sources.length; i++) {
      final src = _sources[i];
      if (!src.compatibility.canEnable) continue;
      if (src.enabled != enabled) {
        final next = src.copyWith(enabled: enabled);
        _sources[i] = next;
        _byId[next.id] = next;
        changed = true;
      }
    }
    if (changed) {
      await _persist();
      notifyListeners();
    }
  }

  /// Updates custom headers (`User-Agent`, `Referer`, `Cookie`, etc.) for [id].
  Future<void> updateCustomHeaders(
    String id, {
    String? userAgent,
    String? referer,
    String? cookie,
  }) async {
    final existing = _byId[id];
    if (existing == null) return;
    final publicHeaders = <String, String>{...existing.headers};
    publicHeaders.removeWhere(
      (k, _) =>
          k.toLowerCase() == 'user-agent' || k.toLowerCase() == 'referer',
    );
    if (userAgent != null && userAgent.trim().isNotEmpty) {
      publicHeaders['User-Agent'] = userAgent.trim();
    }
    if (referer != null && referer.trim().isNotEmpty) {
      publicHeaders['Referer'] = referer.trim();
    }

    final secrets = <String, String>{...?_secretHeadersById[id]};
    secrets.removeWhere((k, _) => k.toLowerCase() == 'cookie');
    if (cookie != null && cookie.trim().isNotEmpty) {
      secrets['Cookie'] = cookie.trim();
    }
    if (secrets.isEmpty) {
      _secretHeadersById.remove(id);
    } else {
      _secretHeadersById[id] = secrets;
    }

    final next = existing.copyWith(headers: Map.unmodifiable(publicHeaders));
    final idx = _sources.indexWhere((s) => s.id == id);
    if (idx >= 0) _sources[idx] = next;
    _byId[id] = next;
    await _persist();
    notifyListeners();
  }

  Future<void> removeSource(String id) async {
    if (_byId.remove(id) == null) return;
    _sources.removeWhere((s) => s.id == id);
    _secretHeadersById.remove(id);
    await _persist();
    notifyListeners();
  }

  Future<int> removeUnsupportedSources() async {
    final toRemove = _sources
        .where((s) => !s.compatibility.canEnable)
        .map((s) => s.id)
        .toList();
    if (toRemove.isEmpty) return 0;
    for (final id in toRemove) {
      _byId.remove(id);
      _secretHeadersById.remove(id);
    }
    _sources.removeWhere((s) => !s.compatibility.canEnable);
    await _persist();
    notifyListeners();
    return toRemove.length;
  }

  Future<void> clearAll() async {
    if (_sources.isEmpty && _secretHeadersById.isEmpty) return;
    _sources.clear();
    _byId.clear();
    _secretHeadersById.clear();
    await _persist();
    notifyListeners();
  }

  /// Exports sanitized JSON (all `Cookie`/`Authorization` secrets stripped).
  String exportSanitizedJson({Iterable<String>? onlyIds}) {
    final allow = onlyIds?.toSet();
    final items = [
      for (final s in _sources)
        if (allow == null || allow.contains(s.id))
          s.toJson(stripSensitiveHeaders: true),
    ];
    return const JsonEncoder.withIndent('  ').convert(items);
  }

  List<Map<String, Object?>> exportSanitizedList() => [
    for (final s in _sources) s.toJson(stripSensitiveHeaders: true),
  ];
}

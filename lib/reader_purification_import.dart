import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'http_download.dart';

/// Downloads JSON without relying on the server's (often incorrect) MIME type.
class ReaderPurificationDownload {
  static const maxBytes = 2 * 1024 * 1024;
  static const timeout = Duration(seconds: 20);
  static const _maxRedirects = 3;

  @visibleForTesting
  static bool allowLoopbackHttpForTesting = false;

  static bool _isAllowedScheme(Uri uri, {required bool allowHttp}) {
    if (uri.isScheme('https')) return true;
    if (allowHttp && uri.isScheme('http')) return true;
    if (allowLoopbackHttpForTesting &&
        uri.isScheme('http') &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1')) {
      return true;
    }
    return false;
  }

  static Uri parseUrl(String input, {bool allowHttp = false}) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !_isAllowedScheme(uri, allowHttp: allowHttp) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw FormatException(
        allowHttp ? '请输入有效的 HTTP 或 HTTPS 规则链接' : '请输入有效的 HTTPS 安全规则链接',
      );
    }
    return uri;
  }

  static Future<String> fetch(String input, {bool allowHttp = false}) async {
    final uri = parseUrl(input, allowHttp: allowHttp);
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final response = await HttpDownload.getResponse(
          client,
          uri,
          headers: const {
            HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
          },
          maxRedirects: _maxRedirects,
          requestTimeout: timeout,
          responseTimeout: timeout,
          resolveRedirect: (current, location, _) {
            if (location == null) {
              throw const FormatException('规则链接重定向过多或无效');
            }
            final resolved = current.resolve(location);
            if (current.isScheme('https') && resolved.isScheme('http')) {
              throw const FormatException('不允许从 HTTPS 重定向降级到 HTTP');
            }
            return parseUrl(resolved.toString(), allowHttp: allowHttp);
          },
          onTooManyRedirects: () => const FormatException('规则链接重定向过多或无效'),
        );
        final bytes = await HttpDownload.readBytes(
          response,
          maxBytes: maxBytes,
          streamTimeout: timeout,
          onLimitExceeded: () =>
              const FormatException('规则文件超过 2 MB，请使用较小的规则集'),
        );
        return utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

class ReaderPurificationSaveException implements Exception {
  const ReaderPurificationSaveException();

  @override
  String toString() => '规则保存失败，请重试';
}

class ReaderPurificationImportResult {
  ReaderPurificationImportResult({
    required this.imported,
    required this.disabled,
    required this.duplicates,
    required this.invalid,
    this.enabledCount = 0,
    Iterable<String> importedRuleIds = const [],
    Iterable<String> enableableRuleIds = const [],
  }) : importedRuleIds = List.unmodifiable(importedRuleIds),
       enableableRuleIds = List.unmodifiable(enableableRuleIds);

  final int imported;
  // Incompatible/unsafe rules, distinct from compatible rules awaiting consent.
  final int disabled;
  final int duplicates;
  final int invalid;
  final int enabledCount;
  final List<String> importedRuleIds;
  final List<String> enableableRuleIds;

  String get message => [
    imported > 0
        ? '已保存 $imported 条规则（${enabledCount == 0 ? "尚未启用" : "已启用 $enabledCount 条"}）'
        : '没有新增规则',
    if (disabled > 0) '其中 $disabled 条暂不兼容或存在风险，强制停用',
    if (duplicates > 0) '跳过 $duplicates 条重复规则',
    if (invalid > 0) '跳过 $invalid 条无效数据',
  ].join('；');
}

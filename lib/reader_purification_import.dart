import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Downloads JSON without relying on the server's (often incorrect) MIME type.
class ReaderPurificationDownload {
  static const maxBytes = 2 * 1024 * 1024;
  static const timeout = Duration(seconds: 20);
  static const _maxRedirects = 3;

  @visibleForTesting
  static bool allowLoopbackHttpForTesting = false;

  static bool _isAllowedScheme(Uri uri) {
    if (uri.isScheme('https')) return true;
    if (allowLoopbackHttpForTesting &&
        uri.isScheme('http') &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1')) {
      return true;
    }
    return false;
  }

  static Uri parseUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !_isAllowedScheme(uri) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('请输入有效的 HTTPS 安全规则链接');
    }
    return uri;
  }

  static Future<String> fetch(String input) async {
    final uri = parseUrl(input);
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _read(client, uri).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _read(HttpClient client, Uri uri) async {
    var current = uri;
    for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      request.maxRedirects = 0;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/plain, */*',
      );
      final response = await request.close();
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirect == _maxRedirects) {
          throw const FormatException('规则链接重定向过多或无效');
        }
        current = parseUrl(current.resolve(location).toString());
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('下载失败（HTTP ${response.statusCode}）');
      }
      if (response.contentLength > maxBytes) {
        await response.drain<void>();
        throw const FormatException('规则文件超过 2 MB，请使用较小的规则集');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('规则文件超过 2 MB，请使用较小的规则集');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
    }
    throw const FormatException('规则链接重定向过多');
  }
}

class ReaderPurificationImportResult {
  const ReaderPurificationImportResult({
    required this.imported,
    required this.disabled,
    required this.duplicates,
    required this.invalid,
  });

  final int imported;
  final int disabled;
  final int duplicates;
  final int invalid;

  String get message => [
    imported > 0 ? '已导入 $imported 条规则（外部规则默认关闭，请确认后开启）' : '没有可导入的新规则',
    if (disabled > 0) '其中 $disabled 条暂不兼容或存在风险，已停用',
    if (duplicates > 0) '跳过 $duplicates 条重复规则',
    if (invalid > 0) '跳过 $invalid 条无效数据',
  ].join('；');
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Downloads JSON without relying on the server's (often incorrect) MIME type.
class ReaderPurificationDownload {
  static const maxBytes = 2 * 1024 * 1024;
  static const timeout = Duration(seconds: 20);

  static Uri parseUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的 HTTP 或 HTTPS 规则链接');
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
    final request = await client.getUrl(uri);
    request.maxRedirects = 3;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('下载失败（HTTP ${response.statusCode}）');
    }
    if (response.contentLength > maxBytes) {
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
    imported > 0 ? '已导入 $imported 条规则' : '没有可导入的新规则',
    if (disabled > 0) '其中 $disabled 条暂不兼容，已停用',
    if (duplicates > 0) '跳过 $duplicates 条重复规则',
    if (invalid > 0) '跳过 $invalid 条无效数据',
  ].join('；');
}

import 'dart:async';
import 'dart:io';
import 'font_catalog.dart';
import 'http_download.dart';
export 'font_catalog.dart';

class FontDownloadProgress {
  const FontDownloadProgress(
    this.received,
    this.total, {
    this.validating = false,
  });
  final int received, total;
  final bool validating;
  double get fraction =>
      total <= 0 ? 0.0 : (received / total).clamp(0.0, 1.0);
  int get percent => (fraction * 100).floor();
}

class FontDownloadCancelled implements Exception {
  const FontDownloadCancelled();
}

class FontDownloadCancellation {
  bool cancelled = false;
  HttpClient? _client;
  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }

  void check() {
    if (cancelled) throw const FontDownloadCancelled();
  }
}

/// Explicit, user-initiated downloads only. No account or reading data is sent.
/// Fixed font releases, streamed to a temporary file. No app Worker quota,
/// account credential or paid font API is used.
class FontDownloadClient {
  FontDownloadClient({
    List<Uri>? sources,
    HttpClient Function()? clientFactory,
  }) : sources =
           sources ?? downloadableFonts.first.sourceUrls.map(Uri.parse).toList(),
       _clientFactory = clientFactory ?? HttpClient.new;
  final List<Uri> sources;
  final HttpClient Function() _clientFactory;

  static bool _isPrivateOrLoopbackHost(String rawHost) {
    final host = rawHost.trim().toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost') || host == '::1') {
      return true;
    }
    final addr = InternetAddress.tryParse(host);
    if (addr == null) return false;
    if (addr.isLoopback || addr.isLinkLocal) return true;
    if (addr.type == InternetAddressType.IPv4) {
      final b = addr.rawAddress;
      if (b[0] == 0 || b[0] == 10 || b[0] == 127) return true;
      if (b[0] == 169 && b[1] == 254) return true;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
      if (b[0] == 192 && b[1] == 168) return true;
      if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
    } else if (addr.type == InternetAddressType.IPv6) {
      final b = addr.rawAddress;
      if ((b[0] & 0xfe) == 0xfc) return true;
    }
    return false;
  }

  static void _validateFontUrl(Uri url) {
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        _isPrivateOrLoopbackHost(url.host)) {
      throw const FormatException('字体下载地址不安全或不受支持');
    }
  }

  Future<void> download(
    File target, {
    required FontDownloadCancellation cancellation,
    required void Function(FontDownloadProgress) onProgress,
    int expectedBytes = sourceHanFontBytes,
    String? expectedSha256,
    List<Uri>? from,
  }) async {
    final endpoints = from ?? sources;
    if (expectedBytes <= 0) {
      throw const FormatException('字体预期大小无效');
    }
    for (final (index, source) in endpoints.indexed) {
      cancellation.check();
      final client = _clientFactory()
        ..connectionTimeout = const Duration(seconds: 12);
      cancellation._client = client;
      try {
        final response = await HttpDownload.getResponse(
          client,
          source,
          headers: const {HttpHeaders.acceptEncodingHeader: 'identity'},
          maxRedirects: 5,
          requestTimeout: const Duration(seconds: 20),
          responseTimeout: const Duration(seconds: 20),
          checkCancelled: cancellation.check,
          validateUrl: _validateFontUrl,
          resolveRedirect: (current, location, _) {
            if (location == null || location.trim().isEmpty) {
              throw const FormatException('字体下载重定向无效');
            }
            final resolved = current.resolve(location.trim());
            _validateFontUrl(resolved);
            return resolved;
          },
          onStatusError: (_) => const FormatException('字体下载暂不可用，请稍后重试'),
          onTooManyRedirects: () => const FormatException('字体下载链接重定向过多'),
        );
        var lastPercent = -1;
        onProgress(FontDownloadProgress(0, expectedBytes));
        await HttpDownload.streamToFile(
          response,
          target,
          expectedBytes: expectedBytes,
          expectedSha256: expectedSha256?.toLowerCase(),
          deleteOnFailure: true,
          streamTimeout: const Duration(seconds: 30),
          checkCancelled: cancellation.check,
          onContentLengthMismatch: () =>
              const FormatException('字体下载内容不完整，请重试'),
          onLimitExceeded: () => const FormatException('字体下载内容超出预期，请重试'),
          onIncomplete: () => const FormatException('字体下载中断，请重试'),
          onDigestMismatch: () =>
              const FormatException('字体文件完整性校验失败，请重试'),
          onProgress: (received, _) {
            final progress = FontDownloadProgress(received, expectedBytes);
            if (progress.percent != lastPercent) {
              lastPercent = progress.percent;
              onProgress(progress);
            }
          },
        );
        return;
      } on FileSystemException {
        rethrow;
      } catch (e) {
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
        cancellation.check();
        if (index == endpoints.length - 1) {
          if (e is FormatException &&
              (e.message.contains('不安全') || e.message.contains('完整性校验'))) {
            rethrow;
          }
          throw const FormatException('字体下载未完成，请检查网络后重试');
        }
      } finally {
        client.close(force: true);
        cancellation._client = null;
      }
    }
    throw const FormatException('字体下载暂不可用，请稍后重试');
  }
}

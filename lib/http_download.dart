import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class _Sha256Sink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Shared low-level HTTP download and bounded response streaming primitives
/// used by purification rule imports, font downloads, GitHub APK updates,
/// and cloud book/backup transfers.
class HttpDownload {
  const HttpDownload._();

  static const Set<int> redirectStatuses = {301, 302, 303, 307, 308};

  static int? _safeContentLength(HttpClientResponse response) {
    try {
      final length = response.contentLength;
      return length < 0 ? null : length;
    } catch (_) {
      return null;
    }
  }

  /// Resolves a `GET` request with explicit redirect validation.
  static Future<HttpClientResponse> getResponse(
    HttpClient client,
    Uri initialUrl, {
    Map<String, String> headers = const {},
    int maxRedirects = 5,
    Duration requestTimeout = const Duration(seconds: 20),
    Duration responseTimeout = const Duration(seconds: 20),
    void Function()? checkCancelled,
    void Function(Uri url)? validateUrl,
    Uri Function(Uri current, String? location, int hop)? resolveRedirect,
    Object Function(int statusCode)? onStatusError,
    Object Function()? onTooManyRedirects,
  }) async {
    var current = initialUrl;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      checkCancelled?.call();
      validateUrl?.call(current);
      final request = await client.getUrl(current).timeout(requestTimeout);
      request.followRedirects = false;
      try {
        request.maxRedirects = 0;
      } catch (_) {}
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(responseTimeout);
      if (redirectStatuses.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (hop == maxRedirects || resolveRedirect == null) {
          throw onTooManyRedirects?.call() ??
              const FormatException('下载链接重定向过多或无效');
        }
        current = resolveRedirect(current, location, hop);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        try {
          await response.drain<void>();
        } catch (_) {}
        throw onStatusError?.call(response.statusCode) ??
            HttpException('下载失败（HTTP ${response.statusCode}）');
      }
      return response;
    }
    throw onTooManyRedirects?.call() ?? const FormatException('下载链接重定向过多');
  }

  /// Reads a response body into memory with a strict byte ceiling.
  static Future<Uint8List> readBytes(
    HttpClientResponse response, {
    required int maxBytes,
    Duration streamTimeout = const Duration(seconds: 25),
    void Function()? checkCancelled,
    Object Function()? onLimitExceeded,
  }) async {
    final contentLength = _safeContentLength(response);
    if (contentLength != null && contentLength > maxBytes) {
      try {
        await response.listen((_) {}).cancel();
      } catch (_) {}
      throw onLimitExceeded?.call() ??
          FormatException('下载文件超过大小限制（$maxBytes 字节）');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(streamTimeout)) {
      checkCancelled?.call();
      if (builder.length + chunk.length > maxBytes) {
        throw onLimitExceeded?.call() ??
            FormatException('下载文件超过大小限制（$maxBytes 字节）');
      }
      builder.add(chunk);
    }
    checkCancelled?.call();
    return builder.takeBytes();
  }

  /// Streams a response body to [target] with optional byte ceiling, exact
  /// expected byte length, SHA-256 verification, and progress reporting.
  static Future<void> streamToFile(
    HttpClientResponse response,
    File target, {
    int? maxBytes,
    int? expectedBytes,
    bool requireNonEmpty = false,
    String? expectedSha256,
    Duration streamTimeout = const Duration(seconds: 30),
    void Function()? checkCancelled,
    void Function(int received, int? total)? onProgress,
    bool flushEachChunk = false,
    bool deleteOnFailure = false,
    Object Function()? onContentLengthMismatch,
    Object Function()? onLimitExceeded,
    Object Function()? onIncomplete,
    Object Function()? onDigestMismatch,
  }) async {
    final total = _safeContentLength(response);
    if (expectedBytes != null && total != null && total != expectedBytes) {
      try {
        await response.listen((_) {}).cancel();
      } catch (_) {}
      throw onContentLengthMismatch?.call() ??
          const FormatException('下载内容长度不匹配，请重试');
    }
    final ceiling = maxBytes ?? expectedBytes;
    if (ceiling != null && total != null && total > ceiling) {
      try {
        await response.listen((_) {}).cancel();
      } catch (_) {}
      throw onLimitExceeded?.call() ?? const FormatException('下载内容超出大小上限');
    }
    final sink = target.openWrite();
    var received = 0;
    final digestSink = _Sha256Sink();
    final hashing = expectedSha256 == null
        ? null
        : sha256.startChunkedConversion(digestSink);
    try {
      await for (final chunk in response.timeout(streamTimeout)) {
        checkCancelled?.call();
        received += chunk.length;
        if (ceiling != null && received > ceiling) {
          throw onLimitExceeded?.call() ?? const FormatException('下载内容超出大小上限');
        }
        hashing?.add(chunk);
        sink.add(chunk);
        if (flushEachChunk) await sink.flush();
        onProgress?.call(received, expectedBytes ?? total);
      }
      hashing?.close();
      await sink.flush();
      checkCancelled?.call();
      if ((requireNonEmpty && received == 0) ||
          (expectedBytes != null && received != expectedBytes) ||
          (expectedBytes == null && total != null && received != total)) {
        throw onIncomplete?.call() ?? const FormatException('下载中断或不完整，请重试');
      }
      if (expectedSha256 != null &&
          digestSink.value.toString() != expectedSha256) {
        throw onDigestMismatch?.call() ??
            const FormatException('文件完整性校验失败，请重新下载');
      }
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (deleteOnFailure) {
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }
}

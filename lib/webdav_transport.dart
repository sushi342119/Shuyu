import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'cloud_sources.dart';

/// Shared WebDAV transport used by both [WebDavBookClient] (cloud book library
/// browsing/import) and [WebDavBackupClient] (encrypted/HTTPS library backups).
class WebDavTransport {
  WebDavTransport({
    required this.endpoint,
    required this.username,
    required this.password,
    this.allowHttp = false,
    CloudHttp? http,
  }) : http = http ?? CloudHttp();

  final Uri endpoint;
  final String username;
  final String password;
  final bool allowHttp;
  final CloudHttp http;

  static const String propfindBody =
      '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>';

  static Map<String, String> basicAuthHeaders(
    Uri uri,
    Uri base,
    String username,
    String password,
  ) => {
    'User-Agent': 'Wenku8/0.3 WebDAV',
    if (CloudHttp.sameOrigin(uri, base) &&
        (username.isNotEmpty || password.isNotEmpty))
      'Authorization':
          'Basic ${base64Encode(utf8.encode('$username:$password'))}',
  };

  static Iterable<(XmlElement responseNode, String href)> parseMultistatusHrefs(
    String xmlText,
  ) sync* {
    final document = XmlDocument.parse(xmlText);
    if (document.rootElement.name.local != 'multistatus') {
      throw const CloudSourceFailure('该地址不是 WebDAV 服务，请检查 /dav/ 路径');
    }
    for (final node in document.rootElement.childElements.where(
      (e) => e.name.local == 'response',
    )) {
      final href = node.childElements
          .where((e) => e.name.local == 'href')
          .firstOrNull
          ?.innerText;
      if (href != null) yield (node, href);
    }
  }

  /// Resolves and validates that [id] lies strictly within [endpoint].
  Uri resolveResource(String id) {
    final uri = Uri.parse(id).normalizePath();
    final base = endpoint.normalizePath();
    final segments = uri.pathSegments;
    final prefix = base.pathSegments.where((e) => e.isNotEmpty).toList();
    if (!CloudHttp.sameOrigin(uri, base) ||
        uri.hasQuery ||
        uri.hasFragment ||
        segments.any(
          (s) => s == '..' || s == '.' || s.contains('/') || s.contains('\\'),
        ) ||
        segments.length < prefix.length ||
        !listEquals(segments.take(prefix.length).toList(), prefix)) {
      throw const CloudSourceFailure('文件地址不在已配置的 WebDAV 目录内');
    }
    return uri;
  }

  Map<String, String> headersFor(Uri uri, [Map<String, String>? extra]) => {
    ...basicAuthHeaders(uri, endpoint, username, password),
    ...?extra,
  };

  Future<Iterable<(XmlElement responseNode, String href)>> propfind(
    Uri uri, {
    bool redirects = false,
    int maxBytes = 4 * 1024 * 1024,
  }) async {
    final res = await http.request(
      'PROPFIND',
      uri,
      allowHttp: allowHttp,
      redirects: redirects,
      headers: (u) => headersFor(
        u,
        const {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      ),
      body: utf8.encode(propfindBody),
    );
    final xml = utf8.decode(
      await http.bytes(res, limit: maxBytes),
      allowMalformed: true,
    );
    return parseMultistatusHrefs(xml).toList(growable: false);
  }

  Future<void> mkcol(
    Uri uri, {
    bool redirects = true,
    String? authenticationMessage,
  }) async {
    final res = await http.request(
      'MKCOL',
      uri,
      allowHttp: allowHttp,
      redirects: redirects,
      headers: headersFor,
      allowedStatuses: const {200, 201, 301, 405},
      authenticationMessage: authenticationMessage,
    );
    await res.drain<void>();
  }

  Future<void> putBytes(
    Uri uri,
    List<int> body, {
    String contentType = 'application/octet-stream',
    bool redirects = true,
  }) async {
    final res = await http.request(
      'PUT',
      uri,
      allowHttp: allowHttp,
      redirects: redirects,
      headers: (u) => headersFor(u, {'Content-Type': contentType}),
      body: body,
    );
    await res.drain<void>();
  }

  Future<void> delete(Uri uri, {bool redirects = true}) async {
    final res = await http.request(
      'DELETE',
      uri,
      allowHttp: allowHttp,
      redirects: redirects,
      headers: headersFor,
      allowedStatuses: const {200, 202, 204, 404},
    );
    await res.drain<void>();
  }

  Future<Uint8List> getBytes(
    Uri uri, {
    bool redirects = true,
    int maxBytes = 4 * 1024 * 1024,
  }) async {
    final res = await http.request(
      'GET',
      uri,
      allowHttp: allowHttp,
      redirects: redirects,
      headers: headersFor,
    );
    return http.bytes(res, limit: maxBytes);
  }

  Future<void> downloadToFile(
    Uri uri,
    File target, {
    String? bookName,
    bool redirects = true,
    void Function(int, int?)? onProgress,
  }) async {
    final res = await http.request(
      'GET',
      uri,
      allowHttp: allowHttp,
      redirects: redirects,
      headers: headersFor,
    );
    await http.save(res, target, bookName: bookName, onProgress: onProgress);
  }

  void close() => http.close();
}

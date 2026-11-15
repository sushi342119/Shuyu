import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Centralized URL normalization, jump-link unwrapping, and SSRF guard for
/// user-imported book sources, cover images, inline illustrations, and manga.
abstract final class NetworkUrlSafety {
  /// Allows `127.0.0.1` / `localhost` / `::1` ONLY inside automated tests.
  @visibleForTesting
  static bool allowLoopbackForTesting = false;

  /// Optional DNS resolver override for deterministic SSRF unit tests.
  @visibleForTesting
  static Future<List<InternetAddress>> Function(String host)? debugDnsLookup;

  /// Runs [computation] inside a background [Isolate], forwarding the current
  /// loopback test flag when running under automated tests.
  static Future<T> runInIsolate<T>(T Function() computation) {
    final allowLoopback = allowLoopbackForTesting;
    return Isolate.run(() {
      allowLoopbackForTesting = allowLoopback;
      return computation();
    });
  }

  static const int defaultMaxUrlLength = 2048;

  static final RegExp _embeddedUrlPattern = RegExp(
    r'(?:legado|yuedu|shuyu)://[^\s"<>，。！？；：（）【】「」『』《》、\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]+|https?://[^\s"<>，。！？；：（）【】「」『』《》、\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]+',
    caseSensitive: false,
  );

  static final RegExp _numericOrHexHostPattern = RegExp(
    r'^(?:0x[0-9a-f]+|\d+|0[0-7]+(?:\.[0-7]+){1,3})$',
    caseSensitive: false,
  );

  /// Extracts a clean HTTP(S) URL from user-pasted text, unwrapping common
  /// redirect jump links (e.g. `coolapk.com/link?url=...`) and deep-link
  /// wrappers (`legado://import/bookSource?src=...`, `yuedu://...`).
  static String unwrapImportSourceUrl(String rawInput) {
    var candidate = rawInput.trim();
    if (candidate.isEmpty) return '';

    // If the user pasted a share paragraph containing a URL, extract the URL.
    if (!candidate.startsWith('[') && !candidate.startsWith('{')) {
      final direct = Uri.tryParse(candidate);
      if (direct == null || !direct.hasScheme) {
        final match = _embeddedUrlPattern.firstMatch(candidate);
        if (match != null) {
          candidate = match.group(0)!.replaceAll(
            RegExp(r'[，。！？；：）”’\]】),.!;]+$'),
            '',
          );
        }
      }
    }

    for (var hop = 0; hop < 4; hop++) {
      final uri = Uri.tryParse(candidate);
      if (uri == null || !uri.hasScheme) break;
      final scheme = uri.scheme.toLowerCase();

      if (scheme == 'legado' || scheme == 'yuedu' || scheme == 'shuyu') {
        final nested =
            uri.queryParameters['src'] ??
            uri.queryParameters['url'] ??
            uri.queryParameters['target'];
        if (nested != null && nested.trim().isNotEmpty) {
          candidate = nested.trim();
          continue;
        }
        break;
      }

      if (scheme == 'http' || scheme == 'https') {
        final host = uri.host.toLowerCase();
        final path = uri.path.toLowerCase();
        final isJumpHost =
            host == 'coolapk.com' ||
            host.endsWith('.coolapk.com') ||
            host == 'link.zhihu.com' ||
            host == 'c.pc.qq.com' ||
            host == 't.cn' ||
            path == '/link' ||
            path.endsWith('/link.html');
        if (isJumpHost) {
          final nested =
              uri.queryParameters['url'] ??
              uri.queryParameters['target'] ??
              uri.queryParameters['pfurl'] ??
              uri.queryParameters['src'];
          if (nested != null && nested.trim().isNotEmpty) {
            final nestedUri = Uri.tryParse(nested.trim());
            if (nestedUri != null &&
                (nestedUri.isScheme('http') || nestedUri.isScheme('https'))) {
              candidate = nestedUri.toString();
              continue;
            }
          }
        }
      }
      break;
    }

    return candidate;
  }

  static bool _isLoopbackHostLiteral(String cleanHost) =>
      cleanHost == 'localhost' ||
      cleanHost == '127.0.0.1' ||
      cleanHost == '::1';

  /// Returns `true` when [addr] is loopback, private LAN, link-local, CGNAT,
  /// cloud metadata, benchmark/Fake-IP, unspecified, multicast, or reserved.
  ///
  /// Used for validating literal IP hosts in URLs (`http://198.18.x.x/...`).
  static bool isBlockedAddress(InternetAddress addr) =>
      _checkAddressBlocked(addr, allowTunFakeIp: false);

  /// Returns `true` when a DNS-resolved [addr] for a validated public domain
  /// points to loopback, unspecified, private LAN, link-local/cloud metadata,
  /// or multicast space.
  ///
  /// Permits virtual TUN VPN Fake-IP / CGNAT / IPv6 ULA ranges (`198.18/15`,
  /// `100.64/10`, `fc00::/7`) used by Android VPN clients (Clash, Mihomo,
  /// Sing-box, v2rayNG, Surge, Tailscale) when resolving public domain names.
  static bool isBlockedResolvedAddress(InternetAddress addr) =>
      _checkAddressBlocked(addr, allowTunFakeIp: true);

  static bool _isLoopbackOrUnspecifiedAddress(InternetAddress addr) {
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      return raw[0] == 0 || raw[0] == 127;
    }
    if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
      var prefixZero15 = true;
      for (var i = 0; i < 15; i++) {
        if (raw[i] != 0) {
          prefixZero15 = false;
          break;
        }
      }
      if (prefixZero15 && (raw[15] == 0 || raw[15] == 1)) return true;
      var prefixZero10 = true;
      for (var i = 0; i < 10; i++) {
        if (raw[i] != 0) {
          prefixZero10 = false;
          break;
        }
      }
      if (prefixZero10 &&
          ((raw[10] == 0xff && raw[11] == 0xff) ||
              (raw[10] == 0 && raw[11] == 0))) {
        return raw[12] == 0 || raw[12] == 127;
      }
    }
    return false;
  }

  static bool _checkAddressBlocked(
    InternetAddress addr, {
    required bool allowTunFakeIp,
  }) {
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4) {
      if (raw.length != 4) return true;
      return _isBlockedIpv4Bytes(
        raw[0],
        raw[1],
        raw[2],
        raw[3],
        allowTunFakeIp: allowTunFakeIp,
      );
    }
    if (addr.type == InternetAddressType.IPv6) {
      if (raw.length != 16) return true;
      // Unspecified `::`
      var allZero = true;
      for (var i = 0; i < 16; i++) {
        if (raw[i] != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero) return true;

      // Loopback `::1`
      var prefixZero15 = true;
      for (var i = 0; i < 15; i++) {
        if (raw[i] != 0) {
          prefixZero15 = false;
          break;
        }
      }
      if (prefixZero15 && raw[15] == 1) {
        return !allowLoopbackForTesting;
      }

      // IPv4-mapped `::ffff:a.b.c.d` or IPv4-compatible `::a.b.c.d`
      var prefixZero10 = true;
      for (var i = 0; i < 10; i++) {
        if (raw[i] != 0) {
          prefixZero10 = false;
          break;
        }
      }
      if (prefixZero10 &&
          ((raw[10] == 0xff && raw[11] == 0xff) ||
              (raw[10] == 0 && raw[11] == 0))) {
        return _isBlockedIpv4Bytes(
          raw[12],
          raw[13],
          raw[14],
          raw[15],
          allowTunFakeIp: allowTunFakeIp,
        );
      }

      // NAT64 well-known prefix `64:ff9b::/96`
      if (raw[0] == 0x00 &&
          raw[1] == 0x64 &&
          raw[2] == 0xff &&
          raw[3] == 0x9b) {
        return _isBlockedIpv4Bytes(
          raw[12],
          raw[13],
          raw[14],
          raw[15],
          allowTunFakeIp: allowTunFakeIp,
        );
      }

      // Unique local `fc00::/7` (used as IPv6 Fake-IP pool `fc00::/18` by TUN VPNs)
      if ((raw[0] & 0xfe) == 0xfc) return !allowTunFakeIp;
      // Link-local `fe80::/10`
      if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;
      // Multicast `ff00::/8`
      if (raw[0] == 0xff) return true;
      return false;
    }
    return true;
  }

  static bool _isBlockedIpv4Bytes(
    int b0,
    int b1,
    int b2,
    int b3, {
    required bool allowTunFakeIp,
  }) {
    // 0.0.0.0/8 (this-network)
    if (b0 == 0) return true;
    // Loopback 127.0.0.0/8
    if (b0 == 127) return !allowLoopbackForTesting;
    // RFC1918 class A (first octet 10)
    if (b0 == 10) return true;
    // CGNAT / TUN shared space 100.64.0.0/10
    if (b0 == 100 && (b1 & 0xc0) == 64) return !allowTunFakeIp;
    // Link-local / cloud metadata 169.254.0.0/16
    if (b0 == 169 && b1 == 254) return true;
    // RFC1918 class B 172.16.0.0/12
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
    // IETF protocol assignments 192.0.0.0/24 & documentation 192.0.2.0/24
    if (b0 == 192 && b1 == 0 && (b2 == 0 || b2 == 2)) return true;
    // RFC1918 class C (192.168/16)
    if (b0 == 192 && b1 == 168) return true;
    // Benchmark / TUN Fake-IP 198.18.0.0/15
    if (b0 == 198 && (b1 == 18 || b1 == 19)) return !allowTunFakeIp;
    // Multicast & reserved 224.0.0.0/3 (includes 255.255.255.255)
    if (b0 >= 224) return true;
    return false;
  }

  static String _normalizeHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']') && host.length > 2) {
      host = host.substring(1, host.length - 1);
    }
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  /// Checks whether [rawHost] is a blocked IP literal, local domain suffix,
  /// or obfuscated integer/octal/hex IP representation.
  static bool isBlockedHostLiteral(String rawHost) {
    final host = _normalizeHost(rawHost);
    if (host.isEmpty) return true;
    if (allowLoopbackForTesting && _isLoopbackHostLiteral(host)) {
      return false;
    }
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.home.arpa') ||
        host.endsWith('.lan')) {
      return true;
    }
    // Zone-scoped IPv6 literal (`fe80::1%eth0`)
    if (host.contains('%')) return true;

    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      return isBlockedAddress(parsed);
    }

    // Reject non-standard numeric/hex/octal IPv4 encodings (`2130706433`, `0x7f000001`).
    if (_numericOrHexHostPattern.hasMatch(host)) {
      return true;
    }
    return false;
  }

  /// Synchronously checks whether [uri] is a syntactically safe public HTTP(S)
  /// URL without credentials or blocked host literals.
  static bool isSafePublicHttpUri(
    Uri? uri, {
    bool allowHttp = true,
    int maxLength = defaultMaxUrlLength,
  }) {
    if (uri == null) return false;
    final text = uri.toString();
    if (text.isEmpty || text.length > maxLength) return false;
    final scheme = uri.scheme.toLowerCase();
    final schemeOk = scheme == 'https' || (allowHttp && scheme == 'http');
    if (!schemeOk) return false;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
    if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) return false;
    if (isBlockedHostLiteral(uri.host)) return false;
    return true;
  }

  /// Parses and validates [rawUrl], throwing [FormatException] if disallowed.
  static Uri parsePublicHttpUrl(
    String rawUrl, {
    bool allowHttp = true,
    int maxLength = defaultMaxUrlLength,
    bool stripFragment = true,
  }) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty || trimmed.length > maxLength) {
      throw const FormatException('网址为空或超出长度限制');
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      throw const FormatException('网址格式无效');
    }
    final cleaned = stripFragment && parsed.hasFragment
        ? parsed.removeFragment()
        : parsed;
    if (!isSafePublicHttpUri(
      cleaned,
      allowHttp: allowHttp,
      maxLength: maxLength,
    )) {
      throw FormatException(
        allowHttp ? '不支持访问内网、本地或非 HTTP(S) 地址' : '仅支持安全的公网 HTTPS 地址',
      );
    }
    return cleaned;
  }

  static bool get _hasConfiguredSystemProxy {
    try {
      final httpProxy =
          Platform.environment['HTTP_PROXY'] ??
          Platform.environment['http_proxy'] ??
          '';
      final httpsProxy =
          Platform.environment['HTTPS_PROXY'] ??
          Platform.environment['https_proxy'] ??
          '';
      return httpProxy.trim().isNotEmpty || httpsProxy.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Validates both the URI syntax/host literal and DNS resolution results so
  /// DNS rebinding to private/loopback addresses is rejected before connecting.
  static Future<Uri> ensureSafeDestination(
    Uri uri, {
    bool allowHttp = true,
    int maxLength = defaultMaxUrlLength,
    Duration dnsTimeout = const Duration(seconds: 6),
  }) async {
    final checked = parsePublicHttpUrl(
      uri.toString(),
      allowHttp: allowHttp,
      maxLength: maxLength,
    );
    final cleanHost = _normalizeHost(checked.host);
    if (allowLoopbackForTesting && _isLoopbackHostLiteral(cleanHost)) {
      return checked;
    }
    if (InternetAddress.tryParse(cleanHost) != null) {
      return checked;
    }

    final customLookup = debugDnsLookup;
    if (customLookup != null) {
      final addresses = await customLookup(cleanHost).timeout(dnsTimeout);
      _validateResolvedAddresses(addresses);
      return checked;
    }

    try {
      final addresses = await InternetAddress.lookup(
        cleanHost,
      ).timeout(dnsTimeout);
      _validateResolvedAddresses(addresses);
    } on SocketException {
      // When outbound traffic is mediated by an explicit HTTP(S) proxy without
      // direct DNS resolution, host-literal checks still apply and the proxy
      // handles upstream resolution. On normal Android devices without a proxy,
      // surface the DNS failure directly.
      if (!_hasConfiguredSystemProxy) rethrow;
    }
    return checked;
  }

  static void _validateResolvedAddresses(List<InternetAddress> addresses) {
    if (addresses.isEmpty) {
      throw const FormatException('目标域名未能解析出有效地址');
    }
    if (addresses.any(isBlockedResolvedAddress)) {
      if (!allowLoopbackForTesting &&
          addresses.every(_isLoopbackOrUnspecifiedAddress)) {
        throw const FormatException(
          '域名解析返回了空地址或本机回环（可能被当前网络 DNS 污染拦截，请检查 VPN 分流规则或切换其他书源）',
        );
      }
      throw const FormatException('目标域名解析到了受限制的局域网或本机地址');
    }
  }
}

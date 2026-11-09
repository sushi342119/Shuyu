import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_state.dart';
import 'local_library.dart';

class LanBookshelfServer extends ChangeNotifier {
  LanBookshelfServer({
    required this.local,
    required this.state,
  });

  final LocalLibraryStore local;
  final LibraryState state;

  HttpServer? _server;
  String _hostIp = '127.0.0.1';
  int _port = 0;
  String _accessCode = '';
  int _uploadedCount = 0;
  String? _lastError;
  final List<String> _recentUploads = <String>[];

  bool get isRunning => _server != null;
  String get baseUrl => isRunning ? 'http://$_hostIp:$_port' : '';
  String get url =>
      isRunning ? 'http://$_hostIp:$_port/?token=$_accessCode' : '';
  String get accessCode => _accessCode;
  int get port => _port;
  int get uploadedCount => _uploadedCount;
  String? get lastError => _lastError;
  List<String> get recentUploads => List.unmodifiable(_recentUploads);

  static String _generateAccessCode() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buffer.write(random.nextInt(10));
    }
    return buffer.toString();
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Future<String> resolveLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
      for (final iface in interfaces) {
        if (iface.addresses.isNotEmpty) {
          return iface.addresses.first.address;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('LanBookshelfServer.resolveLanIp failed: $e');
    }
    return '127.0.0.1';
  }

  Future<void> start({
    int preferredPort = 8899,
    InternetAddress? bindAddress,
  }) async {
    if (_server != null) return;
    _lastError = null;
    try {
      _hostIp = await resolveLanIp();
      _accessCode = _generateAccessCode();
      final preferredAddress =
          bindAddress ??
          (_hostIp != '127.0.0.1' ? InternetAddress.tryParse(_hostIp) : null) ??
          InternetAddress.anyIPv4;
      HttpServer server;
      try {
        server = await HttpServer.bind(preferredAddress, preferredPort);
      } catch (_) {
        server = await HttpServer.bind(
          bindAddress ?? InternetAddress.anyIPv4,
          0,
        );
      }
      _server = server;
      _port = server.port;
      server.listen(
        _handleRequest,
        onError: (Object error) {
          if (kDebugMode) debugPrint('LanBookshelfServer stream error: $error');
          _lastError = '局域网服务连接异常';
          notifyListeners();
        },
      );
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('LanBookshelfServer.start failed: $e');
      _accessCode = '';
      _lastError = '启动局域网服务失败，请检查无线网络连接';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    _accessCode = '';
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (e) {
        if (kDebugMode) debugPrint('LanBookshelfServer.stop failed: $e');
      }
    }
    notifyListeners();
  }

  bool _isCrossOrigin(HttpRequest request) {
    final fetchSite = request.headers.value('sec-fetch-site')?.toLowerCase();
    if (fetchSite != null &&
        fetchSite != 'same-origin' &&
        fetchSite != 'none') {
      return true;
    }
    final origin = request.headers.value('origin');
    if (origin != null) {
      final parsed = Uri.tryParse(origin);
      final host = request.headers.value(HttpHeaders.hostHeader);
      if (parsed == null || host == null || parsed.authority != host) {
        return true;
      }
    }
    return false;
  }

  bool _isAuthorized(HttpRequest request) {
    if (_accessCode.isEmpty) return false;
    final candidate = request.headers.value('x-shuyu-token') ?? '';
    return _constantTimeEquals(candidate.trim(), _accessCode);
  }

  static String _sanitizeUploadFileName(String rawName) {
    String decoded;
    try {
      decoded = Uri.decodeComponent(rawName).trim();
    } on ArgumentError {
      decoded = rawName.trim();
    }
    final baseName = decoded.split(RegExp(r'[/\\]')).last.trim();
    final cleaned = baseName.replaceAll(
      RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'),
      '_',
    );
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'uploaded_book.txt';
    }
    return cleaned;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('X-Frame-Options', 'DENY');
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('Cross-Origin-Resource-Policy', 'same-origin');

    final path = request.uri.path;
    try {
      if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'",
        );
        response.headers.contentType = ContentType.html;
        response.write(_webAppHtml);
        await response.close();
        return;
      }

      if (_isCrossOrigin(request)) {
        _writeJson(
          response,
          {'ok': false, 'error': '已拒绝跨站请求'},
          status: HttpStatus.forbidden,
        );
        await response.close();
        return;
      }

      if (!_isAuthorized(request)) {
        _writeJson(
          response,
          {'ok': false, 'error': '未授权访问，请输入手机端显示的 6 位访问口令'},
          status: HttpStatus.unauthorized,
        );
        await response.close();
        return;
      }

      if (request.method == 'GET' && path == '/api/books') {
        final list = [
          for (final book in local.books)
            {
              'id': book.id,
              'title': book.displayTitle,
              'author': book.displayAuthor,
              'fileName': book.fileName,
              'kind': book.kind.name,
              'chapterCount': book.chapters.length,
              'wordCount': book.wordCount ?? 0,
            },
        ];
        _writeJson(response, {'ok': true, 'books': list});
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/book') {
        final id = int.tryParse(request.uri.queryParameters['id'] ?? '') ?? 0;
        final chapterIdx =
            int.tryParse(request.uri.queryParameters['chapter'] ?? '0') ?? 0;
        final book = local.bookFor(id);
        if (book == null) {
          _writeJson(
            response,
            {'ok': false, 'error': '未找到该书籍'},
            status: HttpStatus.notFound,
          );
          await response.close();
          return;
        }
        final novel = local.toNovel(book);
        final safeIdx = novel.chapters.isEmpty
            ? 0
            : chapterIdx.clamp(0, novel.chapters.length - 1);
        var content = '';
        var chapterTitle = '';
        if (novel.chapters.isNotEmpty && book.kind == LocalBookKind.txt) {
          chapterTitle = novel.chapters[safeIdx].title;
          content = await local.chapterContent(
            novel.id,
            novel.chapters[safeIdx],
          );
        } else if (book.kind == LocalBookKind.epub) {
          chapterTitle = novel.chapters.isNotEmpty
              ? novel.chapters[safeIdx].title
              : book.displayTitle;
          final epubData = await local.epubChapter(book.id, safeIdx);
          content = epubData.blocks
              .map((b) => b.text ?? '')
              .where((s) => s.trim().isNotEmpty)
              .join('\n\n');
        }
        _writeJson(response, {
          'ok': true,
          'id': book.id,
          'title': book.displayTitle,
          'author': book.displayAuthor,
          'chapter': safeIdx,
          'chapterTitle': chapterTitle,
          'totalChapters': novel.chapters.length,
          'content': content,
          'chapters': [
            for (var i = 0; i < novel.chapters.length; i++)
              {'index': i, 'title': novel.chapters[i].title},
          ],
        });
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/upload') {
        if (request.contentLength > localTextMaxSourceBytes) {
          _writeJson(
            response,
            {'ok': false, 'error': '上传文件超过 256 MiB 限制'},
            status: HttpStatus.requestEntityTooLarge,
          );
          await response.close();
          return;
        }
        final rawName =
            request.uri.queryParameters['name'] ??
            request.headers.value('x-file-name') ??
            'uploaded_book.txt';
        final safeName = _sanitizeUploadFileName(rawName);
        final tempDir = await Directory.systemTemp.createTemp('shuyu_wifi_');
        try {
          final tempFile = File('${tempDir.path}/$safeName');
          final sink = tempFile.openWrite();
          var totalBytes = 0;
          try {
            await for (final chunk in request) {
              totalBytes += chunk.length;
              if (totalBytes > localTextMaxSourceBytes) {
                throw const FormatException('上传文件超过 256 MiB 限制');
              }
              sink.add(chunk);
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (totalBytes == 0) {
            _writeJson(
              response,
              {'ok': false, 'error': '上传文件内容为空'},
              status: HttpStatus.badRequest,
            );
            await response.close();
            return;
          }
          if (safeName.toLowerCase().endsWith('.zip')) {
            final res = await local.importCloudBatch(safeName, tempFile.path);
            await state.addShelfBooks([
              for (final b in local.books)
                if (!state.contains(b.id)) local.toNovel(b),
            ]);
            _uploadedCount += res.imported;
            _recentUploads.insert(0, '$safeName (${res.imported} 本)');
          } else {
            final novel = await local.importCloudFile(safeName, tempFile.path);
            await state.addShelfBooks([novel]);
            _uploadedCount++;
            _recentUploads.insert(0, novel.title);
          }
          if (_recentUploads.length > 10) {
            _recentUploads.removeRange(10, _recentUploads.length);
          }
          notifyListeners();
          _writeJson(response, {'ok': true, 'name': safeName});
        } finally {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
        await response.close();
        return;
      }

      _writeJson(
        response,
        {'ok': false, 'error': '未知接口'},
        status: HttpStatus.notFound,
      );
      await response.close();
    } on FormatException catch (error) {
      _writeJson(
        response,
        {'ok': false, 'error': error.message},
        status: HttpStatus.badRequest,
      );
      await response.close();
    } catch (_) {
      _writeJson(
        response,
        {'ok': false, 'error': '请求处理失败'},
        status: HttpStatus.internalServerError,
      );
      await response.close();
    }
  }

  void _writeJson(
    HttpResponse response,
    Map<String, Object?> data, {
    int status = HttpStatus.ok,
  }) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

Future<void> showLanBookshelfSheet({
  required BuildContext context,
  required LocalLibraryStore local,
  required LibraryState state,
  bool reduceMotion = false,
}) async {
  final server = LanBookshelfServer(local: local, state: state);
  await server.start();
  if (!context.mounted) {
    await server.stop();
    server.dispose();
    return;
  }
  try {
    await showJellySheet<void>(
      context: context,
      reduceMotion: reduceMotion,
      builder: (ctx) => _LanBookshelfSheet(server: server),
    );
  } finally {
    await server.stop();
    server.dispose();
  }
}

class _LanBookshelfSheet extends StatelessWidget {
  const _LanBookshelfSheet({required this.server});
  final LanBookshelfServer server;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final running = server.isRunning;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ArchiveIcon(CupertinoIcons.wifi,
                    color: running ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Wi-Fi 传书与网页书架',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    key: const ValueKey('lan-server-toggle'),
                    value: running,
                    onChanged: (v) {
                      if (v) {
                        server.start();
                      } else {
                        server.stop();
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '确保电脑或另一台设备与本机连接同一 Wi-Fi，扫码或打开下方带口令地址即可上传书籍或在线阅读：',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(
                    ArchiveDesign.panelRadius,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            running ? server.url : '服务已暂停',
                            key: const ValueKey('lan-server-url'),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: running
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (running)
                          GlassTextButton(
                            key: const ValueKey('lan-server-copy-url'),
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: server.url),
                              );
                              if (context.mounted) {
                                showNovelFeedback(context, '已复制带口令的局域网地址');
                              }
                            },
                            child: const Text('复制地址'),
                          ),
                      ],
                    ),
                    if (running) ...[
                      const SizedBox(height: 6),
                      Text(
                        '本次会话访问口令：${server.accessCode}',
                        key: const ValueKey('lan-server-pin'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: _LanQrCodeView(
                          key: const ValueKey('lan-server-qr'),
                          data: server.url,
                          size: 148,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '扫码自动填充 X-Shuyu-Token 口令',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (server.lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  server.lastError!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '本次已接收 ${server.uploadedCount} 本书籍 · 关闭此面板将自动停止局域网服务并销毁口令',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              if (server.recentUploads.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '最近接收：${server.recentUploads.join('、')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LanQrCodeView extends StatelessWidget {
  const _LanQrCodeView({
    super.key,
    required this.data,
    this.size = 148,
  });

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final matrix = _QrCodeMatrix.encode(data);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        painter: _QrCodePainter(matrix),
        size: Size.square(size - 20),
      ),
    );
  }
}

class _QrCodePainter extends CustomPainter {
  const _QrCodePainter(this.matrix);
  final List<List<bool>> matrix;

  @override
  void paint(Canvas canvas, Size size) {
    final count = matrix.length;
    if (count == 0) return;
    final cell = size.width / count;
    final paint = Paint()
      ..color = const Color(0xFF1A1612)
      ..style = PaintingStyle.fill;
    for (var r = 0; r < count; r++) {
      for (var c = 0; c < count; c++) {
        if (matrix[r][c]) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.35, cell + 0.35),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrCodePainter oldDelegate) =>
      oldDelegate.matrix != matrix;
}

/// Compact ISO/IEC 18004 QR Code (Byte mode, Level L, Versions 1–5) encoder.
class _QrCodeMatrix {
  static const _versions = <(int dataBytes, int ecBytes, List<int> align)>[
    (19, 7, []),
    (34, 10, [6, 18]),
    (55, 15, [6, 22]),
    (80, 20, [6, 26]),
    (108, 26, [6, 30]),
  ];

  static List<List<bool>> encode(String text) {
    final payload = utf8.encode(text);
    var version = 1;
    while (version <= _versions.length &&
        payload.length + 2 > _versions[version - 1].$1) {
      version++;
    }
    if (version > _versions.length) {
      version = _versions.length;
    }
    final spec = _versions[version - 1];
    final dataCap = spec.$1;
    final ecCount = spec.$2;
    final trimmed = payload.length + 2 > dataCap
        ? payload.sublist(0, dataCap - 2)
        : payload;

    final bits = <int>[];
    void pushBits(int val, int len) {
      for (var i = len - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    pushBits(0x4, 4); // Byte mode
    pushBits(trimmed.length, 8);
    for (final b in trimmed) {
      pushBits(b, 8);
    }
    final maxBits = dataCap * 8;
    for (var i = 0; i < 4 && bits.length < maxBits; i++) {
      bits.add(0);
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final dataCodewords = <int>[
      for (var i = 0; i < bits.length; i += 8)
        (bits[i] << 7) |
            (bits[i + 1] << 6) |
            (bits[i + 2] << 5) |
            (bits[i + 3] << 4) |
            (bits[i + 4] << 3) |
            (bits[i + 5] << 2) |
            (bits[i + 6] << 1) |
            bits[i + 7],
    ];
    var padIndex = 0;
    while (dataCodewords.length < dataCap) {
      dataCodewords.add(padIndex.isEven ? 0xEC : 0x11);
      padIndex++;
    }

    final ecCodewords = _reedSolomonRemainder(dataCodewords, ecCount);
    final allCodewords = <int>[...dataCodewords, ...ecCodewords];

    final size = 17 + version * 4;
    final modules = List.generate(size, (_) => List<bool>.filled(size, false));
    final isFunc = List.generate(size, (_) => List<bool>.filled(size, false));

    void setFunc(int r, int c, bool dark) {
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      modules[r][c] = dark;
      isFunc[r][c] = true;
    }

    void drawFinder(int top, int left) {
      for (var dr = -1; dr <= 7; dr++) {
        for (var dc = -1; dc <= 7; dc++) {
          final inBounds = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
          final onBorder = dr == 0 || dr == 6 || dc == 0 || dc == 6;
          final inCenter = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
          setFunc(top + dr, left + dc, inBounds && (onBorder || inCenter));
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(0, size - 7);
    drawFinder(size - 7, 0);

    for (var i = 8; i < size - 8; i++) {
      setFunc(6, i, i.isEven);
      setFunc(i, 6, i.isEven);
    }

    final align = spec.$3;
    if (align.length >= 2) {
      final center = align.last;
      for (var dr = -2; dr <= 2; dr++) {
        for (var dc = -2; dc <= 2; dc++) {
          final dist = max(dr.abs(), dc.abs());
          setFunc(center + dr, center + dc, dist != 1);
        }
      }
    }

    // Reserve format info & dark module
    for (var i = 0; i <= 8; i++) {
      if (i != 6) {
        isFunc[8][i] = true;
        isFunc[i][8] = true;
      }
    }
    for (var i = 0; i < 8; i++) {
      isFunc[8][size - 1 - i] = true;
      if (i < 7) isFunc[size - 1 - i][8] = true;
    }
    setFunc(4 * version + 9, 8, true);

    var bitIdx = 0;
    final totalBits = allCodewords.length * 8;
    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        final r = upward ? (size - 1 - vert) : vert;
        for (var j = 0; j < 2; j++) {
          final c = right - j;
          if (!isFunc[r][c]) {
            var dark = false;
            if (bitIdx < totalBits) {
              dark =
                  ((allCodewords[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1) != 0;
              bitIdx++;
            }
            // Mask 0: (r + c) % 2 == 0
            if ((r + c).isEven) dark = !dark;
            modules[r][c] = dark;
          }
        }
      }
      upward = !upward;
    }

    // Format info for Level L (01) + Mask 0 (000) -> 0x77C4
    const formatBits = 0x77C4;
    bool fmtBit(int i) => ((formatBits >> i) & 1) != 0;
    for (var i = 0; i <= 5; i++) {
      modules[8][i] = fmtBit(i);
    }
    modules[8][7] = fmtBit(6);
    modules[8][8] = fmtBit(7);
    modules[7][8] = fmtBit(8);
    for (var i = 9; i < 15; i++) {
      modules[14 - i][8] = fmtBit(i);
    }
    for (var i = 0; i < 7; i++) {
      modules[size - 1 - i][8] = fmtBit(i);
    }
    for (var i = 7; i < 15; i++) {
      modules[8][size - 15 + i] = fmtBit(i);
    }

    return modules;
  }

  static int _gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }

  static List<int> _reedSolomonRemainder(List<int> data, int degree) {
    var gen = <int>[1];
    var root = 1;
    for (var i = 0; i < degree; i++) {
      final next = List<int>.filled(gen.length + 1, 0);
      for (var j = 0; j < gen.length; j++) {
        next[j] ^= gen[j];
        next[j + 1] ^= _gfMul(gen[j], root);
      }
      gen = next;
      root = _gfMul(root, 0x02);
    }
    final rem = List<int>.filled(degree, 0);
    for (final b in data) {
      final factor = b ^ rem[0];
      for (var i = 0; i < degree - 1; i++) {
        rem[i] = rem[i + 1] ^ _gfMul(gen[i + 1], factor);
      }
      rem[degree - 1] = _gfMul(gen[degree], factor);
    }
    return rem;
  }
}

const _webAppHtml = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>书屿 · Wi-Fi 传书与网页书架</title>
<style>
  :root {
    --bg: #F6F1E7;
    --card: #FCF9F2;
    --ink: #2C261F;
    --muted: #7A6F63;
    --accent: #8C6239;
    --border: #E5DCCB;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Noto Serif CJK SC", sans-serif;
    background: var(--bg);
    color: var(--ink);
    line-height: 1.6;
  }
  header {
    padding: 16px 24px;
    border-bottom: 1px solid var(--border);
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
    background: var(--card);
  }
  header h1 { margin: 0; font-size: 20px; font-weight: 600; }
  .auth-bar { display: flex; align-items: center; gap: 8px; }
  .auth-bar input {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 6px 10px;
    font-size: 13px;
    width: 120px;
    background: var(--bg);
    color: var(--ink);
  }
  main { max-width: 960px; margin: 24px auto; padding: 0 16px; }
  .dropzone {
    border: 2px dashed var(--accent);
    border-radius: 14px;
    background: var(--card);
    padding: 28px 20px;
    text-align: center;
    cursor: pointer;
    transition: background .2s;
  }
  .dropzone:hover { background: #F3ECE0; }
  .books {
    margin-top: 24px;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 14px;
  }
  .book-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 14px 16px;
    cursor: pointer;
  }
  .book-card h3 { margin: 0 0 4px 0; font-size: 16px; }
  .book-card p { margin: 0; font-size: 12px; color: var(--muted); }
  #reader {
    display: none;
    margin-top: 24px;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 24px;
  }
  #reader-content {
    white-space: pre-wrap;
    font-size: 18px;
    line-height: 1.85;
    margin-top: 16px;
  }
  button {
    background: var(--accent);
    color: #fff;
    border: none;
    border-radius: 8px;
    padding: 8px 14px;
    cursor: pointer;
    font-size: 13px;
  }
</style>
</head>
<body>
<header>
  <h1>书屿 · Wi-Fi 传书与网页书架</h1>
  <div class="auth-bar">
    <input id="tokenInput" type="password" placeholder="6位访问口令" autocomplete="off">
    <button onclick="loadBooks()">验证并刷新</button>
    <span id="status" style="font-size:13px;color:var(--muted)">待验证</span>
  </div>
</header>
<main>
  <div class="dropzone" onclick="document.getElementById('fileInput').click()"
       ondragover="event.preventDefault()"
       ondrop="handleDrop(event)">
    <div style="font-size:16px;font-weight:600">点击选择或拖拽小说文件到此处上传</div>
    <div style="font-size:13px;color:var(--muted);margin-top:4px">
      支持 .txt / .epub / .mobi / .azw3 / .zip 批量导入，自动加入书屿书架
    </div>
    <input id="fileInput" type="file" multiple accept=".txt,.epub,.mobi,.azw3,.azw,.prc,.zip,.fb2,.docx" style="display:none" onchange="uploadFiles(this.files)">
  </div>
  <div id="reader">
    <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap">
      <strong id="reader-title"></strong>
      <div>
        <button onclick="stepChapter(-1)">上一章</button>
        <button onclick="stepChapter(1)">下一章</button>
        <button onclick="document.getElementById('reader').style.display='none'" style="background:#7A6F63">关闭阅读</button>
      </div>
    </div>
    <div id="reader-content"></div>
  </div>
  <h2 style="font-size:16px;margin-top:28px">本机书库</h2>
  <div id="books" class="books"></div>
</main>
<script>
let currentBookId = 0, currentChapter = 0, totalChapters = 0;
const initialToken = new URLSearchParams(location.search).get('token') || '';
if (initialToken) {
  document.getElementById('tokenInput').value = initialToken;
  if (window.history && window.history.replaceState) {
    window.history.replaceState(null, '', location.pathname);
  }
}
function authHeaders() {
  const token = (document.getElementById('tokenInput').value || '').trim();
  return {'X-Shuyu-Token': token};
}
async function loadBooks() {
  const status = document.getElementById('status');
  const res = await fetch('/api/books', {headers: authHeaders()});
  const data = await res.json();
  const container = document.getElementById('books');
  container.innerHTML = '';
  if (!data.ok) {
    status.textContent = data.error || '口令未验证';
    return;
  }
  status.textContent = '已授权连接';
  for (const b of (data.books || [])) {
    const div = document.createElement('div');
    div.className = 'book-card';
    div.onclick = () => openBook(b.id, 0);
    div.innerHTML = '<h3>' + escapeHtml(b.title) + '</h3><p>' +
      escapeHtml(b.author || '佚名') + ' · ' + b.chapterCount + ' 章</p>';
    container.appendChild(div);
  }
}
async function openBook(id, ch) {
  const res = await fetch('/api/book?id=' + id + '&chapter=' + ch, {
    headers: authHeaders()
  });
  const data = await res.json();
  if (!data.ok) return alert(data.error || '加载失败');
  currentBookId = data.id;
  currentChapter = data.chapter;
  totalChapters = data.totalChapters;
  document.getElementById('reader').style.display = 'block';
  document.getElementById('reader-title').textContent =
    data.title + ' · ' + (data.chapterTitle || ('第 ' + (ch + 1) + ' 章'));
  document.getElementById('reader-content').textContent = data.content || '（本章暂无正文）';
}
function stepChapter(delta) {
  const next = currentChapter + delta;
  if (next >= 0 && next < totalChapters) openBook(currentBookId, next);
}
async function uploadFiles(files) {
  const status = document.getElementById('status');
  for (const file of files) {
    status.textContent = '正在上传 ' + file.name + '…';
    const res = await fetch('/api/upload?name=' + encodeURIComponent(file.name), {
      method: 'POST',
      headers: authHeaders(),
      body: file
    });
    const data = await res.json();
    if (!data.ok) alert(file.name + ' 上传失败：' + data.error);
  }
  status.textContent = '上传完成';
  loadBooks();
}
function handleDrop(e) {
  e.preventDefault();
  if (e.dataTransfer && e.dataTransfer.files) uploadFiles(e.dataTransfer.files);
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
}
loadBooks();
</script>
</body>
</html>
''';

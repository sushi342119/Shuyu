import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../reader_languages.dart';
import 'models.dart';

/// Wire interoperability follows rany2/edge-tts; no account, subscription or private API key.
class EdgeSpeechClient {
  EdgeSpeechClient({this.onTransportError});
  final void Function(Object error)? onTransportError;
  static const host = 'speech.platform.bing.com';
  static const route = '/consumer/speech/synthesize/readaloud';
  static const publicClientIdentifier = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  Duration _clockSkew = Duration.zero;
  List<SpeechVoice>? _voices;
  DateTime? _voicesLoaded;

  static String connectionId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String timeProof(DateTime now) => EdgeProtocol.timeProof(now);

  static String escapeXml(String source) => source
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static String timestamp(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = date.toUtc();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${months[d.month - 1]} ${pad(d.day)} ${d.year} '
        '${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static bool _isForbiddenHandshake(WebSocketException error) =>
      error.httpStatusCode == HttpStatus.forbidden;

  static Map<String, String> get headers => {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
    'Accept-Language': 'en-US,en;q=0.9',
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    'Cookie': 'muid=${connectionId().toUpperCase()};',
  };

  Future<List<SpeechVoice>> voices({bool refresh = false}) async {
    if (!refresh &&
        _voices != null &&
        DateTime.now().difference(_voicesLoaded!) < const Duration(hours: 24)) {
      return _voices!;
    }
    final client = HttpClient()
      ..userAgent = null
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.https(host, '$route/voices/list', {
          'trustedclienttoken': publicClientIdentifier,
        }),
      );
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final date = response.headers.value(HttpHeaders.dateHeader);
      if (date != null) {
        try {
          _clockSkew = HttpDate.parse(date).difference(DateTime.now().toUtc());
        } catch (_) {}
      }
      if (response.statusCode != 200) {
        throw const SpeechFailure('在线音色列表暂未连接，可使用已有在线音色或稍后重试');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        bytes.add(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const SpeechFailure('在线音色列表过大');
        }
      }
      final json = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (json is! List) throw const SpeechFailure('在线音色列表格式发生变化');
      final voices = <SpeechVoice>[];
      for (final item in json) {
        if (item is! Map ||
            item['ShortName'] is! String ||
            item['Locale'] is! String) {
          continue;
        }
        final id = item['ShortName'] as String,
            locale = item['Locale'] as String;
        if (!locale.startsWith('zh-') ||
            !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
          continue;
        }
        final known = id == defaultEdgeVoice.id
            ? defaultEdgeVoice.label
            : id == alternateEdgeVoice.id
            ? alternateEdgeVoice.label
            : null;
        final gender = item['Gender'] == 'Female' ? '女声' : '男声';
        voices.add(
          SpeechVoice(
            id: id,
            label: known ?? '${item['FriendlyName'] ?? id} · $gender',
            source: ListeningSource.edge,
            locale: locale,
          ),
        );
      }
      _voices = List.unmodifiable(voices);
      _voicesLoaded = DateTime.now();
      return _voices!;
    } on SpeechFailure {
      rethrow;
    } catch (_) {
      throw const SpeechFailure('在线音色列表连接失败，可继续使用已有音色');
    } finally {
      client.close(force: true);
    }
  }

  static ({String path, Uint8List audio}) binaryAudio(List<int> data) {
    if (data.length < 2) throw const SpeechFailure('在线语音返回了不完整的数据');
    final length = (data[0] << 8) | data[1];
    if (length <= 0 || length + 2 > data.length) {
      throw const SpeechFailure('在线语音数据头无效');
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final header = utf8.decode(
      Uint8List.sublistView(bytes, 2, length + 2),
      allowMalformed: false,
    );
    final path =
        RegExp(r'(?:^|\r\n)Path:([^\r\n]+)').firstMatch(header)?.group(1) ?? '';
    return (path: path, audio: Uint8List.sublistView(bytes, length + 2));
  }

  static bool validVoice(String id, String locale) =>
      id.length <= 120 &&
      locale.length <= 40 &&
      RegExp(r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8}){1,4}$').hasMatch(locale) &&
      RegExp(
        r'^[a-zA-Z]{2,3}-(?:[A-Za-z0-9]+-)+[A-Za-z0-9]+Neural$',
      ).hasMatch(id) &&
      id.toLowerCase().startsWith('${locale.toLowerCase()}-') &&
      speechLanguageCode(locale).isNotEmpty;

  Future<Uint8List> synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) => _synthesize(text, voice, cancellation, retryClock: true);

  Future<Uint8List> _synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation, {
    required bool retryClock,
    int retryCount = 0,
  }) async {
    text = speechText(text);
    if (!validVoice(voice.id, voice.locale)) {
      throw const SpeechFailure('在线朗读音色无效，请重新选择音色');
    }
    if (!hasSpeechText(text) || utf8.encode(escapeXml(text)).length > 3500) {
      throw const SpeechFailure('这一段没有可朗读的文本', kind: SpeechFailureKind.content);
    }
    cancellation.check();
    final client = HttpClient()
      // WebSocket.connect adds rather than replaces headers. Without clearing
      // the default UA, Dart's UA is prepended and the Edge upgrade gets 403.
      ..userAgent = null
      ..connectionTimeout = const Duration(seconds: 10);
    WebSocket? socket;
    final removeCancellation = cancellation.onCancel(() {
      unawaited(socket?.close() ?? Future.value());
      client.close(force: true);
    });
    try {
      final now = DateTime.now().toUtc().add(_clockSkew);
      final uri = Uri(
        scheme: 'wss',
        host: host,
        port: 443,
        path: '$route/edge/v1',
        queryParameters: {
          'TrustedClientToken': publicClientIdentifier,
          'ConnectionId': connectionId(),
          'Sec-MS-GEC': timeProof(now),
          'Sec-MS-GEC-Version': EdgeProtocol.version,
        },
      );
      socket = await WebSocket.connect(
        uri.toString(),
        headers: headers,
        customClient: client,
      ).timeout(const Duration(seconds: 12));
      cancellation.check();
      socket.add(
        'X-Timestamp:${timestamp(now)}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      final ssml =
          '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${voice.locale}">'
          '<voice name="${voice.id}"><prosody pitch="+0Hz" rate="+0%" volume="+0%">${escapeXml(text)}</prosody></voice></speak>';
      socket.add(
        'X-RequestId:${connectionId()}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${timestamp(now)}Z\r\nPath:ssml\r\n\r\n$ssml',
      );
      final audio = BytesBuilder(copy: false);
      var ended = false;
      await for (final event in socket.timeout(const Duration(seconds: 25))) {
        cancellation.check();
        if (event is List<int>) {
          final frame = binaryAudio(event);
          if (frame.path != 'audio') {
            throw const SpeechFailure('在线语音返回了未知的数据类型');
          }
          audio.add(frame.audio);
          if (audio.length > 8 * 1024 * 1024) {
            throw const SpeechFailure('单段语音超过缓存上限');
          }
        } else if (event is String &&
            RegExp(r'(?:^|\r\n)Path:turn\.end(?:\r\n|$)').hasMatch(event)) {
          ended = true;
          break;
        }
      }
      cancellation.check();
      if (!ended) {
        throw const SpeechFailure('在线音源未完成这一段，请检查网络后重试，或换一个在线音色');
      }
      if (audio.length < 100) {
        throw const SpeechFailure(
          '在线音源未生成这一段的语音',
          kind: SpeechFailureKind.content,
        );
      }
      return audio.takeBytes();
    } on SpeechCancelled {
      rethrow;
    } on SpeechFailure {
      rethrow;
    } on WebSocketException catch (error) {
      cancellation.check();
      onTransportError?.call(const SpeechFailure('在线音源连接失败，请检查网络后重试'));
      if (retryClock && _isForbiddenHandshake(error)) {
        try {
          await voices(refresh: true);
        } catch (_) {
          cancellation.check();
        }
        cancellation.check();
        return _synthesize(
          text,
          voice,
          cancellation,
          retryClock: false,
          retryCount: retryCount,
        );
      }
      throw const SpeechFailure('在线音源连接失败，请检查网络后重试，或换一个在线音色');
    } catch (error) {
      cancellation.check();
      onTransportError?.call(const SpeechFailure('在线音源连接失败，请检查网络后重试'));
      if (retryCount < 2 &&
          (error is SocketException ||
              error is HandshakeException ||
              error is HttpException ||
              error is TimeoutException)) {
        await cancellation.wait(
          Future<void>.delayed(Duration(milliseconds: 300 * (1 << retryCount))),
        );
        cancellation.check();
        return _synthesize(
          text,
          voice,
          cancellation,
          retryClock: retryClock,
          retryCount: retryCount + 1,
        );
      }
      throw const SpeechFailure('在线音源连接失败，请检查网络后重试，或换一个在线音色');
    } finally {
      removeCancellation();
      client.close(force: true);
      try {
        await socket?.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        /* The completed turn must not wait indefinitely for a close handshake. */
      }
    }
  }
}

// SPDX-License-Identifier: LGPL-3.0-only
// Protocol adaptation of rany2/edge-tts, Copyright (c) 2025- rany.
// Dart implementation modified 2026-10-15. See assets/licenses/edge-tts.txt.

/// Edge read-aloud v2 proof. This is a wire-protocol checksum, not encryption.
abstract final class EdgeProtocol {
  static const version = '2-143.0.3650.75';
  static const clientIdentifier = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _mask = 0xffffffff;
  static const _initial = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  static const _working = [
    0xfd9fbea2,
    0x91243ce7,
    0xbe499094,
    0xcd2e1e0a,
    0x6c006f49,
    0x04bd35ab,
    0xfeb0a7e4,
    0x03effbd2,
  ];
  static const _schedule = [
    0xeb24bf9e,
    0x1558691f,
    0xa0c09ee2,
    0x0cfa32ba,
    0xa622ee8c,
    0xd1dd9491,
    0xc0dd25a0,
    0xf9e70ab6,
    0xf0c31573,
    0x7058ce4e,
    0x7188e606,
    0x00e5ab33,
    0xd258b060,
    0x72766564,
  ];
  static const _roundConstants = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  static const _coefficients = [
    (0xe82e91b1, 0xb32700d0),
    (0x44de24c6, 0x88dff51d),
    (0x3beb65bc, 0x29514038),
    (0xc89c5933, 0xb328cbdf),
    (0x8d1ec211, 0xd405b4d5),
    (0x314ef5d5, 0x26e55f3c),
    (0xe92491b1, 0x607801c6),
    (0xf0a5b9d5, 0x82b2c1fb),
    (0x06064cf3, 0xfa51a3da),
    (0xda79fa60, 0x207cc464),
    (0xbed20560, 0x3c3c74f3),
    (0x89f9c9f8, 0xd2d14b61),
    (0x35fa38c6, 0xbb04a2c1),
    (0xcb49e3c6, 0xc5626167),
  ];
  static int? _cachedWindow;
  static String? _cachedProof;

  static String timeProof(DateTime now) {
    final seconds = now.toUtc().millisecondsSinceEpoch ~/ 1000 + 11644473600;
    final window = seconds - seconds % 300;
    if (_cachedWindow == window) return _cachedProof!;
    final data = Uint8List.fromList(
      ascii.encode('${window * 10000000}$clientIdentifier'),
    );
    final digest = _digest(data);
    final cs = _cs64(data, digest);
    final bytes = ByteData(8)
      ..setUint32(0, cs.$1, Endian.little)
      ..setUint32(4, cs.$2, Endian.little);
    _cachedWindow = window;
    return _cachedProof = '${_hex(bytes.buffer.asUint8List())}-${_hex(digest)}';
  }

  static String _hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  static int _rotate(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;
  static int _swap(int x) => ((x << 16) | ((x & _mask) >> 16)) & _mask;
  static int _sigma0(int x) => _rotate(x, 7) ^ _rotate(x, 18) ^ (x >> 3);
  static int _sigma1(int x) => _rotate(x, 17) ^ _rotate(x, 19) ^ (x >> 10);

  static void _expand(List<int> words) {
    for (var i = words.length; i < 64; i++) {
      words.add(
        (_sigma1(words[i - 2]) +
                words[i - 7] +
                _sigma0(words[i - 15]) +
                words[i - 16]) &
            _mask,
      );
    }
  }

  static List<int> _rounds(List<int> state, List<int> words, {int start = 0}) {
    var [a, b, c, d, e, f, g, h] = state;
    for (var i = start; i < 64; i++) {
      final constant = start == 14 && i == 14 ? 0xc9dc06a7 : _roundConstants[i];
      final t1 =
          h +
          (_rotate(e, 6) ^ _rotate(e, 11) ^ _rotate(e, 25)) +
          (g ^ (e & (f ^ g))) +
          constant +
          words[i];
      final t2 =
          (_rotate(a, 2) ^ _rotate(a, 13) ^ _rotate(a, 22)) +
          ((a & b) | (c & (a | b)));
      [a, b, c, d, e, f, g, h] = [
        (t1 + t2) & _mask,
        a,
        b,
        c,
        (d + t1) & _mask,
        e,
        f,
        g,
      ];
    }
    return [a, b, c, d, e, f, g, h];
  }

  static Uint8List _digest(Uint8List data) {
    final prefix = ByteData.sublistView(data);
    final words = [
      ...List.filled(14, 0),
      data[0] << 16 | data[1] << 8 | data[2],
      prefix.getUint32(3),
    ];
    for (var i = 16; i < 30; i++) {
      var value = _schedule[i - 16];
      if (i - 2 >= 14) {
        value += _sigma1(words[i - 2]) ^ (i == 16 ? 0x000b92c0 : 0);
      }
      if (i - 7 >= 14) value += words[i - 7];
      if (i - 15 >= 14) {
        value += _sigma0(words[i - 15]) ^ (i == 29 ? 0x059c0b80 : 0);
      }
      words.add(value & _mask);
    }
    words.add(
      (_sigma1(words[28]) +
              words[23] +
              _sigma0(words[15]) +
              words[14] +
              0xc9dc06a7 -
              _roundConstants[14]) &
          _mask,
    );
    _expand(words);
    final working = _rounds(_working, words, start: 14);
    var state = List.generate(8, (i) => (_initial[i] + working[i]) & _mask);
    final length = 57 + data.length;
    final padding = (55 - length) % 64;
    final tail = Uint8List(data.length - 7 + 1 + padding + 8);
    tail.setRange(0, data.length - 7, data, 7);
    tail[data.length - 7] = 0x80;
    final view = ByteData.sublistView(tail)
      ..setUint64(tail.length - 8, length * 8);
    for (var offset = 0; offset < tail.length; offset += 64) {
      final block = List.generate(16, (i) => view.getUint32(offset + i * 4));
      _expand(block);
      final result = _rounds(state, block);
      state = List.generate(8, (i) => (state[i] + result[i]) & _mask);
    }
    final result = ByteData(32);
    for (var i = 0; i < 8; i++) {
      result.setUint32(i * 4, state[i]);
    }
    return result.buffer.asUint8List();
  }

  static (int, int) _cs64(Uint8List data, Uint8List digest) {
    final key = ByteData.sublistView(digest);
    final keys = [
      key.getUint32(0, Endian.little) | 1,
      key.getUint32(4, Endian.little) | 1,
    ];
    final factors = keys.map((k) => (k * 0x82893933) & _mask).toList();
    final terms = List.generate(
      _coefficients.length,
      (i) => (_coefficients[i].$1 * factors[i % 2]) & _mask,
    );
    final offsets = _coefficients.map((c) => c.$2).toList();
    final padded = Uint8List(((data.length + 1 + 7) ~/ 8) * 8)
      ..setRange(1, data.length + 1, data);
    final view = ByteData.sublistView(padded);
    for (var i = 0; i < padded.length ~/ 4; i++) {
      final word = view.getUint32(i * 4, Endian.little);
      var term = word * keys[i % 2];
      var offset = _swap(word) * (i.isEven ? 0xef0569fb : 0xc31713db);
      if (i == 0) {
        term += 0xf2f90b1a * factors[0];
        offset += 0x0b1a0000;
      }
      terms.add(term & _mask);
      offsets.add(offset & _mask);
    }
    var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
    for (var i = 0; i < terms.length; i += 2) {
      final x = terms[i], y = terms[i + 1];
      var q = (_swap((offsets[i] + x) & _mask) * 0x76f50f34) & _mask;
      swapAcc += (_swap(q) * 0xc3efea97 + q) & _mask;
      q = (_swap((offsets[i + 1] + y) & _mask) * 0x1881ce3c) & _mask;
      swapLast = (_swap(q) * 0x35bd1ec9 + q) & _mask;
      swapAcc = (swapAcc + swapLast) & _mask;
      state = (state * keys[0] + x) & _mask;
      for (final factor in [0xcf98b111, 0x87085b9f, 0x12ceb96d, 0x257e1d83]) {
        state = (_swap(state) * factor) & _mask;
      }
      acc += state;
      var t = (state * keys[1] + y) & _mask;
      for (final factor in [0xa27416f5, 0xd38396ff, 0x7c932b89, 0xbfa49f69]) {
        t = (_swap(t) * factor) & _mask;
      }
      state = t;
      acc = (acc + state) & _mask;
    }
    return (swapLast ^ state, swapAcc ^ acc);
  }
}

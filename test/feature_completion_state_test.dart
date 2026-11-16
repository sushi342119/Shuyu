import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/reader_content.dart';
import 'package:shuyu/reader_find.dart';
import 'package:shuyu/reader_illustrations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  group('illustrations', () {
    test(
      'image URLs are not in-chapter search hits or arbitrary remote fetches',
      () async {
        final content = await ReaderContent.parse(
          'img文字\n\n<!--image-->https://img.wenku8.com/a.jpg<!--image-->',
        );
        expect((await findInReader(content, 'img')).matches.length, 1);
        expect(
          readerIllustrationUrl(
            '<!--image-->https://example.org/a.jpg<!--image-->',
          ),
          isNull,
        );
        expect(
          readerIllustrationUrl(
            '<!--image-->https://img.wenku8.com.evil.test/a.jpg<!--image-->',
          ),
          isNull,
        );
        expect(
          readerIllustrationUrl('<!--image-->file:///tmp/a.jpg<!--image-->'),
          isNull,
        );
      },
    );
    test(
      'encoded memory cache is bounded and evicted futures fetch again',
      () async {
        final calls = <String>[];
        final cache = ReaderIllustrationCache(
          maxBytes: 8,
          request: (url) async {
            calls.add(url);
            return Uint8List(4);
          },
        );
        await cache.load('a');
        await cache.load('b');
        await cache.load('a');
        await cache.load('c');
        expect(cache.encodedBytes, 8);
        expect(cache.peek('b'), isNull);
        await cache.load('b');
        expect(calls, ['a', 'b', 'c', 'b']);
      },
    );
    test(
      'pending images deduplicate; failure and clear release requests',
      () async {
        final held = Completer<Uint8List>();
        var calls = 0;
        final cache = ReaderIllustrationCache(
          request: (_) {
            calls++;
            return held.future;
          },
        );
        final first = cache.load('a');
        final second = cache.load('a');
        expect(calls, 1);
        cache.clearMemory();
        held.complete(Uint8List(4));
        await first;
        await second;
        expect(cache.peek('a'), isNull);
        expect(cache.encodedBytes, 0);
        var attempts = 0;
        final retry = ReaderIllustrationCache(
          request: (_) async {
            if (++attempts == 1) throw StateError('offline');
            return Uint8List(4);
          },
        );
        await expectLater(retry.load('a'), throwsStateError);
        await retry.load('a');
        expect(attempts, 2);
      },
    );
  });
}

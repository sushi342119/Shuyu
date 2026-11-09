import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/reader_purification.dart';
import 'package:shuyu/reader_purification_import.dart';

Map<String, Object?> rule(
  String pattern, {
  String replacement = '',
  bool regex = false,
  String scope = '',
  String excludeScope = '',
  bool content = true,
  int order = 0,
}) => {
  'name': 'Rule $pattern',
  'pattern': pattern,
  'replacement': replacement,
  'isRegex': regex,
  'isEnabled': true,
  'scope': scope,
  'excludeScope': excludeScope,
  'scopeContent': content,
  'order': order,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Network tests below only use their own loopback HTTP server.
  setUpAll(() {
    HttpOverrides.global = null;
    ReaderPurificationDownload.allowLoopbackHttpForTesting = true;
  });
  tearDownAll(() {
    ReaderPurificationDownload.allowLoopbackHttpForTesting = false;
  });
  final store = ReaderPurificationStore.shared;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.resetForTesting();
  });

  test(
    'downloads JSON through redirects, defaults imported rules to disabled until enabled, deduplicates and deletes its source',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = 'http://${server.address.address}:${server.port}/redirect';
      server.listen((request) async {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/rules.json',
          );
        } else {
          // Deliberately text/plain with BOM and no .json on the input URL.
          request.response.headers.contentType = ContentType.text;
          request.response.add(
            utf8.encode('\uFEFF${jsonEncode([rule('广告')])}'),
          );
        }
        await request.response.close();
      });
      final result = await store.importRulesFromInput(url);
      expect(result.imported, 1);
      // Imported rules default to disabled until explicitly enabled by the user.
      expect(store.rules.last.enabled, isFalse);
      expect(store.purifyParagraph('这是广告正文'), '这是广告正文');
      await store.enableAllCustomRules();
      expect(store.purifyParagraph('这是广告正文'), '这是正文');
      expect(store.rules.last.sourceUrl, url);
      expect((await store.importRulesFromInput(url)).duplicates, 1);
      await store.addCustomRule(
        name: 'Manual',
        pattern: '错字',
        replacement: '正字',
        isRegex: false,
      );
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.rules.where((r) => r.sourceUrl == url), hasLength(1));
      await store.removeSource(url);
      expect(store.purifyParagraph('广告错字'), '广告正字');
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.rules.where((r) => r.sourceUrl == url), isEmpty);
    },
  );

  test(
    'failed HTTP, HTML, non-HTTPS external URLs and oversized downloads leave rules intact',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://${server.address.address}:${server.port}';
      server.listen((request) async {
        switch (request.uri.path) {
          case '/missing':
            request.response.statusCode = 404;
          case '/large':
            request.response.write(
              'x' * (ReaderPurificationDownload.maxBytes + 1),
            );
          default:
            request.response.write('<html>Not JSON</html>');
        }
        await request.response.close();
      });
      await expectLater(
        store.importRulesFromInput('$base/missing'),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        store.importRulesFromInput('$base/html'),
        throwsFormatException,
      );
      await expectLater(
        store.importRulesFromInput('$base/large'),
        throwsFormatException,
      );
      for (final url in [
        'file:///rules.json',
        'http://example.com/rules.json',
        'https://',
        'https://user:pass@example.com/rules',
      ]) {
        expect(
          () => ReaderPurificationDownload.parseUrl(url),
          throwsFormatException,
        );
      }
      expect(
        store.rules,
        hasLength(ReaderPurificationStore.builtInPresets.length),
      );
    },
  );

  test(
    'preserves scopes, content flags, ordering and distinct scope duplicates',
    () async {
      final result = await store.importRulesFromInput(
        jsonEncode([
          rule('B', replacement: 'C', order: 2),
          rule('A', replacement: 'B', order: 1),
          rule('X', scope: 'Book A;https://example.com', order: 3),
          rule('X', scope: 'Book B;https://example.com', order: 4),
          rule('Z', scope: 'https://example.com', order: 5),
          rule('T', content: false, order: 6),
          rule('Y', excludeScope: 'Book A', order: 7),
          {'name': 123, 'pattern': 456},
        ]),
        enableImported: true,
      );
      expect(result.imported, 7);
      expect(result.invalid, 1);
      expect(store.purifyParagraph('AXZTY', bookTitle: 'Book A'), 'CZTY');
      expect(store.purifyParagraph('AXZTY', bookTitle: 'Book B'), 'CZT');
      expect(store.purifyParagraph('AXZTY', bookTitle: 'Book C'), 'CXZT');
      expect(store.purifyParagraph('AXZTY'), 'CXZT');
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.purifyParagraph('AXZTY', bookTitle: 'Book A'), 'CZTY');
    },
  );

  test(
    'incompatible and ReDoS rules are disabled and never output script text',
    () async {
      final result = await store.importRulesFromInput(
        jsonEncode([
          rule('广告'),
          rule('word', replacement: '@js:result.toUpperCase()'),
          rule('[unclosed', regex: true),
          rule('(a+)+b', regex: true),
        ]),
        enableImported: true,
      );
      expect(result.imported, 4);
      expect(result.disabled, 3);
      expect(store.purifyParagraph('word广告'), 'word');
      final script = store.rules.firstWhere(
        (r) => r.replacement.startsWith('@js:'),
      );
      await store.toggleRule(script.id, true);
      expect(store.purifyParagraph('word'), 'word');
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.purifyParagraph('word'), 'word');
    },
  );

  test(
    'regex groups, multiline flags and unicode properties work after import',
    () async {
      await store.importRulesFromInput(
        jsonEncode([
          rule(r'([，。！？；])\1{2,}', replacement: r'$1$1', regex: true),
          rule(r'(?m)^广告$', regex: true),
          rule(r'[😀-🙏]+', regex: true),
          rule(r'[𝓟\｡]+', regex: true),
          rule(r'[^\p{L}\p{N}\s]+(?=END)', replacement: '', regex: true),
        ]),
        enableImported: true,
      );
      expect(store.purifyParagraph('你好！！！😀🙏𝓟｡\n广告\n!END'), '你好！！\n\nEND');
    },
  );

  test(
    'master and individual switches persist, deletion restores original text',
    () async {
      await store.importRulesFromInput(
        jsonEncode([rule('广告')]),
        enableImported: true,
      );
      final id = store.rules.last.id;
      await store.toggleRule(id, false);
      expect(store.purifyParagraph('广告正文'), '广告正文');
      await store.toggleRule(id, true);
      await store.setEnabled(false);
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.enabled, isFalse);
      expect(store.purifyParagraph('广告正文'), '广告正文');
      await store.setEnabled(true);
      expect(store.purifyParagraph('广告正文'), '正文');
      await store.removeRule(id);
      expect(store.purifyParagraph('广告正文'), '广告正文');
    },
  );

  test(
    'share tokens round trip source metadata and title-only rules',
    () async {
      await store.importRulesFromInput(
        jsonEncode([
          {
            ...rule('X', content: false),
            'scopeTitle': true,
            'sourceUrl': 'https://example.com/rules',
          },
        ]),
        enableImported: true,
      );
      final token = store.exportRulesShareToken();
      store.resetForTesting();
      SharedPreferences.setMockInitialValues({});
      await store.importRulesFromInput(token, enableImported: true);
      expect(store.rules.last.applyToTitle, isTrue);
      expect(store.rules.last.applyToContent, isFalse);
      expect(store.rules.last.sourceUrl, 'https://example.com/rules');
      expect(store.purifyParagraph('X'), 'X');
    },
  );

  testWidgets('link import validates HTTPS input and clipboard imports rules safely disabled by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReaderPurificationSheet(
                context: context,
                reduceMotion: true,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('purification-import-url')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('purification-url-field')),
      'invalid',
    );
    await tester.tap(
      find.byKey(const ValueKey('purification-import-url-submit')),
    );
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的 HTTPS 安全规则链接'), findsOneWidget);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {
            'text': jsonEncode([rule('广告')]),
          };
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('purification-import-clipboard')),
    );
    await tester.tap(
      find.byKey(const ValueKey('purification-import-clipboard')),
    );
    await tester.pumpAndSettle();
    expect(store.rules.last.enabled, isFalse);
    await store.enableAllCustomRules();
    expect(store.purifyParagraph('广告正文'), '正文');
    expect(tester.takeException(), isNull);
  });
}

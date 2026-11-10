import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
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

class _RuleStorage extends InMemorySharedPreferencesStore {
  _RuleStorage() : super.empty();

  bool reject = false;
  bool throwOnWrite = false;
  Completer<void>? gate;
  Completer<void>? started;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.${ReaderPurificationStore.preferenceKey}') {
      started?.complete();
      started = null;
      if (gate != null) await gate!.future;
      if (throwOnWrite) throw StateError('disk failure');
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}

Future<_RuleStorage> _useRuleStorage() async {
  SharedPreferences.resetStatic();
  final storage = _RuleStorage();
  SharedPreferencesStorePlatform.instance = storage;
  await ReaderPurificationStore.shared.ensureLoaded();
  return storage;
}

Future<void> openImportSheet(WidgetTester tester) async {
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
}

Future<void> importClipboard(WidgetTester tester, Object rules) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async =>
        call.method == 'Clipboard.getData' ? {'text': jsonEncode(rules)} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final button = find.byKey(const ValueKey('purification-import-clipboard'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

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
        ReaderPurificationDownload.parseUrl(
          'http://example.com/rules.json',
          allowHttp: true,
        ).toString(),
        'http://example.com/rules.json',
      );
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

  test(
    'confirmation IDs exclude duplicates and leave all existing rules untouched',
    () async {
      const source = 'https://example.com/a';
      await store.importRulesFromInput(
        jsonEncode([
          {...rule('old-off'), 'sourceUrl': source},
          {...rule('old-on'), 'sourceUrl': source},
          {...rule('other'), 'sourceUrl': 'https://example.com/b'},
        ]),
        enableImported: true,
      );
      final oldOff = store.rules.firstWhere((r) => r.pattern == 'old-off');
      await store.toggleRule(oldOff.id, false);
      await store.toggleRule(store.rules.first.id, true);
      await store.addCustomRule(
        name: 'manual',
        pattern: 'manual',
        replacement: '',
        isRegex: false,
      );
      final before = [for (final r in store.rules) r.toJson()];
      final result = await store.importRulesFromInput(
        jsonEncode([
          {...rule('old-off'), 'sourceUrl': 'https://example.com/b'},
          {...rule('new'), 'sourceUrl': source, 'enabled': true},
          {...rule('new-off'), 'isEnabled': false},
          rule('script', replacement: '  @js:result'),
          rule('[unclosed', regex: true),
          rule('(a+)+b', regex: true),
          {'pattern': 123},
        ]),
      );
      expect(result.imported, 5);
      expect(result.disabled, 3);
      expect(result.duplicates, 1);
      expect(result.invalid, 1);
      expect(result.importedRuleIds, hasLength(5));
      expect(result.enableableRuleIds, hasLength(2));
      expect(() => result.importedRuleIds.add('old'), throwsUnsupportedError);
      expect(() => result.enableableRuleIds.clear(), throwsUnsupportedError);
      expect(store.rules.skip(before.length).every((r) => !r.enabled), isTrue);
      expect(await store.enableImportedRules(result.enableableRuleIds), 2);
      expect([
        for (final r in store.rules.take(before.length)) r.toJson(),
      ], before);
      // Even a defensive call with all new IDs must keep blocked rules off.
      expect(await store.enableImportedRules(result.importedRuleIds), 0);
      expect(
        store.rules
            .where((r) => r.unsupportedReason != null)
            .every((r) => !r.enabled),
        isTrue,
      );
      expect(
        await store.enableImportedRules([store.rules[1].id, 'missing']),
        0,
      );
      expect(store.rules[1].enabled, isFalse);
      store.resetForTesting();
      await store.ensureLoaded();
      expect([
        for (final r in store.rules.take(before.length)) r.toJson(),
      ], before);
      expect(
        store.rules
            .where((r) => r.unsupportedReason != null)
            .every((r) => !r.enabled),
        isTrue,
      );
    },
  );

  test(
    'batch activation preserves order, scopes, master switch and deletion',
    () async {
      final result = await store.importRulesFromInput(
        jsonEncode([
          {
            ...rule('B', replacement: 'C', order: 2),
            'sourceUrl': 'https://example.com/a',
          },
          {
            ...rule('A', replacement: 'B', order: 1),
            'sourceUrl': 'https://example.com/a',
          },
          rule('X', scope: 'Book A', order: 3),
          rule('Y', excludeScope: 'Book A', order: 3),
          rule('T', content: false, order: 4),
        ]),
      );
      final ids = store.rules.map((r) => r.id).toList();
      final metadata = [
        for (final r in store.rules) {...r.toJson()}..remove('enabled'),
      ];
      await store.setEnabled(false);
      expect(await store.enableImportedRules(result.enableableRuleIds), 5);
      expect(store.enabled, isFalse);
      expect(store.purifyParagraph('AXYT', bookTitle: 'Book A'), 'AXYT');
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.enabled, isFalse);
      expect(store.rules.map((r) => r.id), ids);
      expect([
        for (final r in store.rules) {...r.toJson()}..remove('enabled'),
      ], metadata);
      await store.setEnabled(true);
      expect(store.purifyParagraph('AXYT', bookTitle: 'Book A'), 'CYT');
      expect(store.purifyParagraph('AXYT', bookTitle: 'Book B'), 'CXT');
      await store.removeSource('https://example.com/a');
      expect(store.purifyParagraph('AXYT', bookTitle: 'Book A'), 'AYT');
      final x = store.rules.firstWhere((r) => r.pattern == 'X');
      await store.removeRule(x.id);
      expect(await store.enableImportedRules([x.id]), 0);
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.rules.any((r) => r.id == x.id), isFalse);
      expect(
        store.rules.any((r) => r.sourceUrl == 'https://example.com/a'),
        isFalse,
      );
    },
  );

  for (final throwsWrite in [false, true]) {
    test(
      'failed import and activation keep memory/disk intact and allow retry (throws=$throwsWrite)',
      () async {
        final storage = await _useRuleStorage();
        await store.addCustomRule(
          name: 'original',
          pattern: 'original',
          replacement: '',
          isRegex: false,
        );
        final before = [for (final r in store.rules) r.toJson()];
        storage.reject = !throwsWrite;
        storage.throwOnWrite = throwsWrite;
        final payload = jsonEncode([rule('new')]);
        await expectLater(
          store.importRulesFromInput(payload),
          throwsA(isA<ReaderPurificationSaveException>()),
        );
        expect([for (final r in store.rules) r.toJson()], before);
        store.resetForTesting();
        await store.ensureLoaded();
        expect([for (final r in store.rules) r.toJson()], before);
        storage.reject = storage.throwOnWrite = false;
        final result = await store.importRulesFromInput(payload);
        storage.reject = !throwsWrite;
        storage.throwOnWrite = throwsWrite;
        await expectLater(
          store.enableImportedRules(result.enableableRuleIds),
          throwsA(isA<ReaderPurificationSaveException>()),
        );
        expect(store.rules.last.enabled, isFalse);
        expect(store.purifyParagraph('new'), 'new');
        store.resetForTesting();
        await store.ensureLoaded();
        expect(store.rules.last.enabled, isFalse);
        storage.reject = storage.throwOnWrite = false;
        expect(await store.enableImportedRules(result.enableableRuleIds), 1);
        expect(store.purifyParagraph('new'), '');
      },
    );
  }

  test(
    'overlapping import, toggle and delete keep their order without lost edits',
    () async {
      final storage = await _useRuleStorage();
      await store.addCustomRule(
        name: 'original',
        pattern: 'original',
        replacement: '',
        isRegex: false,
      );
      final oldId = store.rules.last.id;
      final started = Completer<void>();
      storage.started = started;
      storage.gate = Completer<void>();
      final importing = store.importRulesFromInput(jsonEncode([rule('new')]));
      await started.future;
      final toggling = store.toggleRule(oldId, false);
      final deleting = store.removeRule(oldId);
      expect(store.rules.any((r) => r.pattern == 'new'), isFalse);
      storage.gate!.complete();
      await importing;
      await toggling;
      await deleting;
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.rules.any((r) => r.id == oldId), isFalse);
      expect(store.rules.last.pattern, 'new');
      expect(store.rules.last.enabled, isFalse);
    },
  );

  for (final dismissal in ['save', 'back', 'barrier']) {
    testWidgets('$dismissal keeps imported rules saved but disabled', (
      tester,
    ) async {
      await openImportSheet(tester);
      await importClipboard(tester, [rule('广告')]);
      expect(find.text('规则已保存，尚未启用'), findsOneWidget);
      if (dismissal == 'save') {
        await tester.tap(
          find.byKey(const ValueKey('purification-import-save-only')),
        );
      } else if (dismissal == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(const Offset(5, 5));
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purification-import-confirm')),
        findsNothing,
      );
      expect(store.rules.last.enabled, isFalse);
      store.resetForTesting();
      await store.ensureLoaded();
      expect(store.rules.last.pattern, '广告');
      expect(store.rules.last.enabled, isFalse);
    });
  }

  testWidgets(
    'duplicates and blocked-only imports do not offer batch activation',
    (tester) async {
      await openImportSheet(tester);
      await importClipboard(tester, [
        rule('script', replacement: '@js:result'),
      ]);
      expect(
        find.byKey(const ValueKey('purification-import-confirm')),
        findsNothing,
      );
      expect(store.rules.last.enabled, isFalse);
      await importClipboard(tester, [
        rule('script', replacement: '@js:result'),
      ]);
      expect(
        find.byKey(const ValueKey('purification-import-confirm')),
        findsNothing,
      );
      expect(store.rules.where((r) => !r.builtIn), hasLength(1));
    },
  );

  testWidgets(
    'failed activation remains in dialog and can retry with master off',
    (tester) async {
      final storage = await _useRuleStorage();
      await store.setEnabled(false);
      await openImportSheet(tester);
      await importClipboard(tester, [rule('广告'), rule('(a+)+b', regex: true)]);
      expect(find.text('启用本次 1 条'), findsOneWidget);
      expect(find.text('正文净化总开关关闭，启用规则后仍需手动打开总开关。'), findsOneWidget);
      storage.reject = true;
      await tester.tap(
        find.byKey(const ValueKey('purification-import-enable-batch')),
      );
      await tester.pumpAndSettle();
      expect(find.text('启用保存失败，规则仍未启用，请重试'), findsOneWidget);
      expect(
        store.rules.where((r) => !r.builtIn).every((r) => !r.enabled),
        isTrue,
      );
      storage.reject = false;
      await tester.tap(
        find.byKey(const ValueKey('purification-import-enable-batch')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purification-import-confirm')),
        findsNothing,
      );
      expect(store.enabled, isFalse);
      expect(store.rules.firstWhere((r) => r.pattern == '广告').enabled, isTrue);
      expect(store.rules.last.enabled, isFalse);
      expect(store.purifyParagraph('广告正文'), '广告正文');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('activation blocks repeated taps and dismissal while saving', (
    tester,
  ) async {
    final storage = await _useRuleStorage();
    await openImportSheet(tester);
    await importClipboard(tester, [rule('广告')]);
    storage.gate = Completer<void>();
    final button = find.byKey(
      const ValueKey('purification-import-enable-batch'),
    );
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget);
    expect(store.rules.last.enabled, isFalse);
    await tester.tapAt(const Offset(5, 5));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('purification-import-confirm')),
      findsOneWidget,
    );
    storage.gate!.complete();
    await tester.pumpAndSettle();
    expect(store.rules.last.enabled, isTrue);
    expect(
      find.byKey(const ValueKey('purification-import-confirm')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('purification-import-clipboard')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed import reports failure without confirmation or new rules',
    (tester) async {
      final storage = await _useRuleStorage();
      storage.reject = true;
      await openImportSheet(tester);
      await importClipboard(tester, [rule('广告')]);
      expect(find.text('规则保存失败，请重试'), findsWidgets);
      expect(
        find.byKey(const ValueKey('purification-import-confirm')),
        findsNothing,
      );
      expect(store.rules.every((r) => r.builtIn), isTrue);
      storage.reject = false;
      await importClipboard(tester, [rule('广告')]);
      expect(find.text('规则已保存，尚未启用'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('purification-import-save-only')),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'URL submit saves then confirms only newly downloaded compatible rules',
    (tester) async {
      late HttpServer server;
      await tester.runAsync(() async {
        HttpOverrides.global = null;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.write(
            jsonEncode([rule('广告'), rule('script', replacement: '@js:result')]),
          );
          await request.response.close();
        });
      });
      addTearDown(() => server.close(force: true));
      await openImportSheet(tester);
      await tester.tap(find.byKey(const ValueKey('purification-import-url')));
      await tester.pumpAndSettle();
      expect(find.text('导入规则'), findsOneWidget);
      expect(find.text('导入并使用'), findsNothing);
      final url = 'http://127.0.0.1:${server.port}/rules';
      await tester.enterText(
        find.byKey(const ValueKey('purification-url-field')),
        url,
      );
      await tester.tap(
        find.byKey(const ValueKey('purification-import-url-submit')),
      );
      await tester.pump();
      // Real loopback I/O and the widget's fake clock must both advance.
      for (
        var attempt = 0;
        attempt < 100 &&
            find
                .byKey(const ValueKey('purification-import-confirm'))
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('来源：127.0.0.1'), findsOneWidget);
      expect(find.text('启用本次 1 条'), findsOneWidget);
      expect(
        store.rules.where((r) => !r.builtIn).every((r) => !r.enabled),
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('purification-import-enable-batch')),
      );
      await tester.pumpAndSettle();
      expect(store.purifyParagraph('广告script'), 'script');
      expect(store.rules.last.enabled, isFalse);
      expect(store.rules.last.sourceUrl, url);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'link import validates HTTPS input and clipboard imports rules safely disabled by default',
    (tester) async {
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
      expect(find.text('规则已保存，尚未启用'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('purification-import-enable-batch')),
      );
      await tester.pumpAndSettle();
      expect(store.purifyParagraph('广告正文'), '正文');
      expect(
        find.byKey(const ValueKey('purification-import-confirm')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

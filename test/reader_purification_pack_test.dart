import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/reader_purification.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReaderPurificationStore.shared.resetForTesting();
  });

  test('optional pack is disabled by default and can be toggled and removed', () async {
    final store = ReaderPurificationStore.shared;
    final count = await store.importRulesFromText(
      '[{"name":"净化测试","pattern":"广告[0-9]+","replacement":""}]',
      sourcePack: ReaderPurificationStore.nyaRulePackId,
    );
    expect(count, 1);
    expect(store.nyaRulePackRuleCount, 1);
    expect(store.nyaRulePackEnabled, false);
    expect(store.purifyParagraph('正文广告123结束'), '正文广告123结束');

    await store.setNyaRulePackEnabled(true);
    expect(store.purifyParagraph('正文广告123结束'), '正文结束');
    await store.setNyaRulePackEnabled(false);
    expect(store.purifyParagraph('正文广告123结束'), '正文广告123结束');

    await store.removeNyaRulePack();
    expect(store.nyaRulePackRuleCount, 0);
    expect(store.nyaRulePackEnabled, false);
  });

  test('pack delete does not touch a personal rule', () async {
    final store = ReaderPurificationStore.shared;
    await store.addCustomRule(
      name: '个人规则',
      pattern: '错字',
      replacement: '正字',
      isRegex: false,
    );
    await store.importRulesFromText(
      '[{"name":"规则包","pattern":"广告","replacement":""}]',
      sourcePack: ReaderPurificationStore.nyaRulePackId,
    );
    await store.removeNyaRulePack();
    expect(store.purifyParagraph('错字'), '正字');
  });

  test('Legado numeric captures are expanded and broken regex skipped', () async {
    final store = ReaderPurificationStore.shared;
    final count = await store.importRulesFromText(
      r'[{"name":"交换","pattern":"(A)(B)","replacement":"$2$1"},'
      r'{"name":"无效规则","pattern":"[","replacement":""}]',
      sourcePack: ReaderPurificationStore.nyaRulePackId,
    );
    expect(count, 1);
    await store.setNyaRulePackEnabled(true);
    expect(store.purifyParagraph('AB'), 'BA');
  });
}

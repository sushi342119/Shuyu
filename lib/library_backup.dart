import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'catalog.dart';
import 'haptic_preferences.dart';
import 'performance_preferences.dart';
import 'reader_preferences.dart';
import 'reader_underline.dart';
import 'reading_activity.dart';
import 'reading_moments.dart';
import 'recovery_archive.dart';
import 'ui_preferences.dart';
import 'user_fonts.dart';

const localTextEncodingOptions = {
  'auto': '自动识别',
  'UTF-8': 'UTF-8',
  'GB18030': 'GB18030 / GBK',
  'Big5': 'Big5',
  'Big5-HKSCS': 'Big5-HKSCS',
  'UTF-16LE': 'UTF-16 LE',
  'UTF-16BE': 'UTF-16 BE',
};

const shelfSortValues = {
  'recentRead',
  'recentAdded',
  'title',
  'progress',
  'chapters',
};

const backupPurificationKeys = {
  'reader_purification_rules_v1',
  'reader_purification_enabled_v1',
  'reader_paragraph_edits_v1',
};

const backupReadingStatsKeys = {
  ReadingActivityStore.preferenceKey,
  ReadingMomentsStore.preferenceKey,
};

/// 用户在生成备份或上传 WebDAV 时可勾选的附加数据范围。
@immutable
class LibraryBackupOptions {
  const LibraryBackupOptions({
    this.includePreferences = true,
    this.includePurification = true,
    this.includeReadingStats = true,
  });

  static const all = LibraryBackupOptions();

  final bool includePreferences;
  final bool includePurification;
  final bool includeReadingStats;

  LibraryBackupOptions copyWith({
    bool? includePreferences,
    bool? includePurification,
    bool? includeReadingStats,
  }) => LibraryBackupOptions(
    includePreferences: includePreferences ?? this.includePreferences,
    includePurification: includePurification ?? this.includePurification,
    includeReadingStats: includeReadingStats ?? this.includeReadingStats,
  );
}

final backupPreferenceKeys = <String>{
  'theme',
  'appLanguage',
  'readerFontSize',
  'readerLineHeight',
  'reduceMotion',
  'glassBlur',
  'glassOpacity',
  'readerKeepScreenOn',
  'checkAppUpdates',
  'appTypeface',
  'appFontId',
  'readerTypeface',
  AppPalettePreferences.key,
  'shelfSort',
  'shelfFilter',
  'localTxtEncoding',
  HapticPreferences.preferenceKey,
  PerformancePreferences.modeKey,
  ...PerformanceEffect.values.map((effect) => effect.preferenceKey),
  // 2026-11 UI round: additive keys only (glass tier, motion, reader paper…).
  ...UiPreferenceKeys.all,
};
const _listKeys = {'shelf', 'reading_history_hidden', 'recentSearches', 'local_shelf_removed'};
const _tagRecordKeys = {'tag_defs', 'tag_map'};
const restoreJournalKey = 'library_restore_journal';
const restoreJournalQuarantineKey = 'library_restore_journal_quarantine_v1';
final _recordKey = RegExp(
  r'^(chapter|shelf_added|novel_meta|reading_position|reader_bookmarks)_([1-9][0-9]{0,9})$',
);
final _paragraphEditKey = RegExp(
  r'^([1-9][0-9]{0,9}):([0-9]{1,6}):([0-9]{1,7})$',
);

bool isLibraryRecordKey(String key) =>
    backupPreferenceKeys.contains(key) ||
    backupPurificationKeys.contains(key) ||
    backupReadingStatsKeys.contains(key) ||
    _listKeys.contains(key) ||
    _tagRecordKeys.contains(key) ||
    (_recordKey.hasMatch(key) &&
        int.parse(_recordKey.firstMatch(key)![2]!) <= 0x7fffffff);

class LibraryBackupUnavailable implements Exception {
  const LibraryBackupUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class LibraryBackup {
  LibraryBackup._(this.createdAt, Map<String, Object> records, {
    List<String> omittedCoverKeys = const [],
  }) : records = Map.unmodifiable(records),
       omittedCoverKeys = List.unmodifiable(omittedCoverKeys);
  static const maxBytes = 32 * 1024 * 1024;
  final int createdAt;
  final Map<String, Object> records;
  final List<String> omittedCoverKeys;
  int get shelfCount => (records['shelf'] as List<String>? ?? const []).length;
  int get positionCount =>
      records.keys.where((key) => key.startsWith('reading_position_')).length;
  int get bookmarkCount => records.entries
      .where((entry) => entry.key.startsWith('reader_bookmarks_'))
      .fold<int>(
        0,
        (sum, entry) =>
            sum + (jsonDecode(entry.value as String) as List).length,
      );
  int get historyCount => records.keys
      .where(
        (key) =>
            key.startsWith('chapter_') || key.startsWith('reading_position_'),
      )
      .map((key) => key.substring(key.lastIndexOf('_') + 1))
      .toSet()
      .length;
  bool get hasPreferences => records.keys.any(backupPreferenceKeys.contains);
  bool get hasPurification => records.keys.any(backupPurificationKeys.contains);
  bool get hasReadingStats => records.keys.any(backupReadingStatsKeys.contains);

  /// 有标签归属的书籍数量（用于备份预览确认）。
  int get tagCount {
    final raw = records['tag_map'];
    if (raw is! String) return 0;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return 0;
      var count = 0;
      for (final value in map.values) {
        if (value is List && value.isNotEmpty) count++;
      }
      return count;
    } catch (error) {
      if (kDebugMode) debugPrint('LibraryBackup.tagCount decode failed: $error');
      return 0;
    }
  }

  static Future<LibraryBackup> parse(String text) async {
    if (text.length > maxBytes) {
      throw const FormatException('备份文件超过 32 MiB');
    }
    return compute(_decodeBackup, text);
  }
  static Future<LibraryBackup> fromRecords(Map<String, Object> records) =>
      compute(_createBackup, records);
  static Future<LibraryBackup> fromLocalRecords(Map<String, Object> records) =>
      compute(_createLocalBackup, records);
  Future<String> encode() =>
      compute(_encodeBackup, (createdAt: createdAt, records: records));
}

String _encodeBackup(({int createdAt, Map<String, Object> records}) backup) {
  final text = jsonEncode({
    'format': 'wenku8-local-backup',
    'version': 1,
    'createdAt': backup.createdAt,
    'records': backup.records,
  });
  if (utf8.encode(text).length > LibraryBackup.maxBytes) {
    throw const FormatException('备份超过 32 MiB，请清理冗余记录后重试');
  }
  return text;
}

LibraryBackup _createBackup(Map<String, Object> records) {
  final backup = LibraryBackup._(
    DateTime.now().millisecondsSinceEpoch,
    _validateRecords(records),
  );
  _encodeBackup((createdAt: backup.createdAt, records: backup.records));
  return backup;
}

LibraryBackup _createLocalBackup(Map<String, Object> records) {
  final sanitized = Map<String, Object>.of(records);
  final omitted = <String>[];
  for (final entry in records.entries) {
    if (!entry.key.startsWith('novel_meta_') || entry.value is! String) continue;
    final record = jsonDecode(entry.value as String);
    if (record is! Map<String, dynamic> || record['coverUrl'] == null) continue;
    final cover = record['coverUrl'];
    final uri = cover is String ? Uri.tryParse(cover) : null;
    if (cover is! String || cover.length > 2048 || uri == null || !_isAllowedCoverUrl(uri)) {
      record.remove('coverUrl');
      sanitized[entry.key] = jsonEncode(record);
      omitted.add(entry.key);
    }
  }
  final backup = _createBackup(sanitized);
  return LibraryBackup._(backup.createdAt, backup.records, omittedCoverKeys: omitted);
}

LibraryBackup _decodeBackup(String text) {
  if (text.length > LibraryBackup.maxBytes ||
      utf8.encode(text).length > LibraryBackup.maxBytes) {
    throw const FormatException('备份文件超过 32 MiB');
  }
  final raw = jsonDecode(text);
  if (raw is! Map ||
      raw['format'] != 'wenku8-local-backup' ||
      raw['version'] != 1 ||
      raw['createdAt'] is! int ||
      raw['createdAt'] < 0 ||
      raw['records'] is! Map) {
    throw const FormatException('不是受支持的文库备份文件');
  }
  return LibraryBackup._(
    raw['createdAt'],
    _validateRecords(Map<String, dynamic>.from(raw['records'])),
  );
}

Map<String, Object> _validateRecords(Map<String, dynamic> input) {
  try {
    return _validateRecordValues(input);
  } on TypeError {
    throw const FormatException('备份记录字段类型有误');
  } on RangeError {
    throw const FormatException('备份记录字段超出范围');
  }
}

Map<String, Object> _validateRecordValues(Map<String, dynamic> input) {
  if (input.length > 50000) throw const FormatException('备份记录数量过多');
  final output = <String, Object>{};
  for (final entry in input.entries) {
    final key = entry.key;
    final value = entry.value;
    if (!isLibraryRecordKey(key)) throw const FormatException('备份包含未识别的记录');
    if (_listKeys.contains(key)) {
      if (value is! List ||
          value.length > (key == 'recentSearches' ? 12 : 10000) ||
          value.any((item) => item is! String)) {
        throw const FormatException('备份列表格式有误');
      }
      final list = <String>[];
      final seen = <String>{};
      for (final item in value.cast<String>()) {
        if (key == 'recentSearches') {
          if (item.trim().isEmpty ||
              item.length > 120 ||
              RegExp(r'[\x00-\x1f]').hasMatch(item)) {
            throw const FormatException('搜索记录格式有误');
          }
          if (seen.add(item.trim().toLowerCase())) list.add(item.trim());
        } else {
          final id = int.tryParse(item);
          if (id == null || id <= 0 || id > 0x7fffffff) {
            throw const FormatException('书籍标识格式有误');
          }
          if (seen.add('$id')) list.add('$id');
        }
      }
      output[key] = List<String>.unmodifiable(list);
    } else if (backupPreferenceKeys.contains(key)) {
      final valid = switch (key) {
        'theme' => ['system', 'light', 'dark'].contains(value),
        'appLanguage' => [
          'system',
          'simplified',
          'hongKong',
          'taiwan',
        ].contains(value),
        HapticPreferences.preferenceKey => _validHaptics(value),
        AppPalettePreferences.key => _validAppPalette(value),
        'localTxtEncoding' => localTextEncodingOptions.containsKey(value),
        'shelfSort' => shelfSortValues.contains(value),
        'shelfFilter' => [
          'all',
          'unread',
          'reading',
          'finished',
          'untagged',
        ].contains(value),
        'reduceMotion' ||
        'readerKeepScreenOn' ||
        'checkAppUpdates' => value is bool,
        'appTypeface' || 'appFontId' => validFontChoice(value),
        'readerTypeface' => validFontChoice(value, follow: true),
        // Widened from 15–27 to the reader's 14–30 range; old values fit.
        'readerFontSize' => _number(
          value,
          readerFontSizeMin,
          readerFontSizeMax,
        ),
        UiPreferenceKeys.readerPreferences => _validReaderPreferences(value),
        'readerLineHeight' => _number(value, 1.3, 2.2),
        'glassBlur' => _number(value, 0, 24),
        'glassOpacity' => _number(value, 0, 1),
        _ when UiPreferenceKeys.all.contains(key) =>
          UiPreferenceKeys.valid(key, value),
        _ =>
          (key == PerformancePreferences.modeKey ||
                  PerformanceEffect.values.any(
                    (e) => e.preferenceKey == key,
                  )) &&
              value is bool,
      };
      if (!valid) throw const FormatException('偏好设置格式有误');
      output[key] = value is num ? value.toDouble() : value as Object;
    } else if (backupPurificationKeys.contains(key)) {
      output[key] = _validatePurificationRecord(key, value);
    } else if (backupReadingStatsKeys.contains(key)) {
      output[key] = _validateReadingStatsRecord(key, value);
    } else if (key.startsWith('chapter_') || key.startsWith('shelf_added_')) {
      if (value is! int ||
          value < 0 ||
          value > (key.startsWith('chapter_') ? 100000 : 1000000000000000)) {
        throw const FormatException('阅读记录格式有误');
      }
      output[key] = value;
    } else if (_tagRecordKeys.contains(key)) {
      if (value is! String || utf8.encode(value).length > 512 * 1024) {
        throw const FormatException('标签记录格式有误');
      }
      final record = jsonDecode(value);
      if (key == 'tag_defs') {
        if (record is! List || record.length > 1000) {
          throw const FormatException('标签定义过多或格式有误');
        }
        for (final entry in record) {
          if (entry is! Map) throw const FormatException('标签定义格式有误');
          final map = Map<String, Object?>.from(entry);
          final id = map['id'];
          final name = map['name'];
          final color = map['color'];
          if (id is! String ||
              id.isEmpty ||
              id.length > 128 ||
              name is! String ||
              name.isEmpty ||
              name.length > 64 ||
              color is! int ||
              color < 0) {
            throw const FormatException('标签定义格式有误');
          }
        }
      } else {
        if (record is! Map || record.length > 20000) {
          throw const FormatException('标签归属过多或格式有误');
        }
        for (final e in record.entries) {
          final bookId = int.tryParse('${e.key}');
          if (bookId == null || bookId <= 0 || bookId > 0x7fffffff) {
            throw const FormatException('标签书籍标识格式有误');
          }
          final ids = e.value;
          if (ids is! List ||
              ids.length > 1000 ||
              ids.any((t) => t is! String || t.isEmpty)) {
            throw const FormatException('标签归属格式有误');
          }
        }
      }
      output[key] = value;
    } else {
      if (value is! String || value.length > 512 * 1024) {
        throw const FormatException('书籍记录格式有误');
      }
      final record = jsonDecode(value);
      if (key.startsWith('novel_meta_')) {
        if (record is! Map<String, dynamic>) {
          throw const FormatException('书籍信息格式有误');
        }
        for (final field in [
          'title',
          'author',
          'genre',
          'summary',
          'coverUrl',
          'lastUpdate',
        ]) {
          final text = record[field];
          if (text != null &&
              (text is! String ||
                  text.length > (field == 'summary' ? 100000 : 2048))) {
            throw const FormatException('书籍信息过长或格式有误');
          }
        }
        final novel = Novel.fromSnapshot(record);
        if (novel.id != int.parse(key.substring('novel_meta_'.length))) {
          throw const FormatException('书籍标识不一致');
        }
        final url = novel.coverUrl == null
            ? null
            : Uri.tryParse(novel.coverUrl!);
        if (novel.coverUrl != null &&
            (url == null || !_isAllowedCoverUrl(url))) {
          throw const FormatException('封面地址格式有误');
        }
        final colors = record['colors'];
        if (colors != null &&
            (colors is! List ||
                colors.length > 8 ||
                colors.any(
                  (color) => color is! int || color < 0 || color > 0xffffffff,
                ))) {
          throw const FormatException('封面颜色格式有误');
        }
        output[key] = jsonEncode(novel.toSnapshot());
      } else if (key.startsWith('reading_position_')) {
        _validatePosition(record);
        output[key] = jsonEncode(record);
      } else {
        if (record is! List || record.length > 1000) {
          throw const FormatException('书签数量过多或格式有误');
        }
        final seen = <String>{};
        for (final mark in record) {
          _validateBookmark(mark, seen);
        }
        output[key] = jsonEncode(record);
      }
    }
  }
  return output;
}

bool _number(Object? value, double min, double max) =>
    value is num && value.isFinite && value >= min && value <= max;

bool _validHaptics(Object? value) {
  try {
    HapticPreferences.decode(value);
    return true;
  } on FormatException {
    return false;
  }
}

bool _validAppPalette(Object? value) {
  if (value is! String) return false;
  try {
    AppPalettePreferences.decode(value);
    return true;
  } on FormatException {
    return false;
  }
}

Object _validatePurificationRecord(String key, Object? value) {
  if (key == 'reader_purification_enabled_v1') {
    if (value is! bool) throw const FormatException('净化设置格式有误');
    return value;
  }
  if (value is! String || utf8.encode(value).length > 2 * 1024 * 1024) {
    throw const FormatException('净化规则记录过大或格式有误');
  }
  final decoded = jsonDecode(value);
  if (key == 'reader_purification_rules_v1') {
    if (decoded is! List || decoded.length > 5000) {
      throw const FormatException('净化规则数量过多或格式有误');
    }
    for (final item in decoded) {
      if (item is! Map) throw const FormatException('净化规则格式有误');
      final id = item['id'];
      final name = item['name'];
      final pattern = item['pattern'];
      final replacement = item['replacement'];
      final scopeBookId = item['scopeBookId'];
      if ((id != null && (id is! String || id.isEmpty || id.length > 256)) ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 512 ||
          pattern is! String ||
          pattern.isEmpty ||
          pattern.length > 16384 ||
          (replacement != null &&
              (replacement is! String || replacement.length > 16384)) ||
          (scopeBookId != null &&
              (scopeBookId is! int ||
                  scopeBookId <= 0 ||
                  scopeBookId > 0x7fffffff))) {
        throw const FormatException('净化规则字段格式有误');
      }
    }
    return value;
  }
  if (decoded is! Map || decoded.length > 10000) {
    throw const FormatException('段落纠错记录格式有误');
  }
  for (final entry in decoded.entries) {
    final k = entry.key;
    final v = entry.value;
    final match = k is String ? _paragraphEditKey.firstMatch(k) : null;
    if (match == null ||
        int.parse(match.group(1)!) > 0x7fffffff ||
        v is! String ||
        v.length > 65536) {
      throw const FormatException('段落纠错条目格式有误');
    }
  }
  return value;
}

String _validateReadingStatsRecord(String key, Object? value) {
  if (value is! String || utf8.encode(value).length > 4 * 1024 * 1024) {
    throw const FormatException('阅读统计记录过大或格式有误');
  }
  return key == ReadingActivityStore.preferenceKey
      ? ReadingActivityStore.validateRecord(value)
      : ReadingMomentsStore.validateRecord(value);
}

void _validateBookmark(Object? mark, Set<String> seen) {
  if (mark is! Map) throw const FormatException('书签格式有误');
  final id = mark['id'];
  final title = mark['chapterTitle'];
  final position = mark['position'];
  final quote = mark['quote'] ?? '';
  final category = mark['category'] ?? '';
  final createdAt = mark['createdAt'] is String
      ? DateTime.tryParse(mark['createdAt'] as String)
      : null;
  final createdOffset = mark['createdOffsetMinutes'];
  final rangeUpdatedAt = mark['rangeUpdatedAt'];
  final categoryAt = mark['categoryAt'];
  if (id is! String ||
      id.isEmpty ||
      id.length > 128 ||
      RegExp(r'[\x00-\x1f]').hasMatch(id) ||
      !seen.add(id) ||
      title is! String ||
      title.length > 2048 ||
      RegExp(r'[\x00-\x1f]').hasMatch(title) ||
      position is! Map ||
      quote is! String ||
      quote.length > 12000 ||
      category is! String ||
      category.length > 30 ||
      (mark['createdAt'] != null && (createdAt == null || !createdAt.isUtc)) ||
      (createdOffset != null &&
          (createdOffset is! int ||
              createdOffset < -840 ||
              createdOffset > 840 ||
              createdAt == null)) ||
      (rangeUpdatedAt != null &&
          (rangeUpdatedAt is! int ||
              rangeUpdatedAt < 0 ||
              rangeUpdatedAt > 1000000000000000)) ||
      (categoryAt != null &&
          (categoryAt is! int ||
              categoryAt < 0 ||
              categoryAt > 1000000000000000))) {
    throw const FormatException('书签格式有误');
  }
  _validatePosition(position);
  if (mark['annotation'] != null) {
    ReaderAnnotationData.fromJson(mark['annotation']);
  }
  decodeReaderUnderlineRanges(mark['underlineRanges'], position: position);
}

bool _isAllowedCoverUrl(Uri url) {
  final host = url.host.toLowerCase();
  final officialHost = host == 'wenku8.com' ||
      host.endsWith('.wenku8.com') ||
      host == 'wenku8.net' ||
      host.endsWith('.wenku8.net') ||
      host == 'wenku8.cn' ||
      host.endsWith('.wenku8.cn');
  return url.scheme == 'https' &&
      url.userInfo.isEmpty &&
      (!url.hasPort || url.port == 443) &&
      officialHost;
}

void _validatePosition(Object? record) {
  if (record is! Map ||
      record['chapter'] is! int ||
      !_number(record['chapter'], 0, 100000) ||
      record['chapterId'] is! int ||
      !_number(record['chapterId'], 0, 0x7fffffff) ||
      !_number(record['offset'], 0, 1e12) ||
      !_number(record['fraction'], 0, 1) ||
      !_number(record['fontSize'], 1, 200) ||
      !_number(record['width'], 0, 1e6) ||
      record['updatedAt'] is! int ||
      !_number(record['updatedAt'], 0, 1e15) ||
      (record['lineHeight'] != null &&
          !_number(record['lineHeight'], 1.3, 2.2)) ||
      (record['textScale'] != null && !_number(record['textScale'], .5, 5)) ||
      (record['typeface'] != null &&
          !validFontChoice(record['typeface'], follow: true)) ||
      (record['paragraphIndex'] != null &&
          (record['paragraphIndex'] is! int ||
              !_number(record['paragraphIndex'], 0, 1000000))) ||
      (record['paragraphFraction'] != null &&
          !_number(record['paragraphFraction'], 0, 1))) {
    throw const FormatException('阅读位置格式有误');
  }
}

bool _validReaderPreferences(Object? value) {
  if (value is! String || value.length > 16 * 1024) return false;
  try {
    final raw = jsonDecode(value);
    if (raw is! Map) return false;
    ReaderPreferences.fromJson(Map<String, dynamic>.from(raw));
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> writeLibraryPreference(
  SharedPreferences prefs,
  String key,
  Object? value,
) async {
  try {
    final success = switch (value) {
      null => await prefs.remove(key),
      bool v => await prefs.setBool(key, v),
      int v => await prefs.setInt(key, v),
      double v => await prefs.setDouble(key, v),
      String v => await prefs.setString(key, v),
      List<String> v => await prefs.setStringList(key, v),
      _ => throw const FormatException('Unsupported preference value'),
    };
    if (!success) throw StateError('Local preference did not commit');
  } catch (_) {
    // The legacy plugin updates its in-memory cache before returning a failed
    // platform write. Reload prevents a failed hide/favorite from surviving a
    // new LibraryState instance in the same process.
    try {
      await prefs.reload().timeout(const Duration(seconds: 1));
    } catch (_) { /* Preserve the original write error. */ }
    rethrow;
  }
}

/// An interrupted multi-key merge is rolled back before LibraryState is loaded.
/// The journal contains only allowlisted library keys, never session/API data.
Future<bool> recoverLibraryRestore(SharedPreferences prefs) async {
  final raw = prefs.get(restoreJournalKey);
  if (raw == null) return true;
  var archived = false;
  Future<bool> archive(String reason) async {
    if (archived) return true;
    try {
      await archiveRecoveryRecord(
        prefs, restoreJournalQuarantineKey, raw, reason: reason,
      );
      archived = true;
      return true;
    } catch (error) {
      recordRecoveryFailure(restoreJournalKey, error);
      return false;
    }
  }
  Future<bool> clearJournal() async {
    try {
      await writeLibraryPreference(prefs, restoreJournalKey, null);
      return true;
    } catch (error) {
      recordRecoveryFailure(restoreJournalKey, error);
      return false;
    }
  }
  late Map journal;
  try {
    if (raw is! String || raw.length > LibraryBackup.maxBytes * 2) {
      throw const FormatException('本地恢复日志格式有误');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded.length > 50000) {
      throw const FormatException('本地恢复日志格式有误');
    }
    journal = decoded;
  } catch (_) {
    if (!await archive('invalid_journal')) return false;
    return clearJournal();
  }
  var complete = true;
  for (final entry in journal.entries) {
    if (entry.key is! String || !isLibraryRecordKey(entry.key)) {
      if (!await archive('unknown_key')) complete = false;
      continue;
    }
    final value = entry.value;
    if (value != null &&
        value is! String &&
        value is! bool &&
        value is! int &&
        value is! double &&
        !(value is List && value.every((item) => item is String))) {
      if (!await archive('invalid_value')) complete = false;
      continue;
    }
    try {
      await writeLibraryPreference(
        prefs,
        entry.key,
        value is List ? List<String>.from(value) : value,
      );
    } catch (error) {
      complete = false;
      recordRecoveryFailure(restoreJournalKey, error);
      await archive('write_failed');
    }
  }
  return complete ? clearJournal() : false;
}

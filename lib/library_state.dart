import 'dart:async';
import 'dart:collection' show UnmodifiableSetView;
import 'dart:convert';
import 'dart:io';
import 'text_anchor.dart';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'library_backup.dart';
import 'library_preference_stores.dart';
import 'book_tags.dart';
import 'haptic_preferences.dart';
import 'performance_preferences.dart';
import 'app_typography.dart';
import 'local_platform.dart';
import 'local_library.dart';
import 'local_annotation_remap.dart';
import 'recovery_archive.dart';
import 'reader_underline.dart';
import 'reader_rich_content.dart';
import 'reader_annotation_range.dart';
import 'reading_activity.dart';
import 'reading_moments.dart';
import 'user_fonts.dart';
import 'font_catalog.dart';
import 'app_palette.dart';
import 'reader_preferences.dart';
import 'reader_purification.dart';
import 'ui_preferences.dart';

part 'library_backup_merge.dart';

class PalettePlatformInfo {
  const PalettePlatformInfo({
    this.colors,
    this.iconSupported = false,
    this.themedIcon = true,
  });
  final SystemTonalColors? colors;
  final bool iconSupported, themedIcon;
}

class PalettePlatform {
  const PalettePlatform();
  static const channel = MethodChannel('org.mewx.wenku8/palette');
  Future<PalettePlatformInfo> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const PalettePlatformInfo();
    }
    try {
      final map = await channel.invokeMapMethod<String, dynamic>('read');
      return PalettePlatformInfo(
        colors: SystemTonalColors.fromMap(map?['palettes']),
        iconSupported: map?['iconSupported'] == true,
        themedIcon: map?['themedIcon'] != false,
      );
    } on MissingPluginException {
      return const PalettePlatformInfo();
    }
  }

  Future<void> setThemedIcon(bool enabled) =>
      channel.invokeMethod<void>('icon', {'enabled': enabled});
}

const _libraryWriteTimeout = Duration(seconds: 8);

const _compactAppearanceMigrationKey = 'compactAppearanceMigrationV1';

// Keep the old record names readable by older backups, but remove their
// invisible overrides now that only glass tier / motion / pick pace are shown.
final _retiredAppearanceDefaults = <String, Object>{
  'reduceMotion': false,
  ...const PerformancePreferences().toRecords(),
  'glassBlur': 8.0,
  'glassOpacity': .87,
  UiPreferenceKeys.glassAdvanced: false,
};

class _StateNotifier extends ChangeNotifier {
  bool _closed = false;

  @override
  void notifyListeners() {
    if (!_closed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    super.dispose();
  }
}

class ReadingPosition {
  const ReadingPosition({
    required this.chapter,
    required this.chapterId,
    required this.offset,
    required this.fraction,
    required this.fontSize,
    required this.width,
    required this.updatedAt,
    this.lineHeight = 1.72,
    this.paragraphIndex,
    this.paragraphFraction = 0,
    this.textScale = 1,
    this.typeface = 'system',
    String? revision,
    String? contentRevision,
    this.layout = '',
    this.textOffset,
  }) : revision = revision ?? contentRevision ?? '';
  final int chapter;
  final int chapterId;
  final double offset;
  final double fraction;
  final double fontSize;
  final double width;
  final int updatedAt;
  final double lineHeight;
  final int? paragraphIndex;
  final double paragraphFraction;
  final double textScale;
  final String typeface;
  final String revision;
  final String layout;
  final int? textOffset;

  String get contentRevision => revision;

  Map<String, Object> toJson() => {
    'chapter': chapter,
    'chapterId': chapterId,
    'offset': offset,
    'fraction': fraction,
    'fontSize': fontSize,
    'width': width,
    'updatedAt': updatedAt,
    'lineHeight': lineHeight,
    'paragraphIndex': ?paragraphIndex,
    'paragraphFraction': paragraphFraction,
    'textScale': textScale,
    'typeface': typeface,
    'revision': revision,
    if (revision.isNotEmpty) 'contentRevision': revision,
    if (layout.isNotEmpty) 'layout': layout,
    'textOffset': ?textOffset,
  };

  factory ReadingPosition.fromJson(Map<String, dynamic> value) {
    double number(String key, double fallback) {
      final number = value[key];
      return number is num && number.isFinite ? number.toDouble() : fallback;
    }

    final rawRevision = value['revision'];
    final rawContentRevision = value['contentRevision'];
    return ReadingPosition(
      revision: rawRevision is String && rawRevision.isNotEmpty
          ? rawRevision
          : rawContentRevision is String
          ? rawContentRevision
          : '',
      layout: value['layout'] is String ? value['layout'] as String : '',
      textOffset: value['textOffset'] is int ? value['textOffset'] : null,
      chapter: value['chapter'] is int
          ? (value['chapter'] as int).clamp(0, 100000)
          : 0,
      chapterId: value['chapterId'] is int ? value['chapterId'] : 0,
      offset: number('offset', 0).clamp(0, double.infinity),
      fraction: number('fraction', 0).clamp(0, 1),
      fontSize: number('fontSize', 19),
      width: number('width', 0),
      updatedAt: value['updatedAt'] is int ? value['updatedAt'] : 0,
      lineHeight: number('lineHeight', 1.72).clamp(1.3, 2.2),
      paragraphIndex:
          value['paragraphIndex'] is int && value['paragraphIndex'] >= 0
          ? value['paragraphIndex']
          : null,
      paragraphFraction: number('paragraphFraction', 0).clamp(0, 1),
      textScale: number('textScale', 1).clamp(.5, 5),
      typeface: validFontChoice(value['typeface'], follow: true)
          ? value['typeface'] as String
          : 'system',
    );
  }
}

class ReaderBookmark {
  const ReaderBookmark({
    required this.id,
    required this.chapterTitle,
    required this.position,
    this.quote = '',
    this.category = '',
    this.categoryAt = 0,
    this.underlineRanges = const [],
    ReaderAnnotationData? annotation,
    this.rangeUpdatedAt = 0,
    this.createdAt,
    this.createdOffsetMinutes,
  }) : _annotation = annotation;
  final String id;
  final String chapterTitle;
  final ReadingPosition position;
  final String quote;
  final String category;
  final int categoryAt;
  final DateTime? createdAt;
  final int? createdOffsetMinutes;
  final List<ReaderUnderlineRange> underlineRanges;
  final ReaderAnnotationData? _annotation;
  final int rangeUpdatedAt;

  ReaderAnnotationData get annotation =>
      _annotation ??
      (isUnderline
          ? const ReaderAnnotationData()
          : const ReaderAnnotationData(style: ReaderMarkStyle.none));

  String get note => annotation.note;
  String get kindLabel =>
      isUnderline && annotation.style != ReaderMarkStyle.none
      ? annotation.style.label
      : '书签';
  bool get isUnderline => underlineRanges.isNotEmpty;

  ReaderBookmark copyWithId(String newId) => ReaderBookmark(
    id: newId,
    chapterTitle: chapterTitle,
    position: position,
    quote: quote,
    category: category,
    categoryAt: categoryAt,
    underlineRanges: underlineRanges,
    annotation: _annotation,
    rangeUpdatedAt: rangeUpdatedAt,
    createdAt: createdAt,
    createdOffsetMinutes: createdOffsetMinutes,
  );

  ReaderBookmark withCategory(String value, int at) => ReaderBookmark(
    id: id,
    chapterTitle: chapterTitle,
    position: position,
    quote: quote,
    category: value,
    categoryAt: at,
    underlineRanges: underlineRanges,
    annotation: annotation,
    rangeUpdatedAt: rangeUpdatedAt,
    createdAt: createdAt,
    createdOffsetMinutes: createdOffsetMinutes,
  );

  ReaderBookmark withAnnotation(ReaderAnnotationData value) => ReaderBookmark(
    id: id,
    chapterTitle: chapterTitle,
    position: position,
    quote: quote,
    category: category,
    categoryAt: categoryAt,
    underlineRanges: underlineRanges,
    annotation: value,
    rangeUpdatedAt: rangeUpdatedAt,
    createdAt: createdAt,
    createdOffsetMinutes: createdOffsetMinutes,
  );

  ReaderBookmark withRange({
    required String chapterTitle,
    required ReadingPosition position,
    required List<ReaderUnderlineRange> ranges,
    required String quote,
    required int updatedAt,
  }) => ReaderBookmark(
    id: id,
    chapterTitle: chapterTitle,
    position: position,
    quote: quote,
    category: category,
    categoryAt: categoryAt,
    underlineRanges: ranges,
    annotation: annotation,
    rangeUpdatedAt: updatedAt,
    createdAt: createdAt,
    createdOffsetMinutes: createdOffsetMinutes,
  );


  Map<String, Object> toJson() => {
    'id': id,
    'chapterTitle': chapterTitle,
    'position': position.toJson(),
    if (quote.isNotEmpty) 'quote': quote,
    if (category.isNotEmpty || categoryAt > 0) 'category': category,
    if (categoryAt > 0) 'categoryAt': categoryAt,
    if (!annotation.isEmpty ||
        isUnderline && annotation.style == ReaderMarkStyle.none)
      'annotation': annotation.toJson(),
    if (rangeUpdatedAt > 0) 'rangeUpdatedAt': rangeUpdatedAt,
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
    if (createdAt != null && createdOffsetMinutes != null)
      'createdOffsetMinutes': createdOffsetMinutes!,
    if (isUnderline)
      'underlineRanges': underlineRanges
          .map((range) => range.toJson())
          .toList(),
  };

  factory ReaderBookmark.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['chapterTitle'];
    final position = json['position'];
    final quote = json['quote'] ?? '';
    final category = json['category'] ?? '';
    final createdAt = json['createdAt'] is String
        ? DateTime.tryParse(json['createdAt'] as String)
        : null;
    final createdOffset = json['createdOffsetMinutes'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        RegExp(r'[\x00-\x1f]').hasMatch(id) ||
        title is! String ||
        title.length > 2048 ||
        RegExp(r'[\x00-\x1f]').hasMatch(title) ||
        position is! Map ||
        quote is! String ||
        quote.length > 12000 ||
        category is! String ||
        category.length > 30 ||
        (json['createdAt'] != null &&
            (createdAt == null || !createdAt.isUtc)) ||
        (createdOffset != null &&
            (createdOffset is! int ||
                createdOffset < -840 ||
                createdOffset > 840 ||
                createdAt == null)) ||
        (json['rangeUpdatedAt'] != null &&
            (json['rangeUpdatedAt'] is! int || json['rangeUpdatedAt'] < 0)) ||
        (json['categoryAt'] != null &&
            (json['categoryAt'] is! int || json['categoryAt'] < 0))) {
      throw const FormatException('Damaged bookmark');
    }
    return ReaderBookmark(
      id: id,
      chapterTitle: title,
      position: ReadingPosition.fromJson(Map<String, dynamic>.from(position)),
      quote: quote,
      category: category,
      categoryAt: json['categoryAt'] ?? 0,
      createdAt: createdAt,
      createdOffsetMinutes: createdOffset,
      annotation: json['annotation'] == null
          ? null
          : ReaderAnnotationData.fromJson(json['annotation']),
      rangeUpdatedAt: json['rangeUpdatedAt'] ?? 0,
      underlineRanges: decodeReaderUnderlineRanges(
        json['underlineRanges'],
        position: position,
      ),
    );
  }
}

class LibraryState extends ChangeNotifier {
  LibraryState(
    this._prefs, {
    this.writeWaitTimeout = _libraryWriteTimeout,
    UserFontStore? fonts,
    this.palettePlatform = const PalettePlatform(),
  }) : fonts = fonts ?? UserFontStore() {
    final activity = _prefs.get(ReadingActivityStore.preferenceKey);
    try {
      readingActivity = ReadingActivityStore(
        record: activity is String ? activity : null,
        persist: _persistReadingActivity,
      );
    } on FormatException {
      readingActivity = ReadingActivityStore(persist: _persistReadingActivity);
    }
    final moments = _prefs.get(ReadingMomentsStore.preferenceKey);
    try {
      readingMoments = ReadingMomentsStore(
        record: moments is String ? moments : null,
        persist: _persistReadingMoments,
      );
    } on FormatException {
      readingMoments = ReadingMomentsStore(persist: _persistReadingMoments);
    }
    try {
      final raw = _prefs.get('shelf');
      if (raw != null) {
        if (raw is! List) throw const FormatException('书架类型异常');
        for (final value in raw) {
          final id = value is String ? int.tryParse(value) : null;
          if (id == null || id <= 0 || id > 0x7fffffff) {
            _shelfLoadFailed = true;
          } else {
            _shelf.add(id);
          }
        }
      }
    } catch (_) {
      _shelfLoadFailed = true;
    }
    _hiddenHistory.addAll(
      ((_prefs.get('reading_history_hidden') is List<String>)
              ? _prefs.getStringList('reading_history_hidden')!
              : const <String>[])
          .map(int.tryParse)
          .whereType<int>()
          .where((id) => id > 0),
    );
    for (final key in _prefs.getKeys()) {
      if (key.startsWith('chapter_')) {
        final id = int.tryParse(key.substring('chapter_'.length));
        final value = _prefs.get(key);
        if (id != null && value is int) _chapters[id] = value.clamp(0, 100000);
      }
      if (key.startsWith('shelf_added_')) {
        final id = int.tryParse(key.substring('shelf_added_'.length));
        final value = _prefs.get(key);
        if (id != null && value is int) _added[id] = value;
      }
      if (key.startsWith('novel_meta_')) {
        try {
          final novel = Novel.fromSnapshot(
            jsonDecode(_prefs.getString(key)!) as Map<String, dynamic>,
          );
          _known[novel.id] = novel;
          _persistedNovels[novel.id] = novel;
        } catch (_) {
          // A damaged cache never removes its saved shelf ID or preferences.
        }
      }
      if (key.startsWith('reading_position_')) {
        final id = int.tryParse(key.substring('reading_position_'.length));
        if (id == null) continue;
        try {
          _positions[id] = ReadingPosition.fromJson(
            jsonDecode(_prefs.getString(key)!) as Map<String, dynamic>,
          );
        } catch (_) {
          // The legacy chapter index remains usable without a position record.
        }
      }
      if (key.startsWith('reader_bookmarks_')) {
        final id = int.tryParse(key.substring('reader_bookmarks_'.length));
        if (id == null || id <= 0) continue;
        try {
          final records = jsonDecode(_prefs.getString(key)!);
          if (records is! List) continue;
          final bookmarks = <ReaderBookmark>[];
          final ids = <String>{};
          for (final record in records) {
            try {
              final bookmark = ReaderBookmark.fromJson(
                Map<String, dynamic>.from(record as Map),
              );
              if (ids.add(bookmark.id)) bookmarks.add(bookmark);
            } catch (_) {
              // One damaged bookmark does not erase the remaining marks.
            }
          }
          bookmarks.sort(
            (a, b) => b.position.updatedAt.compareTo(a.position.updatedAt),
          );
          _bookmarks[id] = bookmarks;
          _updateUnderlineIndex(id, notify: false);
        } catch (_) {
          // Resume records are independent of the bookmark list.
        }
      }
    }
    this.fonts.migrateLegacyPreferences(_prefs);
    _readerStore.load(fonts: this.fonts);
    _appearanceStore.load();
    _performanceStore.load();
    final recent = _prefs.get('recentSearches');
    if (recent is List<String>) {
      final seen = <String>{};
      _recentSearches = recent
          .map((query) => query.trim())
          .where(
            (query) =>
                validSearchHistory(query) && seen.add(query.toLowerCase()),
          )
          .take(12)
          .toList(growable: false);
    }
  }

  final Duration writeWaitTimeout;
  final SharedPreferences _prefs;
  late final ReaderSettingsPreferenceStore _readerStore =
      ReaderSettingsPreferenceStore(_prefs);
  late final AppearancePreferenceStore _appearanceStore =
      AppearancePreferenceStore(_prefs);
  late final PerformancePreferenceStore _performanceStore =
      PerformancePreferenceStore(_prefs);
  final UserFontStore fonts;
  final PalettePlatform palettePlatform;
  AppPalettePreferences get appPalette => _appearanceStore.appPalette;
  SystemTonalColors? systemTonalColors;
  bool paletteLoaded = false, themedIconSupported = false;
  String? paletteError;
  Future<void>? _paletteLoad;
  Future<void> refreshSystemPalette() => _paletteLoad ??= _readSystemPalette()
      .whenComplete(() => _paletteLoad = null);
  Future<void> _readSystemPalette() async {
    try {
      final info = await palettePlatform.read();
      if (_disposed) return;
      final changed = systemTonalColors?.signature != info.colors?.signature;
      systemTonalColors = info.colors;
      themedIconSupported = info.iconSupported;
      paletteError = null;
      if (info.iconSupported) {
        await _queuePositionWrite(() async {
          if (_appearanceStore.appPalette.themedIcon != info.themedIcon) {
            await palettePlatform.setThemedIcon(
              _appearanceStore.appPalette.themedIcon,
            );
          }
        });
      }
      if (changed &&
          !_disposed &&
          _appearanceStore.appPalette.source == AppPaletteSource.system) {
        _application.notifyListeners();
        _appearance.notifyListeners();
      }
    } catch (_) {
      if (!_disposed) paletteError = '系统配色读取未完成，请重试';
    } finally {
      if (!_disposed) {
        paletteLoaded = true;
        _settings.notifyListeners();
      }
    }
  }

  Future<void> setAppPalette(AppPalettePreferences value) async {
    if (_restoreBarrier case final barrier?) {
      await barrier.future;
      return setAppPalette(value);
    }
    AppPalettePreferences.decode(value.encode());
    if (value.source == AppPaletteSource.system && systemTonalColors == null) {
      throw const FormatException('当前设备未提供系统配色，请选择自选配色');
    }
    await _queuePositionWrite(() async {
      final before = _appearanceStore.appPalette;
      if (before == value) return;
      final iconChanged = before.themedIcon != value.themedIcon;
      if (iconChanged) {
        if (!themedIconSupported) throw const FormatException('当前设备不支持切换主题图标');
        await palettePlatform.setThemedIcon(value.themedIcon);
      }
      try {
        await _appearanceStore.writeAppPalette(value);
      } catch (_) {
        if (iconChanged) await palettePlatform.setThemedIcon(before.themedIcon);
        rethrow;
      }
      _appearanceStore.appPalette = value;
      if (!_disposed) {
        if (before.source != value.source || before.seed != value.seed) {
          _application.notifyListeners();
          _appearance.notifyListeners();
        }
        _settings.notifyListeners();
      }
    });
  }

  String? fontError;
  String get appFontChoice => _readerStore.appFontId == appFontSystem.id
      ? 'system'
      : _readerStore.appFontId == appFontSourceHanSerif.id
      ? 'sourceHanSerif'
      : _readerStore.appFontId;
  bool independentReaderStyle(int id) => false;
  String readerTypefaceFor(int? id) => _readerStore.readerTypeface;
  String fontLabel(String choice) {
    if (choice == followAppFont) {
      return '跟随应用（${fontLabel(appFontChoice)}）';
    }
    for (final f in allFonts) {
      if (f.id == choice) return f.displayName;
    }
    return fonts.label(choice);
  }

  Future<void> loadFonts() async {
    try {
      await fonts.load();
      await ensureFontLoaded();
      fontError = null;
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
      }
    } catch (_) {
      fontError = '自定义字体读取失败，暂用系统字体；可在字体设置中重试。';
    }
  }

  Future<void> downloadReadingFont([String id = sourceHanFontId]) async {
    await fonts.downloadFont(id);
    await loadFonts();
  }

  Future<void> setReaderTypeface(String choice, {int? bookId}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setReaderTypeface(choice, bookId: bookId),
      );
    }
    if (choice != followAppFont) {
      if (!fonts.available(choice)) {
        throw const FormatException('请先导入这款字体');
      }
      await fonts.ensureLoaded(choice);
    }
    await _queuePositionWrite(() async {
      if (_readerStore.readerTypeface == choice) return;
      await _commitLibraryRecords({'readerTypeface': choice});
      _readerStore.readerTypeface = choice;
      if (!_disposed) {
        _application.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
        notifyListeners();
      }
    });
  }

  Future<void> removeUserFont(String id) async {
    if (appFontChoice == id) await setAppFont(appFontSystem.id);
    if (_readerStore.readerTypeface == id) {
      await setReaderTypeface(followAppFont);
    }
    try {
      await fonts.remove(id);
    } finally {
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
        notifyListeners();
      }
    }
  }

  late final ReadingActivityStore readingActivity;
  late final ReadingMomentsStore readingMoments;
  final _appearance = _StateNotifier();
  final _application = _StateNotifier();
  final _glassChanges = _StateNotifier();
  final _readerSettings = _StateNotifier();
  final _settings = _StateNotifier();
  final _history = _StateNotifier();
  final _bookmarkChanges = _StateNotifier();
  final _underlineChanges = _StateNotifier();
  final _searchChanges = _StateNotifier();
  final _shelfViewChanges = _StateNotifier();
  final _readerBehaviorChanges = _StateNotifier();
  final Set<int> _shelf = {};
  late final Set<int> _shelfView = UnmodifiableSetView(_shelf);
  bool _shelfLoadFailed = false;
  final Set<int> _hiddenHistory = {};
  final Map<int, Novel> _known = {};
  final Map<int, Novel> _persistedNovels = {};
  final Map<int, int> _chapters = {};
  final Map<int, ReadingPosition> _positions = {};
  final Map<int, int> _added = {};
  final Map<int, List<ReaderBookmark>> _bookmarks = {};
  final Map<int, List<ReaderUnderlineRange>> _underlineRanges = {};
  final Map<int, Map<int, List<ReaderUnderlineRange>>> _underlinesByChapter =
      {};
  final Map<int, List<ReaderAnnotationRange>> _annotationRanges = {};
  final Map<int, Map<int, List<ReaderAnnotationRange>>> _annotationsByChapter =
      {};
  final Map<int, int> _shelfRevisions = {};
  List<String> _recentSearches = const [];
  int _metadataEncodes = 0;
  Future<void>? _positionWrites;
  Completer<void>? _restoreBarrier;
  DeviceProfile _deviceProfile = const DeviceProfile();
  bool _disposed = false;
  bool _historyNotificationQueued = false;

  static Future<LibraryState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final recovered = await recoverLibraryRestore(prefs);
    final state = LibraryState(prefs);
    if (prefs.get(_compactAppearanceMigrationKey) != true) {
      // Never overwrite an unresolved restore journal. All writes are
      // idempotent and the marker is committed last, so failed migrations retry.
      if (recovered) {
        try {
          await state._commitLibraryRecords({
            for (final entry in _retiredAppearanceDefaults.entries)
              if (prefs.containsKey(entry.key)) entry.key: entry.value,
          });
          await writeLibraryPreference(
            prefs,
            _compactAppearanceMigrationKey,
            true,
          );
        } catch (error) {
          recordRecoveryFailure(_compactAppearanceMigrationKey, error);
        }
      }
      // The removed controls cannot silently restrict rendering even if disk
      // recovery must wait until the next launch.
      state._resetRetiredAppearance();
    }
    return state;
  }

  void _resetRetiredAppearance() {
    _performanceStore.resetRetired();
    _appearanceStore.resetRetired();
  }

  Set<int> get shelf => _shelfView;
  bool get shelfLoadFailed => _shelfLoadFailed;

  void _requireShelfLoaded() {
    if (_shelfLoadFailed) throw StateError('书架读取失败，已禁止覆盖书架');
  }

  Future<void> repairShelf() async {
    if (_restoreBarrier case final barrier?) {
      await barrier.future;
      return repairShelf();
    }
    await _queuePositionWrite(() async {
      final raw = _prefs.get('shelf');
      final repaired = <int>{};
      var damaged = raw != null && raw is! List;
      if (raw is List) {
        for (final value in raw) {
          final id = value is String ? int.tryParse(value) : null;
          if (id == null || id <= 0 || id > 0x7fffffff) {
            damaged = true;
          } else {
            repaired.add(id);
          }
        }
      }
      if (damaged) {
        await archiveRecoveryRecord(
          _prefs, 'library_shelf_quarantine_v1', raw!, reason: 'invalid_shelf',
        );
        await _commitLibraryRecords(
          {'shelf': repaired.map((id) => '$id').toList()}, repairingShelf: true,
        );
      }
      for (final id in {..._shelf, ...repaired}) {
        if (_shelf.contains(id) != repaired.contains(id)) {
          _shelfRevisions[id] = shelfRevision(id) + 1;
        }
      }
      _shelf
        ..clear()
        ..addAll(repaired);
      _shelfLoadFailed = false;
      notifyListeners();
    });
  }
  Listenable get appearanceChanges => _appearance;
  Listenable get applicationChanges => _application;
  Listenable get glassChanges => _glassChanges;
  Listenable get readerSettingsChanges => _readerSettings;
  Listenable get settingsChanges => _settings;
  Listenable get historyChanges => _history;
  Listenable get bookmarkChanges => _bookmarkChanges;
  Listenable get underlineChanges => _underlineChanges;
  Listenable get searchChanges => _searchChanges;
  Listenable get shelfViewChanges => _shelfViewChanges;
  Listenable get readerBehaviorChanges => _readerBehaviorChanges;
  List<String> get recentSearches => List.unmodifiable(_recentSearches);
  String get shelfSort => _appearanceStore.shelfSort;
  String get shelfFilter => _appearanceStore.shelfFilter;
  bool get keepScreenOn => _readerStore.keepScreenOn;
  ThemeMode get theme => _appearanceStore.theme;
  double get fontSize => _readerStore.fontSize;
  double get lineHeight => _readerStore.lineHeight;
  int get debugMetadataEncodeCount => _metadataEncodes;
  // Existing route/reader callers must follow the visible motion selector too.
  bool get reduceMotion =>
      _performanceStore.reduceMotion ||
      _performanceStore.motionLevel == MotionLevel.off;
  HapticPreferences get haptics => _performanceStore.haptics;

  /// 当前字体 ID（稳定 ID，持久化）。
  String get appFontId => _readerStore.appFontId;

  String? get appFontFamily => currentFont.family;

  String get effectiveReaderFontId =>
      _readerStore.readerTypeface == followAppFont
          ? _readerStore.appFontId
          : _readerStore.readerTypeface;

  String? fontFamilyFor(String id) {
    if (id == followAppFont) return appFontFamily;
    for (final f in allFonts) {
      if (f.id == id) return f.family;
    }
    return fonts.family(id);
  }

  String? get readerFontFamily => fontFamilyFor(effectiveReaderFontId);

  List<String> get readerFontFamilyFallback {
    final family = readerFontFamily;
    if (family == null || family == appFontSourceHanSerif.family) {
      return const [];
    }
    return const ['SourceHanSerifCN'];
  }

  /// 全部可用字体：系统、内置、已导入与已下载字库。
  List<AppFontEntry> get allFonts => [
        appFontSystem,
        appFontSourceHanSerif,
        for (final font in fonts.fonts) font.toAppFontEntry(),
        for (final dl in downloadableFonts)
          if (dl.id != appFontSourceHanSerif.id && fonts.available(dl.id))
            AppFontEntry(
              id: dl.id,
              displayName: dl.name,
              family: dl.typeface.family,
              source: AppFontSource.bundled,
            ),
      ];

  List<AppFontEntry> get importedFonts =>
      List.unmodifiable(fonts.fonts.map((f) => f.toAppFontEntry()));

  /// 当前字体条目；ID 失效时回退到系统字体。
  AppFontEntry get currentFont {
    for (final f in allFonts) {
      if (f.id == _readerStore.appFontId) return f;
    }
    return appFontSystem;
  }

  /// 缺字回退链：用户字体 → 内置思源宋体 → 系统。
  List<String> get fontFamilyFallback {
    final family = currentFont.family;
    if (family == null || family == appFontSourceHanSerif.family) {
      return const [];
    }
    return const ['SourceHanSerifCN'];
  }

  /// 兼容旧代码：由字体 ID 映射回枚举。
  AppTypeface get appTypeface =>
      _readerStore.appFontId == appFontSourceHanSerif.id
          ? AppTypeface.sourceHanSerif
          : AppTypeface.system;
  PerformancePreferences get performance => _performanceStore.performance;
  bool get effectiveReduceMotion =>
      _performanceStore.reduceMotion ||
      !_performanceStore.performance.motion ||
      _performanceStore.motionLevel == MotionLevel.off;
  double get glassBlur => _appearanceStore.glassBlur;
  double get glassOpacity => _appearanceStore.glassOpacity;

  /// Null means the tier is chosen automatically from [deviceProfile].
  GlassTier? get glassTierChoice => _appearanceStore.glassTier;
  bool get glassAdvanced => _appearanceStore.glassAdvanced;
  DeviceProfile get deviceProfile => _deviceProfile;
  MotionLevel get motionLevel => _performanceStore.motionLevel;
  RandomPickPace get randomPickPace => _appearanceStore.randomPickPace;
  bool get pdfNightInvert => _readerStore.pdfNightInvert;
  ShelfLayout get shelfLayout => _appearanceStore.shelfLayout;
  TagMatchMode get tagMatchMode => _appearanceStore.tagMatchMode;
  OriginalPaletteVariant get paletteVariant => _appearanceStore.paletteVariant;
  ReaderPreferences get readerPreferences => _readerStore.readerPreferences;

  /// Tier, advanced sliders and the custom switches resolved together.
  ResolvedGlass get resolvedGlass => resolveGlass(
    chosen: _appearanceStore.glassTier,
    lowEndDevice: _deviceProfile.lowEnd,
    advanced: _appearanceStore.glassAdvanced,
    sliderBlur: _appearanceStore.glassBlur,
    sliderOpacity: _appearanceStore.glassOpacity,
    custom: _performanceStore.performance,
  );

  /// What PerformanceScope publishes. [performance] stays the raw custom
  /// switches so the settings page and old records keep their meaning.
  PerformancePreferences get effectivePerformance =>
      resolvedGlass.performance;

  bool contains(int id) => _shelf.contains(id);
  int chapterFor(int id) => _chapters[id] ?? _positions[id]?.chapter ?? 0;
  Novel? cachedNovel(int id) => _known[id];
  ReadingPosition? positionFor(int id) {
    if (_positions[id] case final position?) return position;
    Map<String, dynamic>? anchor;
    try {
      anchor = _readJsonObjectPreference(_chapterProgressAnchorKey(id));
    } catch (_) {
      return null;
    }
    if (anchor == null || anchor['chapter'] != _chapters[id]) return null;
    if (_chapters[id] == null || anchor['fraction'] is! num ||
        !(anchor['fraction'] as num).isFinite) {
      return null;
    }
    return ReadingPosition(
      chapter: _chapters[id]!,
      chapterId: _chapters[id]!,
      offset: 0,
      fraction: (anchor['fraction'] as num).toDouble().clamp(0, 1),
      fontSize: fontSize,
      width: 0,
      updatedAt: 0,
    );
  }

  List<ReaderBookmark> bookmarksFor(int id) =>
      List.unmodifiable(_bookmarks[id] ?? const <ReaderBookmark>[]);

  List<ReaderUnderlineRange> underlinesFor(int id, {int? chapterId}) =>
      chapterId == null
      ? _underlineRanges[id] ?? const []
      : _underlinesByChapter[id]?[chapterId] ?? const [];

  List<ReaderAnnotationRange> annotationsFor(int id, {int? chapterId}) =>
      chapterId == null
      ? _annotationRanges[id] ?? const []
      : _annotationsByChapter[id]?[chapterId] ?? const [];

  bool _updateUnderlineIndex(int id, {bool notify = true}) {
    final styledMarks =
        List<ReaderBookmark>.of(_bookmarks[id] ?? const <ReaderBookmark>[])
          ..sort((a, b) {
            final edited = b.annotation.updatedAt.compareTo(
              a.annotation.updatedAt,
            );
            return edited != 0 ? edited : b.id.compareTo(a.id);
          });
    final annotations = <ReaderAnnotationRange>[
      for (final mark in styledMarks)
        for (final range in mark.underlineRanges)
          ReaderAnnotationRange(
            range,
            mark.annotation.style,
            mark.annotation.color,
            bookmarkId: mark.id,
          ),
    ];
    final ranges =
        <ReaderUnderlineRange>[
          for (final mark in _bookmarks[id] ?? const <ReaderBookmark>[])
            ...mark.underlineRanges,
        ]..sort((a, b) {
          for (final pair in [
            (a.chapterId, b.chapterId),
            (a.startParagraph, b.startParagraph),
            (a.startOffset, b.startOffset),
            (a.endParagraph, b.endParagraph),
            (a.endOffset, b.endOffset),
          ]) {
            final order = pair.$1.compareTo(pair.$2);
            if (order != 0) return order;
          }
          return a.contentRevision.compareTo(b.contentRevision);
        });
    if (listEquals(_underlineRanges[id] ?? const [], ranges) &&
        listEquals(_annotationRanges[id] ?? const [], annotations)) {
      return false;
    }
    final previous = _underlinesByChapter[id];
    final chapters = <int, List<ReaderUnderlineRange>>{};
    for (final range in ranges) {
      (chapters[range.chapterId] ??= []).add(range);
    }
    _underlineRanges[id] = List.unmodifiable(ranges);
    _underlinesByChapter[id] = {
      for (final entry in chapters.entries)
        entry.key: listEquals(previous?[entry.key], entry.value)
            ? previous![entry.key]!
            : List.unmodifiable(entry.value),
    };
    _annotationRanges[id] = List.unmodifiable(annotations);
    final styledChapters = <int, List<ReaderAnnotationRange>>{};
    for (final item in annotations) {
      (styledChapters[item.range.chapterId] ??= []).add(item);
    }
    final oldStyled = _annotationsByChapter[id];
    _annotationsByChapter[id] = {
      for (final entry in styledChapters.entries)
        entry.key: listEquals(oldStyled?[entry.key], entry.value)
            ? oldStyled![entry.key]!
            : List.unmodifiable(entry.value),
    };
    if (notify && !_disposed) _underlineChanges.notifyListeners();
    return true;
  }


  List<({int novelId, ReaderBookmark bookmark})> get bookmarkEntries {
    final entries =
        [
          for (final entry in _bookmarks.entries)
            for (final mark in entry.value)
              (novelId: entry.key, bookmark: mark),
        ]..sort(
          (a, b) => b.bookmark.position.updatedAt.compareTo(
            a.bookmark.position.updatedAt,
          ),
        );
    return List.unmodifiable(entries);
  }

  Set<int> get recordedReadingIds =>
      Set.unmodifiable({..._chapters.keys, ..._positions.keys});

  int? chapterForPosition(Novel novel, ReadingPosition position) {
    if (position.revision.isNotEmpty &&
        novel.chapters.isNotEmpty &&
        position.revision != novel.chapters.first.revision) {
      return null;
    }
    if (position.chapterId > 0) {
      final chapters = novel.chapters;
      if (position.chapter >= 0 &&
          position.chapter < chapters.length &&
          chapters[position.chapter].id == position.chapterId) {
        return position.chapter;
      }
      if (position.chapterId < chapters.length &&
          chapters[position.chapterId].id == position.chapterId) {
        return position.chapterId;
      }
      final index = chapters.indexWhere(
        (chapter) => chapter.id == position.chapterId,
      );
      return index < 0 ? null : index;
    }
    return position.chapter >= 0 && position.chapter < novel.chapters.length
        ? position.chapter
        : null;
  }

  bool hasRead(int id) =>
      _chapters.containsKey(id) || _positions.containsKey(id);
  int addedAt(int id) => _added[id] ?? 0;
  int shelfRevision(int id) => _shelfRevisions[id] ?? 0;
  int lastReadAt(int id) => _positions[id]?.updatedAt ?? 0;

  bool finishedReading(Novel novel) {
    final count = novel.chapters.isEmpty
        ? novel.chapterCount
        : novel.chapters.length;
    if (count <= 0) return false;
    final position = positionFor(novel.id);
    if (position == null) {
      final book = _localChapters?.bookFor(novel.id);
      if (book?.kind == LocalBookKind.pdf) {
        return _chapters.containsKey(novel.id) &&
            chapterFor(novel.id) >= count - 1;
      }
      return false;
    }
    if (position.fraction < .995) {
      return false;
    }
    if (position.chapterId > 0 && novel.chapters.isNotEmpty) {
      return novel.chapters.last.id == position.chapterId;
    }
    return position.chapter == count - 1;
  }

  static bool validSearchHistory(String query) =>
      query.isNotEmpty &&
      query.length <= 120 &&
      !RegExp(r'[\x00-\x1f]').hasMatch(query);

  Future<void> recordSearch(String query) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => recordSearch(query));
    }
    final term = query.trim();
    if (!validSearchHistory(term)) return Future.value();
    return _queuePositionWrite(() async {
      if (_recentSearches.isNotEmpty && _recentSearches.first == term) return;
      final next = [
        term,
        ..._recentSearches.where(
          (old) => old.toLowerCase() != term.toLowerCase(),
        ),
      ].take(12).toList(growable: false);
      await writeLibraryPreference(_prefs, 'recentSearches', next);
      _recentSearches = next;
      if (!_disposed) _searchChanges.notifyListeners();
    });
  }

  Future<void> clearRecentSearches() {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => clearRecentSearches());
    }
    return _queuePositionWrite(() async {
      await writeLibraryPreference(_prefs, 'recentSearches', <String>[]);
      _recentSearches = const [];
      if (!_disposed) _searchChanges.notifyListeners();
    });
  }

  Future<void> setShelfView({String? sort, String? filter}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setShelfView(sort: sort, filter: filter),
      );
    }
    await _queuePositionWrite(() async {
      final nextSort = sort != null && shelfSortValues.contains(sort)
          ? sort
          : _appearanceStore.shelfSort;
      final nextFilter =
          ['all', 'unread', 'reading', 'finished', 'untagged'].contains(filter)
          ? filter!
          : _appearanceStore.shelfFilter;
      await _commitLibraryRecords({
        'shelfSort': nextSort,
        'shelfFilter': nextFilter,
      });
      if (nextSort != _appearanceStore.shelfSort ||
          nextFilter != _appearanceStore.shelfFilter) {
        _appearanceStore.shelfSort = nextSort;
        _appearanceStore.shelfFilter = nextFilter;
        if (!_disposed) _shelfViewChanges.notifyListeners();
      }
    });
  }

  Future<void> setKeepScreenOn(bool value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setKeepScreenOn(value));
    }
    await _queuePositionWrite(() async {
      await _readerStore.writeKeepScreenOn(value);
      if (_readerStore.keepScreenOn != value) {
        _readerStore.keepScreenOn = value;
        if (!_disposed) {
          _readerBehaviorChanges.notifyListeners();
          _settings.notifyListeners();
        }
      }
    });
  }

  List<int> get readingHistoryIds {
    final ids =
        {
            ..._chapters.keys,
            ..._positions.keys,
          }.where((id) => id > 0 && !_hiddenHistory.contains(id)).toList()
          ..sort((a, b) {
            final time = lastReadAt(b).compareTo(lastReadAt(a));
            return time != 0 ? time : a.compareTo(b);
          });
    return List.unmodifiable(ids);
  }

  void _historyChanged() {
    if (_disposed) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_historyNotificationQueued) return;
      _historyNotificationQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _historyNotificationQueued = false;
        if (!_disposed) _history.notifyListeners();
      });
      return;
    }
    _history.notifyListeners();
  }

  Future<void> _queuePositionWrite(Future<void> Function() write) {
    Future<void> run() async {
      if (_prefs.get(restoreJournalKey) != null) {
        if (!await recoverLibraryRestore(_prefs)) {
          throw StateError('恢复记录尚未处理完成，已保留原记录，请恢复存储后重试');
        }
      }
      await write();
    }

    // An idle store must start in the caller's zone. Retaining a completed
    // Future created at load time stalls widget-test callers in FakeAsync.
    final pending = _positionWrites;
    final next = pending == null ? run() : pending.then((_) => run());
    final barrier = next.then<void>((_) {}, onError: (Object _) {});
    _positionWrites = barrier;
    return next.whenComplete(() {
      if (identical(_positionWrites, barrier)) _positionWrites = null;
    });
  }

  // Bound the caller's wait without replacing _positionWrites: the queued
  // save/migration remains ordered and can finish when storage recovers.
  Future<T> _withWriteTimeout<T>(Future<T> future, String operation) =>
      future.timeout(
        writeWaitTimeout,
        onTimeout: () => throw LocalOperationTimeoutException('$operation（待办已保留）'),
      );

  /// Hide history without destroying resume positions, shelf or body files.
  Future<void> hideReadingHistory(int id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => hideReadingHistory(id));
    }
    return _queuePositionWrite(() async {
      if (id <= 0 || !hasRead(id) || _hiddenHistory.contains(id)) return;
      final next = {..._hiddenHistory, id};
      await writeLibraryPreference(
        _prefs,
        'reading_history_hidden',
        next.map((id) => '$id').toList(),
      );
      _hiddenHistory
        ..clear()
        ..addAll(next);
      _historyChanged();
    });
  }

  /// 彻底清除某本书的阅读进度、章节与历史隐藏标记（用于源文件被删除时）。
  /// 即使内存中没有条目，也尝试删除持久化键，保证重试能清干净。
  Future<void> clearBookProgress(int id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => clearBookProgress(id));
    }
    return _queuePositionWrite(() async {
      if (id <= 0) return;
      final hidden = {..._hiddenHistory}..remove(id);
      final changes = <String, Object?>{
        'reading_position_$id': null,
        'chapter_$id': null,
        _chapterProgressAnchorKey(id): null,
        'reader_bookmarks_$id': null,
        'listening.cursor.v1.$id': null,
        'novel_meta_$id': null,
        'reading_history_hidden': hidden.map((value) => '$value').toList(),
      };
      final previous = {for (final key in changes.keys) key: _prefs.get(key)};
      try {
        for (final entry in changes.entries) {
          await writeLibraryPreference(_prefs, entry.key, entry.value);
        }
      } catch (_) {
        for (final entry in previous.entries) {
          await writeLibraryPreference(_prefs, entry.key, entry.value);
        }
        rethrow;
      }
      _positions.remove(id);
      _chapters.remove(id);
      _hiddenHistory.remove(id);
      _known.remove(id);
      _persistedNovels.remove(id);
      _bookmarks.remove(id);
      _underlineRanges.remove(id);
      _underlinesByChapter.remove(id);
      _annotationRanges.remove(id);
      _annotationsByChapter.remove(id);
      if (!_disposed) {
        _bookmarkChanges.notifyListeners();
        _underlineChanges.notifyListeners();
      }
      _historyChanged();
      notifyListeners();
    });
  }

  LocalLibraryStore? _localChapters;
  LocalLibraryStore? get localLibrary => _localChapters;
  SharedPreferences get preferences => _prefs;
  final Map<int, Future<void>> _chapterMigrations = {};
  void bindLocalChapters(LocalLibraryStore local) {
    _localChapters = local;
    local.migrateProgress = migrateLocalChapterTask;
  }

  bool _acceptLocalPosition(Novel novel, int chapter) =>
      !isLocalNovelId(novel.id) ||
      _localChapters == null ||
      chapter >= 0 &&
          chapter < novel.chapters.length &&
          _localChapters!.acceptsChapter(novel.id, novel.chapters[chapter]);

  bool _acceptLocalSavePosition(Novel novel, int chapter) {
    if (_acceptLocalPosition(novel, chapter)) return true;
    final book = _localChapters?.bookFor(novel.id);
    return book != null &&
        book.kind == LocalBookKind.pdf &&
        chapter >= 0 &&
        chapter < book.pageCount;
  }

  /// All consumers are prepared together before any progress is overwritten.
  /// Replay writes the journal's target records, never reinterprets new offsets.
  Future<void> migrateLocalChapterTask(
    LocalChapterRemap task, {
    bool readingAlreadyMigrated = false,
  }) {
    final previous = _chapterMigrations[task.bookId] ?? Future<void>.value();
    final next = previous.then((_) => _migrateLocalChapterTask(
      task, readingAlreadyMigrated: readingAlreadyMigrated));
    final drained = next.then<void>((_) {}, onError: (Object _) {});
    _chapterMigrations[task.bookId] = drained;
    unawaited(drained.then((_) {
      if (identical(_chapterMigrations[task.bookId], drained)) {
        _chapterMigrations.remove(task.bookId);
      }
    }));
    return _withWriteTimeout(next, '阅读进度迁移');
  }

  Future<void> _migrateLocalChapterTask(
    LocalChapterRemap task, {
    required bool readingAlreadyMigrated,
  }) {
    if (task.newTextPath.isEmpty) {
      final local = _localChapters;
      final book = local?.bookFor(task.bookId);
      if (book == null) {
        return remapChapterProgress(task.bookId, oldChapters: task.oldChapters,
          newChapters: task.newChapters, migrationId: task.migrationId);
      }
      // v2 journals contain ranges only: those tasks were always re-splits of
      // the same normalized text. Enrich them before migrating all consumers.
      final legacyJournal = _readJsonObjectPreference(_remapJournalKey(task.bookId, task.migrationId));
      final finalTable = task.newChapters.length == book.chapters.length &&
          List.generate(book.chapters.length, (i) =>
            task.newChapters[i].offset == book.chapters[i].offset &&
            task.newChapters[i].length == book.chapters[i].length).every((v) => v);
      final enriched = LocalChapterRemap(
        migrationId: '${task.migrationId}:anchors-v3', bookId: task.bookId,
        oldChapters: task.oldChapters, newChapters: task.newChapters,
        oldTextPath: local!.textPathFor(book), newTextPath: local.textPathFor(book),
        newRevision: finalTable ? book.revision : 'legacy-${task.migrationId}',
        newTitles: finalTable ? book.chapters.map((c) => c.title).toList() : const [],
      );
      if (legacyJournal != null) {
        return remapChapterProgress(task.bookId, oldChapters: task.oldChapters,
          newChapters: task.newChapters, migrationId: task.migrationId).then((_) =>
            _migrateLocalChapterTask(enriched, readingAlreadyMigrated: true));
      }
      return _migrateLocalChapterTask(enriched, readingAlreadyMigrated: false);
    }
    return (() async {
      final id = task.bookId;
      final key = _remapJournalKey(id, task.migrationId);
      final sourceKeys = ['reading_position_$id', 'chapter_$id',
        _chapterProgressAnchorKey(id), 'reader_bookmarks_$id', 'listening.cursor.v1.$id'];
      late Map<String, Object?> sourceRecords;
      Map<String, dynamic>? journal;
      ReadingPosition? current;
      List<ReaderBookmark>? marks;
      await _queuePositionWrite(() async {
        sourceRecords = {for (final source in sourceKeys) source: _prefs.get(source)};
        journal = _readJsonObjectPreference(key);
        current = positionFor(id) ?? (_chapters.containsKey(id) ? ReadingPosition(
          chapter: _chapters[id]!, chapterId: _chapters[id]!, offset: 0, fraction: 0,
          fontSize: fontSize, width: 0, updatedAt: 0) : null);
        marks = _bookmarks[id] == null ? null : List.of(_bookmarks[id]!);
      });
      if (journal?['status'] == 'done') return;
      final quarantined = <Object>[];
      if (journal == null &&
          current == null && (marks?.isEmpty ?? true) &&
          sourceRecords['listening.cursor.v1.$id'] == null) {
        journal = {'version': 2, 'bookId': id, 'status': 'prepared', 'records': <String, Object?>{}};
      }
      if (journal == null) {
        final oldText = await FileTextAnchor.open(task.oldTextPath);
        final newText = task.newTextPath == task.oldTextPath
            ? oldText : await FileTextAnchor.open(task.newTextPath);
        final chapters = [
          for (var i = 0; i < task.newChapters.length; i++)
            LocalChapterIndex(
              i < task.newTitles.length ? task.newTitles[i] : '正文',
              task.newChapters[i].offset,
              task.newChapters[i].length,
            ),
        ];
        Future<ReadingPosition> migrate(
          ReadingPosition position, {
          int withinParagraph = 0,
        }) async {
          if (position.revision == task.newRevision) return position;
          if (task.oldRevision.isNotEmpty && position.revision.isNotEmpty &&
              position.revision != task.oldRevision) {
            throw const FormatException('阅读锚点属于其他目录修订');
          }
          if (position.chapter < 0 ||
              position.chapter >= task.oldChapters.length) {
            throw const FormatException('旧阅读章节越界');
          }
          final old = task.oldChapters[position.chapter];
          final start = old.offset.clamp(0, oldText.length);
          final end = (old.offset + old.length).clamp(start, oldText.length);
          final range = await oldText.trimmedRange(start, end);
          final bodyLength = range.end - range.start;
          int local;
          if (position.textOffset != null) {
            local = position.textOffset!;
          } else if (position.paragraphIndex != null) {
            final para = await oldText.paragraphAt(
              range.start,
              range.end,
              stopAt: position.paragraphIndex!,
            );
            if (para.index == position.paragraphIndex! &&
                para.start + withinParagraph <= bodyLength) {
              local = para.start + withinParagraph;
            } else if (bodyLength <= FileTextAnchor.maxSliceLength) {
              final reflowed = reflowReaderParagraphsWithOffsets(
                await oldText.slice(range.start, range.end),
              );
              if (position.paragraphIndex! >= 0 &&
                  position.paragraphIndex! < reflowed.length) {
                local = reflowed[position.paragraphIndex!].rawStart(
                  withinParagraph,
                );
              } else {
                throw const FormatException('旧阅读段落越界');
              }
            } else {
              throw const FormatException('旧阅读段落越界');
            }
          } else {
            local = (position.fraction * bodyLength).floor();
          }
          final global = await newText.relocateFrom(
            oldText,
            range.start + local.clamp(0, bodyLength),
          );
          final target = await newText.locate(chapters, global);
          int? mappedParagraph = target.paragraph;
          if (target.chapter >= 0 && target.chapter < chapters.length) {
            final dstChapter = chapters[target.chapter];
            final dstBody = await newText.trimmedRange(
              dstChapter.offset,
              dstChapter.offset + dstChapter.length,
            );
            if (dstBody.end - dstBody.start <= FileTextAnchor.maxSliceLength) {
              final dstSlice = await newText.slice(dstBody.start, dstBody.end);
              if (!dstSlice.contains('\n\n') && dstSlice.contains('\n')) {
                final reflowedDst = reflowReaderParagraphsWithOffsets(dstSlice);
                mappedParagraph = locateReflowedStart(
                  reflowedDst,
                  (global - dstBody.start).clamp(0, dstSlice.length),
                ).paragraph;
              }
            }
          }
          return ReadingPosition(
            chapter: target.chapter,
            chapterId: target.chapter,
            offset: 0,
            fraction: target.fraction,
            fontSize: position.fontSize,
            width: 0,
            updatedAt: position.updatedAt,
            lineHeight: position.lineHeight,
            paragraphIndex: mappedParagraph,
            paragraphFraction: position.paragraphFraction,
            textScale: position.textScale,
            typeface: position.typeface,
            textOffset: target.textOffset,
            revision: task.newRevision,
          );
        }

        final records = <String, Object?>{};
        if (current case final currentPosition?) {
          Future<ReadingPosition> migrateCurrentPosition() async {
            if (!readingAlreadyMigrated) return migrate(currentPosition);
            if (currentPosition.chapter < 0 || currentPosition.chapter >= chapters.length) {
              throw const FormatException('阅读锚点范围损坏');
            }
            final c = chapters[currentPosition.chapter];
            final target = await newText.locate(chapters,
              c.offset + (currentPosition.fraction * c.length).floor());
            return ReadingPosition.fromJson({...currentPosition.toJson(),
              'revision': task.newRevision, 'textOffset': target.textOffset,
              'paragraphIndex': target.paragraph, 'width': 0, 'offset': 0});
          }
          try {
            final position = await migrateCurrentPosition();
            records['reading_position_$id'] = jsonEncode(position.toJson());
            records['chapter_$id'] = position.chapter;
            records[_chapterProgressAnchorKey(id)] = null;
          } on FormatException {
            quarantined.add({'kind': 'reading', 'record': currentPosition.toJson()});
            if (chapters.isEmpty) throw StateError('章节目录为空');
            final fallback = ReadingPosition.fromJson({...currentPosition.toJson(),
              'chapter': 0, 'chapterId': 0, 'textOffset': 0, 'offset': 0,
              'fraction': 0, 'paragraphIndex': 0, 'paragraphFraction': 0,
              'width': 0, 'revision': task.newRevision});
            records['reading_position_$id'] = jsonEncode(fallback.toJson());
            records['chapter_$id'] = 0;
            records[_chapterProgressAnchorKey(id)] = null;
          }
        }
        if (marks case final currentMarks?) {
          final migratedMarks = <Object>[];
          for (final mark in currentMarks) {
            try {
                final sourcePosition = mark.isUnderline
                    ? ReadingPosition.fromJson({
                        ...mark.position.toJson(),
                        'textOffset': null,
                      })
                    : mark.position;
                var mappedPosition = await migrate(
                  sourcePosition,
                  withinParagraph: mark.isUnderline
                      ? mark.underlineRanges.first.startOffset
                      : 0,
                );
                final ranges = await remapLocalUnderlineRanges(
                  ranges: mark.underlineRanges,
                  oldText: oldText,
                  newText: newText,
                  oldChapters: task.oldChapters,
                  newChapters: chapters,
                  oldRevision: task.oldRevision,
                  newRevision: task.newRevision,
                  quote: mark.quote,
                );
                if (ranges.isNotEmpty) {
                  final first = ranges.first;
                  mappedPosition = ReadingPosition.fromJson({
                    ...mappedPosition.toJson(),
                    'chapter': first.chapterId,
                    'chapterId': first.chapterId,
                    'paragraphIndex': first.startParagraph,
                    'textOffset': first.startOffset,
                    'revision': first.contentRevision,
                    'contentRevision': first.contentRevision,
                  });
                }
                migratedMarks.add(mark.withRange(
                  chapterTitle: chapters[mappedPosition.chapter].title,
                  position: mappedPosition,
                  ranges: ranges,
                  quote: mark.quote,
                  updatedAt: mark.rangeUpdatedAt,
                ).toJson());
            } on FormatException {
              quarantined.add({'kind': 'bookmark', 'record': mark.toJson()});
            } on RangeError {
              quarantined.add({'kind': 'bookmark', 'record': mark.toJson()});
            }
          }
          records['reader_bookmarks_$id'] = jsonEncode(migratedMarks);
        }
        final cursorKey = 'listening.cursor.v1.$id';
        try {
        final rawCursor = sourceRecords[cursorKey];
        final cursor = rawCursor == null ? null : jsonDecode(rawCursor as String) as Map<String, dynamic>;
        if (cursor != null) {
          final p = await migrate(
            ReadingPosition(
              chapter: cursor['chapter'] as int? ?? 0,
              chapterId: cursor['chapterId'] as int? ?? 0,
              offset: 0,
              fraction: 0,
              fontSize: fontSize,
              width: 0,
              updatedAt: 0,
              revision: cursor['revision'] as String? ?? '',
              textOffset: cursor['textOffset'] as int?,
              paragraphIndex: cursor['paragraph'] as int? ?? 0,
            ),
            withinParagraph: cursor['start'] as int? ?? 0,
          );
          final c = chapters[p.chapter];
          final range = await newText.trimmedRange(c.offset, c.offset + c.length);
          final paragraph = await newText.paragraphAt(range.start, range.end,
              stopAt: p.paragraphIndex!);
          records[cursorKey] = jsonEncode({
            ...cursor,
            'chapter': p.chapter,
            'chapterId': p.chapterId,
            'paragraph': p.paragraphIndex,
            'start':
                p.textOffset! -
                paragraph.start,
            'textOffset': p.textOffset,
            'revision': task.newRevision,
            'positionMs': 0,
            'segmentHash': '',
          });
        }
        } on FormatException {
          quarantined.add({'kind': 'listening', 'record': sourceRecords[cursorKey]});
        } on TypeError {
          quarantined.add({'kind': 'listening', 'record': sourceRecords[cursorKey]});
        } on RangeError {
          quarantined.add({'kind': 'listening', 'record': sourceRecords[cursorKey]});
        }
        journal = {
          'version': 2,
          'bookId': id,
          'status': 'prepared',
          'records': records,
        };
      }
      await _queuePositionWrite(() async {
      final stored = _readJsonObjectPreference(key);
      if (stored?['status'] == 'done') return;
      if (stored != null) {
        journal = stored;
      } else {
        if (sourceRecords.entries.any((entry) => _prefs.get(entry.key) != entry.value)) {
          throw StateError('迁移期间进度已更新，请重试');
        }
        for (final record in quarantined) {
          await archiveRecoveryRecord(_prefs, 'local_progress_quarantine_v1', record,
              reason: 'invalid_progress', details: {'bookId': id});
        }
        await writeLibraryPreference(_prefs, key, jsonEncode(journal));
      }
      final committed = journal!;
      if (committed['bookId'] != id || committed['records'] is! Map) {
        throw StateError('章节迁移日志损坏：$id');
      }
      final records = Map<String, dynamic>.from(committed['records'] as Map);
      for (final record in records.entries) {
        if (record.value == null) {
          if (!await _prefs.remove(record.key)) {
            throw StateError('迁移保存失败：${record.key}');
          }
        } else {
          await writeLibraryPreference(_prefs, record.key, record.value);
        }
      }
      await writeLibraryPreference(
        _prefs,
        key,
        jsonEncode({...committed, 'status': 'done'}),
      );
      if (records['reading_position_$id'] case final String raw) {
        _positions[id] = ReadingPosition.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        _chapters[id] = _positions[id]!.chapter;
      }
      if (records['reader_bookmarks_$id'] case final String raw) {
        _bookmarks[id] = [
          for (final item in jsonDecode(raw) as List)
            ReaderBookmark.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
        _updateUnderlineIndex(id);
        if (!_disposed) {
          _bookmarkChanges.notifyListeners();
          _underlineChanges.notifyListeners();
        }
      }
      notifyListeners();
      });
    })();
  }

  String _chapterProgressAnchorKey(int id) {
    return 'reading_anchor_$id';
  }

  String _remapJournalKey(int bookId, String migrationId) {
    return 'reading_remap_journal_${bookId}_$migrationId';
  }

  Map<String, dynamic>? _readJsonObjectPreference(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('$key must contain a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  int _pickNewChapterForGlobalOffset(
    List<({int offset, int length})> chapters, {
    required int globalOffset,
    required bool preferPreviousAtBoundary,
    required int fallbackIndex,
  }) {
    final nonEmpty = <int>[
      for (var i = 0; i < chapters.length; i++)
        if (chapters[i].length > 0) i,
    ];
    if (nonEmpty.isEmpty) {
      if (chapters.isEmpty) return 0;
      if (fallbackIndex < 0) return 0;
      if (fallbackIndex >= chapters.length) return chapters.length - 1;
      return fallbackIndex;
    }
    final firstIndex = nonEmpty.first;
    final lastIndex = nonEmpty.last;
    final lastChapter = chapters[lastIndex];
    final fullBookEnd = lastChapter.offset + lastChapter.length;
    // 全书末尾是一个特殊边界，固定落在最后一个非空章节末尾。
    if (globalOffset >= fullBookEnd) {
      return lastIndex;
    }
    // 章末锚点优先使用左侧区间。
    if (preferPreviousAtBoundary) {
      for (var n = nonEmpty.length - 1; n >= 0; n--) {
        final index = nonEmpty[n];
        final chapter = chapters[index];
        final end = chapter.offset + chapter.length;
        if (globalOffset > chapter.offset && globalOffset <= end) {
          return index;
        }
      }
    }
    // 普通锚点使用右侧区间，符合半开区间 [start, end)。
    for (final index in nonEmpty) {
      final chapter = chapters[index];
      final end = chapter.offset + chapter.length;
      if (globalOffset >= chapter.offset && globalOffset < end) {
        return index;
      }
    }
    // 章节之间理论上不应有空洞；如果存在，选择下一个非空章节。
    for (final index in nonEmpty) {
      if (globalOffset < chapters[index].offset) {
        return index;
      }
    }
    return firstIndex;
  }

  double _fractionForGlobalOffset(
    ({int offset, int length}) chapter,
    int globalOffset,
  ) {
    if (chapter.length <= 0) return 0.0;
    if (globalOffset <= chapter.offset) return 0.0;
    final end = chapter.offset + chapter.length;
    if (globalOffset >= end) return 1.0;
    return ((globalOffset - chapter.offset) / chapter.length)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  /// 本地书章节重切（切分规则升级）后迁移阅读进度，避免按旧章节序号串章。
  /// 锚点换算：旧章节字符起点 + 旧滚动比例 × 旧章节长度 ≈ 全书字符位置，
  /// 再落到包含该位置的新章节，章内比例按新章节长度折算。落点是近似位置
  /// （比例来自滚动而非字符），但保证仍在原来读到的那段文字附近。
  /// 段落锚点与像素偏移一并作废（width 置 0 强制阅读器按比例恢复），
  /// updatedAt 保持不变，不扰动「最近阅读」排序。无进度记录时不处理。
  /// 本地书章节重切后迁移阅读进度（可恢复、幂等）。
  ///
  /// 章节使用半开区间 [offset, offset + length)。
  /// fraction == 1.0 是旧章节的章末锚点，落在字符边界上时优先保留在
  /// 左侧旧章节的末尾，避免跳到下一章的 0.0。
  /// fraction < 1.0 使用 floor 生成字符位置，避免接近 1.0 时因为 round
  /// 直接跨到下一章。
  /// 迁移不更新 updatedAt，也不调用 _historyChanged()。
  /// 同一个 migrationId 第二次调用时，若 journal 已是 done 则直接返回，
  /// 不会把已迁移的位置再次按旧表换算。
  Future<void> remapChapterProgress(
    int id, {
    required List<({int offset, int length})> oldChapters,
    required List<({int offset, int length})> newChapters,
    required String migrationId,
  }) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => remapChapterProgress(
          id,
          oldChapters: oldChapters,
          newChapters: newChapters,
          migrationId: migrationId,
        ),
      );
    }
    return _queuePositionWrite(() async {
      if (id <= 0 || oldChapters.isEmpty || newChapters.isEmpty) return;
      // 兼容 ID 已收紧为必传：两次不同重切若只按章节数量拼 ID，
      // 会共用同一个 done journal，生产调用方全部传持久化任务 ID。
      // journal key 按书隔离，并校验 journal 所属书籍，防止多本书
      // 共用同一任务 ID 时读到别本书的 journal。
      final effectiveMigrationId = migrationId;
      if (effectiveMigrationId.trim().isEmpty) {
        throw ArgumentError.value(migrationId, 'migrationId');
      }
      final journalKey = _remapJournalKey(id, effectiveMigrationId);
      final existingJournal = _readJsonObjectPreference(journalKey);
      if (existingJournal != null && existingJournal['bookId'] != id) {
        throw StateError('remap journal book id mismatch: $journalKey');
      }
      // 任务已经完整应用过。调用方可能在 state 成功后、confirm 前退出，
      // 所以这里必须保留并识别 done journal；journal 查询必须放在
      // 无进度判断之前，否则 prepared 任务会被无进度判断吞掉。
      if (existingJournal?['status'] == 'done') {
        return;
      }
      final pos = _positions[id];
      final savedChapter = _chapters[id];
      // 正式阅读位置优先；只有 pos 为空且锚点章节等于当前章节键时，
      // 独立锚点才可参与换算，否则旧锚点会覆盖已更新的章节或污染
      // 正式位置（例如旧章末标记把新位置拉回上一章章末）。
      final storedAnchor = pos == null
          ? _readJsonObjectPreference(_chapterProgressAnchorKey(id))
          : null;
      final anchor = savedChapter != null &&
              storedAnchor?['chapter'] == savedChapter
          ? storedAnchor
          : null;
      if (existingJournal == null &&
          pos == null &&
          savedChapter == null &&
          anchor == null) {
        // 无进度也要持久化完成标记：否则调用方确认失败或中断后，
        // 用户按新表产生进度，再重放该任务会把新进度当旧表换算。
        await writeLibraryPreference(
          _prefs,
          journalKey,
          jsonEncode({
            'version': 1,
            'status': 'done',
            'migrationId': effectiveMigrationId,
            'bookId': id,
            'hasPosition': false,
          }),
        );
        return;
      }
      late int globalOffset;
      late int newIndex;
      late double newFraction;
      late bool preferPreviousAtBoundary;
      late bool hasPosition;
      if (existingJournal != null) {
        final storedIndex = existingJournal['newChapter'];
        final storedFraction = existingJournal['newFraction'];
        final storedGlobal = existingJournal['globalOffset'];
        if (storedIndex is! num ||
            storedFraction is! num ||
            storedGlobal is! num) {
          throw FormatException('invalid remap journal: $journalKey');
        }
        newIndex = storedIndex.toInt();
        newFraction = storedFraction.toDouble().clamp(0.0, 1.0).toDouble();
        globalOffset = storedGlobal.toInt();
        preferPreviousAtBoundary =
            existingJournal['atChapterEnd'] == true;
        hasPosition = existingJournal['hasPosition'] == true;
        if (newIndex < 0 || newIndex >= newChapters.length) {
          throw StateError(
            'remap journal chapter index out of range: $journalKey',
          );
        }
      } else {
        // 锚点已在上文筛选过：这里只取正式位置或当前章节键，
        // 不再从锚点取章节，避免已换章节时用旧全书偏移。
        final rawOldIndex = pos?.chapter ?? savedChapter;
        if (rawOldIndex == null) return;
        final oldIndex = rawOldIndex < 0
            ? 0
            : rawOldIndex >= oldChapters.length
                ? oldChapters.length - 1
                : rawOldIndex;
        final oldChapter = oldChapters[oldIndex];
        final storedGlobal =
            pos == null ? (anchor?['globalOffset']) : null;
        final fraction = (pos?.fraction ??
                (anchor?['fraction'] as num?)?.toDouble() ??
                0.0)
            .clamp(0.0, 1.0)
            .toDouble();
        if (storedGlobal is num) {
          globalOffset = storedGlobal.toInt();
        } else {
          // 非章末位置用 floor，fraction == 1.0 才使用章节长度本身。
          final localOffset = oldChapter.length <= 0
              ? 0
              : fraction >= 1.0
                  ? oldChapter.length
                  : (fraction * oldChapter.length).floor();
          globalOffset = oldChapter.offset + localOffset;
        }
        preferPreviousAtBoundary = oldChapter.length > 0 &&
            (anchor?['atChapterEnd'] == true || fraction >= 1.0);
        newIndex = _pickNewChapterForGlobalOffset(
          newChapters,
          globalOffset: globalOffset,
          preferPreviousAtBoundary: preferPreviousAtBoundary,
          fallbackIndex: oldIndex,
        );
        final newChapter = newChapters[newIndex];
        newFraction = _fractionForGlobalOffset(newChapter, globalOffset);
        hasPosition = pos != null;
        // 先写 prepared journal。后续任一步失败，下一次重放都使用
        // 同一个目标位置，不会根据已经部分写入的新状态重新计算。
        await writeLibraryPreference(
          _prefs,
          journalKey,
          jsonEncode({
            'version': 1,
            'status': 'prepared',
            'migrationId': effectiveMigrationId,
            'bookId': id,
            'newChapter': newIndex,
            'newFraction': newFraction,
            'globalOffset': globalOffset,
            'atChapterEnd': preferPreviousAtBoundary,
            'hasPosition': hasPosition,
          }),
        );
      }
      ReadingPosition? newPos;
      if (hasPosition) {
        // 正常情况下 prepared journal 产生于 pos 非空时，重启后旧位置
        // 或新位置都应该能恢复出来。如果位置记录已经被外部清掉，
        // 让任务失败并保留 journal，不能悄悄伪造字体和布局参数。
        final template = pos;
        if (template == null) {
          throw StateError(
            'reading position disappeared during chapter remap: $id',
          );
        }
        newPos = ReadingPosition(
          chapter: newIndex,
          chapterId: newIndex,
          offset: 0,
          fraction: newFraction,
          fontSize: template.fontSize,
          width: 0,
          updatedAt: template.updatedAt,
          lineHeight: template.lineHeight,
          textScale: template.textScale,
          typeface: template.typeface,
        );
        _positions[id] = newPos;
        await writeLibraryPreference(
          _prefs,
          'reading_position_$id',
          jsonEncode(newPos.toJson()),
        );
        // 有正式 ReadingPosition 时，旧的独立锚点不再作为来源。
        await _prefs.remove(_chapterProgressAnchorKey(id));
      } else {
        // 只有 chapter_$id 的旧数据不能丢掉计算出的新比例。
        // 这里同时保存全书字符位置，供下一次重切继续使用。
        await writeLibraryPreference(
          _prefs,
          _chapterProgressAnchorKey(id),
          jsonEncode({
            'version': 1,
            'chapter': newIndex,
            'fraction': newFraction,
            'globalOffset': globalOffset,
            'atChapterEnd': preferPreviousAtBoundary,
          }),
        );
      }
      _chapters[id] = newIndex;
      // 位置或锚点写成功后再写章节键。
      await writeLibraryPreference(_prefs, 'chapter_$id', newIndex);
      // journal 完成标记最后写。即使进程在这之前退出，下一次也会
      // 重复写入同一个目标，属于幂等重放。
      await writeLibraryPreference(
        _prefs,
        journalKey,
        jsonEncode({
          'version': 1,
          'status': 'done',
          'migrationId': effectiveMigrationId,
          'bookId': id,
          'newChapter': newIndex,
          'newFraction': newFraction,
          'globalOffset': globalOffset,
          'atChapterEnd': preferPreviousAtBoundary,
          'hasPosition': hasPosition,
        }),
      );
      // 不调用 _historyChanged()，不改变最近阅读排序。
      notifyListeners();
    });
  }

  Future<void> clearReadingHistory() {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => clearReadingHistory());
    }
    return _queuePositionWrite(() async {
      final visible = readingHistoryIds;
      if (visible.isEmpty) return;
      final next = {..._hiddenHistory, ...visible};
      await writeLibraryPreference(
        _prefs,
        'reading_history_hidden',
        next.map((id) => '$id').toList(),
      );
      _hiddenHistory
        ..clear()
        ..addAll(next);
      _historyChanged();
    });
  }

  Future<void> restoreReadingHistory(int id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => restoreReadingHistory(id));
    }
    return _queuePositionWrite(() async {
      if (id <= 0 || !hasRead(id) || !_hiddenHistory.contains(id)) return;
      final next = {..._hiddenHistory}..remove(id);
      await writeLibraryPreference(
        _prefs,
        'reading_history_hidden',
        next.map((id) => '$id').toList(),
      );
      _hiddenHistory
        ..clear()
        ..addAll(next);
      _historyChanged();
    });
  }

  int chapterForNovel(Novel novel) {
    final position = _positions[novel.id];
    if (position != null && position.chapterId > 0) {
      final chapters = novel.chapters;
      if (position.chapter >= 0 &&
          position.chapter < chapters.length &&
          chapters[position.chapter].id == position.chapterId) {
        return position.chapter;
      }
      if (position.chapterId < chapters.length &&
          chapters[position.chapterId].id == position.chapterId) {
        return position.chapterId;
      }
      final index = chapters.indexWhere(
        (chapter) => chapter.id == position.chapterId,
      );
      if (index >= 0) return index;
    }
    final count = novel.chapters.isEmpty
        ? novel.chapterCount
        : novel.chapters.length;
    return count == 0
        ? chapterFor(novel.id)
        : chapterFor(novel.id).clamp(0, count - 1);
  }

  String? _novelSnapshot(Novel novel) {
    if (identical(_persistedNovels[novel.id], novel)) return null;
    assert(() {
      _metadataEncodes++;
      return true;
    }());
    final snapshot = jsonEncode(novel.toSnapshot());
    return snapshot;
  }

  Future<void> _writeNovel(Novel novel, String snapshot) async {
    try {
      await writeLibraryPreference(_prefs, 'novel_meta_${novel.id}', snapshot);
      _persistedNovels[novel.id] = novel;
    } catch (_) {
      if (identical(_persistedNovels[novel.id], novel)) {
        _persistedNovels.remove(novel.id);
      }
      rethrow;
    }
  }

  Future<void> rememberNovel(Novel novel, {bool Function()? accepts}) {
    if (_restoreBarrier case final barrier?) {
      return _withWriteTimeout(
        barrier.future.then((_) => rememberNovel(novel, accepts: accepts)),
        '书籍详情保存',
      );
    }
    if (novel.id <= 0) return Future.value();
    if (accepts == null) _known[novel.id] = novel;
    final queued = _queuePositionWrite(() async {
      if (accepts != null && !accepts()) return;
      final snapshot = _novelSnapshot(novel);
      if (snapshot != null) await _writeNovel(novel, snapshot);
      _known[novel.id] = novel;
    });
    return _withWriteTimeout(queued, '书籍详情保存');
  }

  Future<void> _persistReadingActivity() async {
    if (_restoreBarrier case final barrier?) await barrier.future;
    await _queuePositionWrite(
      () => writeLibraryPreference(
        _prefs,
        ReadingActivityStore.preferenceKey,
        readingActivity.encode(),
      ),
    );
  }

  Future<void> _persistReadingMoments() async {
    if (_restoreBarrier case final barrier?) await barrier.future;
    await _queuePositionWrite(
      () => writeLibraryPreference(
        _prefs,
        ReadingMomentsStore.preferenceKey,
        readingMoments.encode(),
      ),
    );
  }

  Future<ReaderBookmark> addUnderline({
    required Novel novel,
    required ReadingPosition position,
    required List<ReaderUnderlineRange> ranges,
    String quote = '',
  }) async => (await _changeUnderline(
    novel: novel,
    position: position,
    ranges: ranges,
    quote: quote,
    toggle: false,
  ))!;

  Future<bool> toggleUnderline({
    required Novel novel,
    required ReadingPosition position,
    required List<ReaderUnderlineRange> ranges,
    String quote = '',
  }) async =>
      await _changeUnderline(
        novel: novel,
        position: position,
        ranges: ranges,
        quote: quote,
        toggle: true,
      ) !=
      null;

  Future<ReaderBookmark> saveAnnotation({
    required Novel novel,
    required ReadingPosition position,
    required List<ReaderUnderlineRange> ranges,
    String quote = '',
    ReaderMarkStyle style = ReaderMarkStyle.underline,
    ReaderMarkColor color = ReaderMarkColor.ink,
    String note = '',
  }) async => (await _changeUnderline(
    novel: novel,
    position: position,
    ranges: ranges,
    quote: quote,
    toggle: false,
    annotation: ReaderAnnotationData.fromJson({
      'style': style.name,
      'color': color.name,
      'note': note,
      'updatedAt': 0,
    }),
  ))!;

  Future<ReaderBookmark> updateBookmarkAnnotation(
    int novelId,
    String id, {
    required ReaderMarkStyle style,
    required ReaderMarkColor color,
    required String note,
  }) async {
    final data = ReaderAnnotationData.fromJson({
      'style': style.name,
      'color': color.name,
      'note': note,
      'updatedAt': 0,
    });
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => updateBookmarkAnnotation(
          novelId,
          id,
          style: style,
          color: color,
          note: note,
        ),
      );
    }
    late ReaderBookmark result;
    await _queuePositionWrite(() async {
      final marks = _bookmarks[novelId] ?? const <ReaderBookmark>[];
      final previous = marks.where((mark) => mark.id == id).firstOrNull;
      if (previous == null) throw const FormatException('这条书签已被移除');
      result = previous.withAnnotation(_datedAnnotation(data, previous));
      final next = [for (final mark in marks) mark.id == id ? result : mark];
      await _writeBookmarks(novelId, next);
      _bookmarks[novelId] = next;
      _updateUnderlineIndex(novelId);
      if (!_disposed) _bookmarkChanges.notifyListeners();
    });
    return result;
  }

  Future<ReaderBookmark> updateBookmarkRange(
    int novelId,
    String id, {
    required Novel novel,
    required ReaderAnnotationRangeChange change,
    required int expectedRangeUpdatedAt,
    required List<ReaderUnderlineRange> expectedRanges,
    ReaderAnnotationData? annotation,
  }) async {
    if (novelId != novel.id ||
        change.novelId != novelId ||
        change.ranges.any(
          (range) => !novel.chapters.any((c) => c.id == range.chapterId),
        )) {
      throw const FormatException('原文范围不属于这本书');
    }
    final ranges = canonicalReaderUnderlineRanges(
      change.ranges,
      chapterOrder: novel.chapters.map((c) => c.id),
    );
    if (change.quote.length > 12000) {
      throw const FormatException('摘录过长，请选择不超过 12000 字的内容');
    }
    final edited = annotation == null
        ? null
        : ReaderAnnotationData.fromJson(annotation.toJson());
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => updateBookmarkRange(
          novelId,
          id,
          novel: novel,
          change: change,
          expectedRangeUpdatedAt: expectedRangeUpdatedAt,
          expectedRanges: expectedRanges,
          annotation: edited,
        ),
      );
    }
    late ReaderBookmark result;
    await _queuePositionWrite(() async {
      final marks = _bookmarks[novelId] ?? const <ReaderBookmark>[];
      final previous = marks.where((mark) => mark.id == id).firstOrNull;
      if (previous == null) throw const FormatException('这条书签已被移除');
      if (previous.rangeUpdatedAt != expectedRangeUpdatedAt ||
          !listEquals(previous.underlineRanges, expectedRanges)) {
        throw const FormatException('原文范围刚刚发生变化，请重新打开这条书签再调整');
      }
      final first = ranges.first;
      final chapter = novel.chapters.indexWhere((c) => c.id == first.chapterId);
      final position = ReadingPosition.fromJson({
        ...previous.position.toJson(),
        'chapter': chapter,
        'chapterId': first.chapterId,
        'paragraphIndex': first.startParagraph,
        'textOffset': first.startOffset,
        'paragraphFraction': 0,
        'contentRevision': first.contentRevision,
        'revision': first.contentRevision,
        'offset': 0,
        'fraction': 0,
        'width': 0,
        'layout': '',
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      result = previous.withRange(
        chapterTitle: novel.chapters[chapter].title,
        position: position,
        ranges: ranges,
        quote: change.quote,
        updatedAt: now > previous.rangeUpdatedAt
            ? now
            : previous.rangeUpdatedAt + 1,
      );
      if (edited != null) {
        result = result.withAnnotation(_datedAnnotation(edited, previous));
      }
      final next = [for (final mark in marks) mark.id == id ? result : mark];
      await _writeBookmarks(novelId, next);
      _bookmarks[novelId] = next;
      _updateUnderlineIndex(novelId);
      if (!_disposed) _bookmarkChanges.notifyListeners();
    });
    return result;
  }

  ReaderAnnotationData _datedAnnotation(
    ReaderAnnotationData data,
    ReaderBookmark? previous,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = previous?.annotation.updatedAt ?? 0;
    return data.at(now > last ? now : last + 1);
  }

  Future<ReaderBookmark?> _changeUnderline({
    required Novel novel,
    required ReadingPosition position,
    required List<ReaderUnderlineRange> ranges,
    required String quote,
    required bool toggle,
    ReaderAnnotationData? annotation,
  }) async {
    final chapterIds = novel.chapters.map((chapter) => chapter.id).toSet();
    if (novel.id <= 0 ||
        ranges.any((range) => !chapterIds.contains(range.chapterId))) {
      throw const FormatException('暂时无法定位选中的文字，请重新选择');
    }
    final selected = canonicalReaderUnderlineRanges([
      for (final range in ranges)
        range.contentRevision.isEmpty && range.chapterId == position.chapterId
            ? range.withRevision(position.contentRevision)
            : range,
    ], chapterOrder: novel.chapters.map((chapter) => chapter.id));
    final excerpt = quote.trim();
    if (excerpt.length > 12000) {
      throw const FormatException('摘录过长，请选择不超过 12000 字的内容');
    }
    if (!position.offset.isFinite ||
        position.offset < 0 ||
        !position.fraction.isFinite ||
        position.fraction < 0 ||
        position.fraction > 1 ||
        !position.width.isFinite ||
        !position.fontSize.isFinite ||
        !position.lineHeight.isFinite) {
      throw const FormatException('暂时无法定位选中的文字，请重新选择');
    }
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => _changeUnderline(
          novel: novel,
          position: position,
          ranges: selected,
          quote: excerpt,
          toggle: toggle,
          annotation: annotation,
        ),
      );
    }
    ReaderBookmark? result;
    await _queuePositionWrite(() async {
      final marks = _bookmarks[novel.id] ?? const <ReaderBookmark>[];
      final matching = marks.where((mark) {
        if (!mark.isUnderline) return false;
        if (toggle) {
          return readerUnderlineRangesOverlap(mark.underlineRanges, selected);
        }
        return listEquals(
          canonicalReaderUnderlineRanges(
            mark.underlineRanges,
            chapterOrder: novel.chapters.map((chapter) => chapter.id),
          ),
          selected,
        );
      }).toList();
      final existing = matching.firstOrNull;
      if (existing != null) {
        if (!toggle) {
          if (annotation == null) {
            result = existing;
            return;
          }
          result = existing.withAnnotation(
            _datedAnnotation(annotation, existing),
          );
          final next = [
            for (final mark in marks) mark.id == existing.id ? result! : mark,
          ];
          await _writeBookmarks(novel.id, next);
          _bookmarks[novel.id] = next;
          _updateUnderlineIndex(novel.id);
          if (!_disposed) _bookmarkChanges.notifyListeners();
          return;
        }
        final ids = matching.map((mark) => mark.id).toSet();
        final next = marks.where((mark) => !ids.contains(mark.id)).toList();
        await _writeBookmarks(novel.id, next);
        _bookmarks[novel.id] = next;
        _updateUnderlineIndex(novel.id);
        if (!_disposed) _bookmarkChanges.notifyListeners();
        return;
      }
      if (marks.length >= 1000) {
        throw const FormatException('本书书签和划线已达 1000 个，请先整理');
      }
      final first = selected.first;
      final chapter = novel.chapters.indexWhere((c) => c.id == first.chapterId);
      final sameChapter = position.chapterId > 0 || first.chapterId > 0
          ? position.chapterId == first.chapterId
          : position.chapter == chapter;
      final anchor = ReadingPosition.fromJson({
        ...position.toJson(),
        'chapter': chapter,
        'chapterId': first.chapterId,
        'paragraphIndex': first.startParagraph,
        'textOffset': first.startOffset,
        'paragraphFraction': 0,
        'contentRevision': first.contentRevision,
        'revision': first.contentRevision,
        if (!sameChapter) ...{'offset': 0, 'width': 0, 'layout': ''},
      });
      final createdAt = DateTime.now();
      final mark = ReaderBookmark(
        id: '${createdAt.microsecondsSinceEpoch}-${marks.length}',
        createdAt: createdAt.toUtc(),
        createdOffsetMinutes: createdAt.timeZoneOffset.inMinutes,
        chapterTitle: novel.chapters[chapter].title,
        position: anchor,
        quote: excerpt,
        underlineRanges: selected,
        annotation: annotation == null
            ? const ReaderAnnotationData()
            : _datedAnnotation(annotation, null),
      );
      final next = [mark, ...marks];
      await _writeBookmarks(novel.id, next);
      _bookmarks[novel.id] = next;
      _updateUnderlineIndex(novel.id);
      if (!_disposed) _bookmarkChanges.notifyListeners();
      result = mark;
    });
    return result;
  }

  Future<ReaderBookmark?> addBookmark({
    required Novel novel,
    required ReadingPosition position,
    String quote = '',
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => addBookmark(novel: novel, position: position, quote: quote),
      );
    }
    if (!_acceptLocalPosition(novel, position.chapter)) return null;
    final index = chapterForPosition(novel, position);
    final excerpt = quote.trim();
    if (excerpt.length > 12000) {
      throw const FormatException('摘录过长，请选择不超过 12000 字的内容');
    }
    if (novel.id <= 0 ||
        index == null ||
        !position.offset.isFinite ||
        position.offset < 0 ||
        !position.fraction.isFinite ||
        position.fraction < 0 ||
        position.fraction > 1 ||
        !position.width.isFinite ||
        !position.fontSize.isFinite ||
        !position.lineHeight.isFinite) {
      return null;
    }
    ReaderBookmark? result;
    await _queuePositionWrite(() async {
      if (!_acceptLocalPosition(novel, position.chapter)) return;
      final marks = _bookmarks[novel.id] ?? const <ReaderBookmark>[];
      for (final mark in marks) {
        if (!mark.isUnderline &&
            mark.quote == excerpt &&
            chapterForPosition(novel, mark.position) == index &&
            (excerpt.isEmpty
                ? (position.width > 0 ||
                      mark.position.paragraphIndex == position.paragraphIndex)
                : mark.position.paragraphIndex == position.paragraphIndex &&
                      mark.position.textOffset == position.textOffset) &&
            (position.width > 0
                ? (mark.position.offset - position.offset).abs() < 12
                : (mark.position.offset - position.offset).abs() < .01) &&
            (mark.position.fontSize - position.fontSize).abs() < .01 &&
            (mark.position.lineHeight - position.lineHeight).abs() < .01 &&
            (mark.position.width - position.width).abs() < 1) {
          result = mark;
          return;
        }
      }
      if (marks.length >= 1000) {
        throw const FormatException('本书书签已达 1000 个，请先整理书签');
      }
      final createdAt = DateTime.now();
      final mark = ReaderBookmark(
        id: '${createdAt.microsecondsSinceEpoch}-${marks.length}',
        createdAt: createdAt.toUtc(),
        createdOffsetMinutes: createdAt.timeZoneOffset.inMinutes,
        chapterTitle: novel.chapters[index].title,
        position: position,
        quote: excerpt,
      );
      final next = [mark, ...marks];
      await _writeBookmarks(novel.id, next);
      _bookmarks[novel.id] = next;
      _updateUnderlineIndex(novel.id);
      if (!_disposed) _bookmarkChanges.notifyListeners();
      result = mark;
    });
    return result;
  }

  /// PDF page bookmark. Same [ReaderBookmark] record as text books:
  /// `chapter` is the 0-based page (as `chapter_<id>` already stores for PDF),
  /// `chapterId` 0 so lookup falls back to the page index, offsets zero.
  /// The generic [addBookmark] cannot be used because PDF page "chapters"
  /// carry no revision and are refused by the local chapter guard.
  Future<ReaderBookmark?> addPageBookmark({
    required Novel novel,
    required int page,
    required int pageCount,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => addPageBookmark(novel: novel, page: page, pageCount: pageCount),
      );
    }
    if (novel.id <= 0 || page < 0 || page >= pageCount) return null;
    ReaderBookmark? result;
    await _queuePositionWrite(() async {
      final marks = _bookmarks[novel.id] ?? const <ReaderBookmark>[];
      for (final mark in marks) {
        if (!mark.isUnderline &&
            mark.quote.isEmpty &&
            mark.position.chapterId == 0 &&
            mark.position.chapter == page) {
          result = mark;
          return;
        }
      }
      if (marks.length >= 1000) {
        throw const FormatException('本书书签已达 1000 个，请先整理书签');
      }
      final createdAt = DateTime.now();
      final mark = ReaderBookmark(
        id: '${createdAt.microsecondsSinceEpoch}-${marks.length}',
        createdAt: createdAt.toUtc(),
        createdOffsetMinutes: createdAt.timeZoneOffset.inMinutes,
        chapterTitle: '第 ${page + 1} 页',
        position: ReadingPosition(
          chapter: page,
          chapterId: 0,
          offset: 0,
          fraction: pageCount <= 1 ? 0 : page / (pageCount - 1),
          fontSize: _readerStore.fontSize,
          width: 0,
          updatedAt: createdAt.millisecondsSinceEpoch,
          lineHeight: _readerStore.lineHeight,
        ),
      );
      final next = [mark, ...marks];
      await _writeBookmarks(novel.id, next);
      _bookmarks[novel.id] = next;
      _updateUnderlineIndex(novel.id);
      if (!_disposed) _bookmarkChanges.notifyListeners();
      result = mark;
    });
    return result;
  }

  Future<void> removeBookmark(int novelId, String id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => removeBookmark(novelId, id));
    }
    return _queuePositionWrite(() async {
      final marks = _bookmarks[novelId];
      if (marks == null || !marks.any((mark) => mark.id == id)) return;
      final next = marks.where((mark) => mark.id != id).toList();
      await _writeBookmarks(novelId, next);
      _bookmarks[novelId] = next;
      _updateUnderlineIndex(novelId);
      if (!_disposed) _bookmarkChanges.notifyListeners();
    });
  }

  Future<void> categorizeBookmark(int novelId, String id, String category) {
    category = category.trim();
    if (category.length > 30) throw const FormatException('分类名称最多 30 个字');
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => categorizeBookmark(novelId, id, category),
      );
    }
    return _queuePositionWrite(() async {
      final marks = _bookmarks[novelId] ?? const <ReaderBookmark>[];
      final previous = marks.where((mark) => mark.id == id).firstOrNull;
      if (previous == null || previous.category == category) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final next = [
        for (final mark in marks)
          mark.id == id
              ? mark.withCategory(
                  category,
                  now > previous.categoryAt ? now : previous.categoryAt + 1,
                )
              : mark,
      ];
      await _writeBookmarks(novelId, next);
      _bookmarks[novelId] = next;
      _updateUnderlineIndex(novelId);
      if (!_disposed) _bookmarkChanges.notifyListeners();
    });
  }

  Future<void> _writeBookmarks(int novelId, List<ReaderBookmark> marks) async {
    final record = jsonEncode(marks.map((mark) => mark.toJson()).toList());
    await writeLibraryPreference(_prefs, 'reader_bookmarks_$novelId', record);
  }

  Future<void> toggleShelf(int id, {Novel? novel}) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => toggleShelf(id, novel: novel));
    }
    return setShelfMembership(id, !contains(id), novel: novel);
  }

  /// One transactional merge/notification rather than rebuilding the shelf
  /// once per imported cloud/legacy ID. Reading records are never overwritten.
  Future<void> addShelfIds(
    Iterable<int> values, {
    Map<int, Novel> novels = const {},
    bool automatic = false,
  }) async {
    final ids = values.where((id) => id > 0 && id <= 0x7fffffff).toSet();
    if (_restoreBarrier case final barrier?) {
      await barrier.future;
      return addShelfIds(ids, novels: novels, automatic: automatic);
    }
    await _queuePositionWrite(() async {
      final excluded = (_prefs.getStringList('local_shelf_removed') ?? []).toSet();
      final additions = ids.difference(_shelf)
        ..removeWhere((id) => automatic && excluded.contains('$id'));
      if (additions.isEmpty) return;
      final shelf = {..._shelf, ...additions};
      final now = DateTime.now().millisecondsSinceEpoch;
      final snapshots = <int, Novel>{};
      final changes = <String, Object>{
        'shelf': shelf.map((id) => '$id').toList(),
        'local_shelf_removed': excluded.where((id) => !additions.any((added) => '$added' == id)).toList(),
        for (final id in additions) 'shelf_added_$id': now,
      };
      for (final id in additions) {
        final novel = novels[id];
        if (novel == null) continue;
        final snapshot = _novelSnapshot(novel);
        snapshots[id] = novel;
        if (snapshot != null) changes['novel_meta_$id'] = snapshot;
      }
      try {
        await _commitLibraryRecords(changes);
      } catch (_) {
        for (final entry in snapshots.entries) {
          if (identical(_persistedNovels[entry.key], entry.value)) {
            _persistedNovels.remove(entry.key);
          }
        }
        rethrow;
      }
      _shelf.addAll(additions);
      _persistedNovels.addAll(snapshots);
      for (final id in additions) {
        _added[id] = now;
        _shelfRevisions[id] = shelfRevision(id) + 1;
        final novel = novels[id];
        if (novel != null) _known[id] = novel;
      }
      if (!_disposed) notifyListeners();
    });
  }

  /// 扫描自动上架的批量入口，同时持久化书架和书籍元数据。
  Future<void> addShelfBooks(Iterable<Novel> novels) async {
    final byId = <int, Novel>{for (final novel in novels) novel.id: novel};
    await addShelfIds(byId.keys, novels: byId, automatic: true);
  }

  Future<void> setShelfMembership(
    int id,
    bool present, {
    Novel? novel,
    int? restoredAddedAt,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setShelfMembership(
          id,
          present,
          novel: novel,
          restoredAddedAt: restoredAddedAt,
        ),
      );
    }
    if (id <= 0) return;
    await _queuePositionWrite(() async {
      final changedMembership = contains(id) != present;
      final excluded = (_prefs.getStringList('local_shelf_removed') ?? []).toSet();
      if (isLocalNovelId(id)) {
        if (present) {
          excluded.remove('$id');
        } else {
          excluded.add('$id');
        }
      }
      final shelf = {..._shelf};
      if (present) {
        shelf.add(id);
      } else {
        shelf.remove(id);
      }
      final timestamp = changedMembership && present
          ? restoredAddedAt != null && restoredAddedAt >= 0
                ? restoredAddedAt
                : DateTime.now().millisecondsSinceEpoch
          : _added[id];
      final snapshot = novel == null ? null : _novelSnapshot(novel);
      try {
        await _commitLibraryRecords({
          'local_shelf_removed': excluded.toList(),
          if (changedMembership) 'shelf': shelf.map((id) => '$id').toList(),
          if (present && timestamp != null) 'shelf_added_$id': timestamp,
          'novel_meta_$id': ?snapshot,
        });
      } catch (_) {
        if (novel != null && identical(_persistedNovels[id], novel)) {
          _persistedNovels.remove(id);
        }
        rethrow;
      }
      _shelf
        ..clear()
        ..addAll(shelf);
      if (present && timestamp != null) _added[id] = timestamp;
      if (novel != null) _known[id] = novel;
      if (novel != null && snapshot != null) _persistedNovels[id] = novel;
      if (changedMembership) _shelfRevisions[id] = shelfRevision(id) + 1;
      if (!_disposed && (changedMembership || novel != null)) notifyListeners();
    });
  }

  Future<void> setChapter(int id, int chapter) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setChapter(id, chapter));
    }
    if (id <= 0 || chapter < 0) return;
    _chapters[id] = chapter;
    notifyListeners();
    _historyChanged();
    await _queuePositionWrite(() async {
      await writeLibraryPreference(_prefs, 'chapter_$id', chapter);
      if (_hiddenHistory.contains(id)) {
        final hidden = {..._hiddenHistory}..remove(id);
        await writeLibraryPreference(_prefs, 'reading_history_hidden',
            hidden.map((value) => '$value').toList());
        _hiddenHistory.remove(id);
        _historyChanged();
      }
    });
  }

  Future<void> savePosition({
    required Novel novel,
    required int chapter,
    required double offset,
    required double maximum,
    required double width,
    bool notify = true,
    int? paragraphIndex,
    double paragraphFraction = 0,
    double textScale = 1,
    String? typeface,
    int? textOffset,
  }) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => savePosition(
          novel: novel,
          chapter: chapter,
          offset: offset,
          maximum: maximum,
          width: width,
          notify: notify,
          paragraphIndex: paragraphIndex,
          paragraphFraction: paragraphFraction,
          textScale: textScale,
          typeface: typeface,
          textOffset: textOffset,
        ),
      );
    }
    if (!_acceptLocalSavePosition(novel, chapter)) return Future.value();
    if (novel.id <= 0 ||
        !offset.isFinite ||
        !maximum.isFinite ||
        !width.isFinite ||
        !paragraphFraction.isFinite ||
        !textScale.isFinite ||
        chapter < 0 ||
        chapter >= novel.chapters.length) {
      return Future.value();
    }
    final position = ReadingPosition(
      chapter: chapter,
      chapterId: novel.chapters[chapter].id,
      revision: novel.chapters[chapter].revision,
      textOffset: textOffset,
      offset: offset.clamp(0, double.infinity),
      fraction: maximum > 0 ? (offset / maximum).clamp(0, 1) : 0,
      fontSize: fontSize,
      width: width,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      lineHeight: lineHeight,
      paragraphIndex: paragraphIndex != null && paragraphIndex >= 0
          ? paragraphIndex
          : null,
      paragraphFraction: paragraphFraction.clamp(0, 1),
      textScale: textScale.clamp(.5, 5),
      typeface: typeface ?? _readerStore.appFontId,
    );
    final previousPosition = _positions[novel.id];
    final previousChapter = _chapters[novel.id];
    final previousNovel = _known[novel.id];
    _positions[novel.id] = position;
    final chapterChanged = _chapters[novel.id] != chapter;
    _chapters[novel.id] = chapter;
    _known[novel.id] = novel;
    if (notify) notifyListeners();
    _historyChanged();
    final record = jsonEncode(position.toJson());
    void rollbackRejected() {
      if (!identical(_positions[novel.id], position)) return;
      if (previousPosition == null) {
        _positions.remove(novel.id);
      } else {
        _positions[novel.id] = previousPosition;
      }
      if (previousChapter == null) {
        _chapters.remove(novel.id);
      } else {
        _chapters[novel.id] = previousChapter;
      }
      if (previousNovel == null) {
        _known.remove(novel.id);
      } else {
        _known[novel.id] = previousNovel;
      }
      _historyChanged();
    }
    return _queuePositionWrite(() async {
      if (!_acceptLocalSavePosition(novel, chapter)) {
        rollbackRejected();
        return;
      }
      try {
      final snapshot = _novelSnapshot(novel);
      if (chapterChanged) {
        await writeLibraryPreference(_prefs, 'chapter_${novel.id}', chapter);
      }
      await writeLibraryPreference(
        _prefs,
        'reading_position_${novel.id}',
        record,
      );
      if (snapshot != null) await _writeNovel(novel, snapshot);
      if (_hiddenHistory.contains(novel.id)) {
        final hidden = {..._hiddenHistory}..remove(novel.id);
        await writeLibraryPreference(_prefs, 'reading_history_hidden',
            hidden.map((value) => '$value').toList());
        _hiddenHistory.remove(novel.id);
        _historyChanged();
      }
      } catch (_) {
        if (_prefs.getString('reading_position_${novel.id}') != record) rollbackRejected();
        rethrow;
      }
    });
  }

  Future<void> setTheme(ThemeMode mode) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setTheme(mode));
    }
    if (_appearanceStore.theme == mode) {
      if (_appearanceStore.hasThemeMismatch(mode)) {
        await _queuePositionWrite(() => _appearanceStore.writeTheme(mode));
      }
      return;
    }
    _appearanceStore.theme = mode;
    _application.notifyListeners();
    _appearance.notifyListeners();
    _settings.notifyListeners();
    notifyListeners();
    await _queuePositionWrite(
      () => _appearanceStore.writeTheme(_appearanceStore.theme),
    );
  }

  /// 确保当前选中的导入或下载字体已通过 FontLoader 加载（启动时调用）。
  /// 加载失败时回退到系统字体。
  Future<void> ensureFontLoaded() async {
    final activeId = _readerStore.appFontId;
    if (activeId != appFontSystem.id &&
        activeId != appFontSourceHanSerif.id) {
      try {
        if (!fonts.available(activeId)) throw StateError('字体不可用');
        await fonts.ensureLoaded(activeId);
      } catch (_) {
        _readerStore.appFontId = appFontSystem.id;
        try {
          await _readerStore.persistFontState();
        } catch (_) {}
        notifyListeners();
      }
    }
    final readerFont = _readerStore.readerTypeface;
    if (readerFont != followAppFont &&
        readerFont != appFontSystem.id &&
        readerFont != appFontSourceHanSerif.id) {
      try {
        if (!fonts.available(readerFont)) throw StateError('字体不可用');
        await fonts.ensureLoaded(readerFont);
      } catch (_) {
        _readerStore.readerTypeface = followAppFont;
      }
    }
  }

  /// 预加载全部已导入字体（供字体选择器预览用）；失败的跳过。
  Future<void> preloadImportedFonts() => fonts.preloadImportedFonts();

  /// 切换应用字体；导入或下载字体会先确保加载成功。
  Future<void> setAppFont(String id) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setAppFont(id));
    }
    if (id != appFontSystem.id &&
        id != appFontSourceHanSerif.id &&
        !fonts.available(id)) {
      throw const FormatException('请先导入这款字体');
    }
    await _queuePositionWrite(() async {
      if (_readerStore.appFontId == id) return;
      final previous = _readerStore.appFontId;
      _readerStore.appFontId = id;
      if (id != appFontSystem.id && id != appFontSourceHanSerif.id) {
        try {
          await fonts.ensureLoaded(id);
        } catch (_) {
          _readerStore.appFontId = previous;
          rethrow;
        }
      }
      try {
        await _readerStore.persistFontState();
      } catch (_) {
        _readerStore.appFontId = previous;
        rethrow;
      }
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
        notifyListeners();
      }
    });
  }

  /// 注册从手机导入的字体文件（文件已由原生层复制到私有目录）。
  /// 返回新字体的稳定 ID。
  Future<String> registerImportedFont(
    String filePath,
    String displayName,
  ) async {
    final id = await fonts.registerImportedFont(filePath, displayName);
    notifyListeners();
    return id;
  }

  /// 删除导入的字体（含文件）；若正选中则回退到系统字体。
  Future<void> removeImportedFont(String id) => removeUserFont(id);

  /// 兼容旧调用：枚举转字体 ID。
  Future<void> setAppTypeface(AppTypeface value) => setAppFont(
        value == AppTypeface.sourceHanSerif
            ? appFontSourceHanSerif.id
            : appFontSystem.id,
      );

  Future<void> setFontSize(double size, {bool persist = true}) =>
      setTypography(fontSize: size, persist: persist);

  Future<void> setLineHeight(double value, {bool persist = true}) =>
      setTypography(lineHeight: value, persist: persist);

  Future<void> setTypography({
    double? fontSize,
    double? lineHeight,
    bool persist = true,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setTypography(
          fontSize: fontSize,
          lineHeight: lineHeight,
          persist: persist,
        ),
      );
    }
    final font = fontSize?.isFinite == true
        ? fontSize!.clamp(readerFontSizeMin, readerFontSizeMax)
        : _readerStore.fontSize;
    final spacing = lineHeight?.isFinite == true
        ? lineHeight!.clamp(1.3, 2.2)
        : _readerStore.lineHeight;
    if (font != _readerStore.fontSize || spacing != _readerStore.lineHeight) {
      _readerStore.fontSize = font;
      _readerStore.lineHeight = spacing;
      _readerSettings.notifyListeners();
      _settings.notifyListeners();
    }
    if (persist) {
      final writeFont = fontSize?.isFinite == true;
      final writeSpacing = lineHeight?.isFinite == true;
      await _queuePositionWrite(
        () => _readerStore.writeTypography(
          fontSize: writeFont ? _readerStore.fontSize : null,
          lineHeight: writeSpacing ? _readerStore.lineHeight : null,
        ),
      );
    }
  }

  Future<void> setHaptics(HapticPreferences value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setHaptics(value));
    }
    await _queuePositionWrite(() async {
      if (_performanceStore.haptics == value) return;
      await _commitLibraryRecords(value.toRecords());
      _performanceStore.haptics = value;
      if (!_disposed) {
        _application.notifyListeners();
        _settings.notifyListeners();
      }
    });
  }

  Future<void> setPerformance(PerformancePreferences value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setPerformance(value));
    }
    await _queuePositionWrite(() async {
      if (_performanceStore.performance == value) return;
      await _commitLibraryRecords(value.toRecords());
      _performanceStore.performance = value;
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _settings.notifyListeners();
      }
    });
  }

  Future<void> setReduceMotion(bool value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setReduceMotion(value));
    }
    if (_performanceStore.reduceMotion == value) {
      if (_performanceStore.hasReduceMotionMismatch(value)) {
        await _queuePositionWrite(
          () => _performanceStore.writeReduceMotion(value),
        );
      }
      return;
    }
    _performanceStore.reduceMotion = value;
    _application.notifyListeners();
    _appearance.notifyListeners();
    _settings.notifyListeners();
    notifyListeners();
    await _queuePositionWrite(
      () => _performanceStore.writeReduceMotion(_performanceStore.reduceMotion),
    );
  }

  Future<void> setGlassBlur(double value, {bool persist = true}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setGlassBlur(value, persist: persist));
    }
    if (!value.isFinite) return;
    final next = value.clamp(0.0, 24.0);
    _markGlassAdvanced();
    if (_appearanceStore.glassBlur != next) {
      _appearanceStore.glassBlur = next;
      _glassChanges.notifyListeners();
      _appearance.notifyListeners();
      _settings.notifyListeners();
      notifyListeners();
    }
    if (persist) {
      await _queuePositionWrite(
        () => _appearanceStore.writeGlassBlur(_appearanceStore.glassBlur),
      );
    }
  }

  Future<void> setGlassOpacity(double value, {bool persist = true}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setGlassOpacity(value, persist: persist),
      );
    }
    if (!value.isFinite) return;
    final next = value.clamp(0.0, 1.0);
    _markGlassAdvanced();
    if (_appearanceStore.glassOpacity != next) {
      _appearanceStore.glassOpacity = next;
      _glassChanges.notifyListeners();
      _appearance.notifyListeners();
      _settings.notifyListeners();
      notifyListeners();
    }
    if (persist) {
      await _queuePositionWrite(
        () => _appearanceStore.writeGlassOpacity(_appearanceStore.glassOpacity),
      );
    }
  }

  /// Moving an advanced slider means the user wants exactly that value, so the
  /// sliders override the tier's blur/opacity until "恢复档位默认值".
  void _markGlassAdvanced() {
    if (_appearanceStore.glassAdvanced) return;
    _appearanceStore.glassAdvanced = true;
    _glassChanges.notifyListeners();
    _settings.notifyListeners();
  }

  void setDeviceProfile(DeviceProfile profile) {
    _deviceProfile = profile;
    if (_disposed) return;
    _application.notifyListeners();
    _glassChanges.notifyListeners();
    _appearance.notifyListeners();
    _settings.notifyListeners();
  }

  Future<void> _writeUiPreference(
    String key,
    Object value,
    void Function() apply, {
    bool glass = false,
    bool application = false,
    bool reader = false,
    bool shelf = false,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => _writeUiPreference(
          key,
          value,
          apply,
          glass: glass,
          application: application,
          reader: reader,
          shelf: shelf,
        ),
      );
    }
    apply();
    if (!_disposed) {
      if (glass) _glassChanges.notifyListeners();
      if (application) _application.notifyListeners();
      if (reader) {
        _readerSettings.notifyListeners();
        _readerBehaviorChanges.notifyListeners();
      }
      if (shelf) _shelfViewChanges.notifyListeners();
      _appearance.notifyListeners();
      _settings.notifyListeners();
      notifyListeners();
    }
    await _queuePositionWrite(() => writeLibraryPreference(_prefs, key, value));
  }

  /// Null selects the automatic tier (stored as "auto", never removed, so a
  /// backup can carry the explicit choice).
  Future<void> setGlassTier(GlassTier? tier) => _writeUiPreference(
    UiPreferenceKeys.glassTier,
    tier?.name ?? glassTierAuto,
    () => _appearanceStore.glassTier = tier,
    glass: true,
    application: true,
  );

  Future<void> setMotionLevel(MotionLevel value) => _writeUiPreference(
    UiPreferenceKeys.motionLevel,
    value.name,
    () => _performanceStore.motionLevel = value,
    application: true,
  );

  Future<void> setRandomPickPace(RandomPickPace value) => _writeUiPreference(
    UiPreferenceKeys.randomPickPace,
    value.name,
    () => _appearanceStore.randomPickPace = value,
  );

  Future<void> setPdfNightInvert(bool value) => _writeUiPreference(
    UiPreferenceKeys.pdfNightInvert,
    value,
    () => _readerStore.pdfNightInvert = value,
    reader: true,
  );

  Future<void> setShelfLayout(ShelfLayout value) => _writeUiPreference(
    UiPreferenceKeys.shelfLayout,
    value.name,
    () => _appearanceStore.shelfLayout = value,
    shelf: true,
  );

  Future<void> setPaletteVariant(OriginalPaletteVariant value) =>
      _writeUiPreference(
        UiPreferenceKeys.paletteVariant,
        value.name,
        () => _appearanceStore.paletteVariant = value,
        application: true,
      );

  Future<void> setTagMatchMode(TagMatchMode value) => _writeUiPreference(
    UiPreferenceKeys.tagMatchMode,
    value.name,
    () => _appearanceStore.tagMatchMode = value,
    shelf: true,
  );

  Future<void> setReaderPreferences(ReaderPreferences value) =>
      _writeUiPreference(
        UiPreferenceKeys.readerPreferences,
        jsonEncode(value.toJson()),
        () => _readerStore.readerPreferences = value,
        reader: true,
      );

  Future<void> _writeLibraryBatch(Map<String, Object> changes) async {
    if (LocalPlatform.android) {
      try {
        final committed = await LocalPlatform.channel.invokeMethod<bool>(
          'writeLibraryPreferences',
          {'changes': changes},
        );
        await _prefs.reload();
        if (committed != true) {
          throw StateError('Local preference batch did not commit');
        }
        return;
      } on MissingPluginException {
        // Other embedders retain the existing journal-protected write protocol.
      }
    }
    for (final entry in changes.entries) {
      await writeLibraryPreference(_prefs, entry.key, entry.value);
    }
  }

  Future<void> _commitLibraryRecords(Map<String, Object> changes, {
    bool repairingShelf = false,
  }) async {
    changes = Map<String, Object>.of(changes);
    if (changes.containsKey('shelf') && !repairingShelf) _requireShelfLoaded();
    changes.removeWhere(
      (key, value) => jsonEncode(_prefs.get(key)) == jsonEncode(value),
    );
    if (changes.isEmpty) return;
    final journal = jsonEncode({
      for (final key in changes.keys) key: _prefs.get(key),
    });
    if (utf8.encode(journal).length > LibraryBackup.maxBytes * 2) {
      throw const FormatException('本地恢复日志过大');
    }
    try {
      await writeLibraryPreference(_prefs, restoreJournalKey, journal);
      await _writeLibraryBatch(changes);
      await writeLibraryPreference(_prefs, restoreJournalKey, null);
    } catch (_) {
      if (_prefs.get(restoreJournalKey) != null) {
        await recoverLibraryRestore(_prefs);
      }
      rethrow;
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    readingActivity.dispose();
    readingMoments.dispose();
    _appearance.dispose();
    _application.dispose();
    _glassChanges.dispose();
    _readerSettings.dispose();
    _settings.dispose();
    _history.dispose();
    _bookmarkChanges.dispose();
    _underlineChanges.dispose();
    _searchChanges.dispose();
    _shelfViewChanges.dispose();
    _readerBehaviorChanges.dispose();
    super.dispose();
  }
}

class FileTextAnchor {
  FileTextAnchor._(this.file, this.length, this._text);
  final File file;
  final int length;
  final String? _text;
  static const maxSliceLength = 4 * 1024 * 1024;

  static Future<FileTextAnchor> open(String path) async {
    final file = File(path);
    if (await file.length() <= 2 * 1024 * 1024) {
      final text = await file.readAsString();
      return FileTextAnchor._(file, text.length, text);
    }
    var length = 0;
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      length += chunk.length;
    }
    return FileTextAnchor._(file, length, null);
  }

  Future<String> slice(int start, int end) async {
    if (start < 0 || end < start || end > length) {
      throw StateError('阅读锚点范围损坏');
    }
    if (end - start > maxSliceLength) {
      throw const FormatException('单章正文过大，请拆分章节后迁移阅读进度');
    }
    if (_text case final text?) return text.substring(start, end);
    var offset = 0;
    final result = StringBuffer();
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final next = offset + chunk.length;
      if (next > start && offset < end) {
        result.write(
          chunk.substring(
            start > offset ? start - offset : 0,
            end < next ? end - offset : chunk.length,
          ),
        );
      }
      offset = next;
      if (offset >= end) break;
    }
    if (result.length != end - start) throw StateError('迁移期间正文发生变化');
    return result.toString();
  }

  Stream<String> _chunks(int start, int end) async* {
    if (start < 0 || end < start || end > length) {
      throw StateError('阅读锚点范围损坏');
    }
    var offset = 0;
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final next = offset + chunk.length;
      if (next > start && offset < end) {
        yield chunk.substring((start - offset).clamp(0, chunk.length),
            (end - offset).clamp(0, chunk.length));
      }
      offset = next;
      if (offset >= end) break;
    }
    if (offset < end) throw StateError('迁移期间正文发生变化');
  }

  Future<({int start, int end})> trimmedRange(int start, int end) async {
    int? first;
    var last = start;
    var offset = start;
    await for (final chunk in _chunks(start, end)) {
      final left = chunk.trimLeft();
      if (first == null && left.isNotEmpty) first = offset + chunk.length - left.length;
      final right = chunk.trimRight();
      if (right.isNotEmpty) last = offset + right.length;
      offset += chunk.length;
    }
    return (start: first ?? end, end: first == null ? end : last);
  }

  Future<({int index, int start})> paragraphAt(int start, int end, {int? stopAt}) async {
    var paragraph = 0;
    var paragraphStart = 0;
    var consumed = 0;
    var newline = false;
    if (stopAt == 0) return (index: 0, start: 0);
    await for (final chunk in _chunks(start, end)) {
      for (final unit in chunk.codeUnits) {
        consumed++;
        if (unit == 10 && newline) {
          paragraph++;
          paragraphStart = consumed;
          newline = false;
          if (stopAt != null && paragraph >= stopAt) {
            return (index: paragraph, start: paragraphStart);
          }
        } else {
          newline = unit == 10;
        }
      }
    }
    return (index: paragraph, start: paragraphStart);
  }

  Future<int> relocateFrom(FileTextAnchor old, int offset) async {
    offset = offset.clamp(0, old.length);
    if (old._text != null && _text != null) {
      return relocateTextOffset(old._text, _text, offset);
    }
    if (old.file.path == file.path) {
      if (old.length != length) {
        throw StateError('迁移期间正文发生变化');
      }
      return offset;
    }
    final windowStart = (offset - 4096).clamp(0, old.length);
    final windowEnd = (offset + 4160).clamp(0, old.length);
    final window = await old.slice(windowStart, windowEnd);
    final candidates = <({String text, int expected, int adjustment})>[];
    void add(int start, int end, int adjustment) {
      final text = window.substring(start - windowStart, end - windowStart);
      if (text.trim().isNotEmpty) {
        candidates.add((text: text, expected: start, adjustment: adjustment));
      }
    }

    final left = (offset - 32).clamp(0, old.length);
    final right = (offset + 96).clamp(0, old.length);
    add(left, right, offset - left);
    add(offset, right, 0);
    for (var distance = 64; distance <= 4096; distance *= 2) {
      for (final sign in [1, -1]) {
        final start = (offset + sign * distance).clamp(0, old.length);
        final end = (start + 64).clamp(0, old.length);
        if (end - start >= 16) add(start, end, sign > 0 ? 0 : end - start);
      }
    }
    final matches = List<int?>.filled(candidates.length, null);
    var consumed = 0;
    var tail = '';
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final text = '$tail$chunk';
      final base = consumed - tail.length;
      for (var candidate = 0; candidate < candidates.length; candidate++) {
        final needle = candidates[candidate];
        var best = matches[candidate];
        if (best != null &&
            base - needle.expected >= (best - needle.expected).abs()) {
          continue;
        }
        var found = text.indexOf(needle.text);
        while (found >= 0) {
          final position = base + found;
          if (best == null ||
              (position - needle.expected).abs() <
                  (best - needle.expected).abs()) {
            best = position;
          }
          if (position >= needle.expected) break;
          found = text.indexOf(needle.text, found + 1);
        }
        matches[candidate] = best;
      }
      consumed += chunk.length;
      tail = text.substring((text.length - 127).clamp(0, text.length));
    }
    for (var candidate = 0; candidate < candidates.length; candidate++) {
      if (matches[candidate] case final match?) {
        return match + candidates[candidate].adjustment;
      }
    }
    return offset.clamp(0, length);
  }

  Future<
    ({
      int chapter,
      int textOffset,
      int paragraph,
      int paragraphStart,
      double fraction,
    })
  >
  locate(List<LocalChapterIndex> chapters, int global) async {
    if (chapters.isEmpty) {
      throw StateError('Cannot anchor an empty chapter table');
    }
    var index = chapters.indexWhere(
      (chapter) => global < chapter.offset + chapter.length,
    );
    if (index < 0) index = chapters.length - 1;
    final chapter = chapters[index];
    if (chapter.length > maxSliceLength) {
      final range = await trimmedRange(chapter.offset, chapter.offset + chapter.length);
      final bodyLength = range.end - range.start;
      final local = (global - range.start).clamp(0, bodyLength);
      final paragraph = await paragraphAt(range.start, range.start + local);
      return (chapter: index, textOffset: local,
        paragraph: paragraph.index, paragraphStart: paragraph.start,
        fraction: bodyLength == 0 ? 0.0 : local / bodyLength);
    }
    final body = await slice(chapter.offset, chapter.offset + chapter.length);
    final target = locateTextAnchor(body, [
      LocalChapterIndex(chapter.title, 0, body.length),
    ], global - chapter.offset);
    return (
      chapter: index,
      textOffset: target.textOffset,
      paragraph: target.paragraph,
      paragraphStart: target.paragraphStart,
      fraction: target.fraction,
    );
  }
}

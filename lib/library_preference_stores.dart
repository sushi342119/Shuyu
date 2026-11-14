import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'app_typography.dart';
import 'haptic_preferences.dart';
import 'library_backup.dart';
import 'performance_preferences.dart';
import 'reader_preferences.dart';
import 'ui_preferences.dart';
import 'user_fonts.dart';

double _readClampedPreference(
  SharedPreferences prefs,
  String key,
  double fallback,
  double min,
  double max,
) {
  final value = prefs.get(key);
  return value is num && value.isFinite
      ? value.toDouble().clamp(min, max)
      : fallback;
}

/// 封装阅读器排版、字体与阅读行为偏好。
class ReaderSettingsPreferenceStore {
  ReaderSettingsPreferenceStore(this._prefs);

  final SharedPreferences _prefs;

  double fontSize = 19;
  double lineHeight = 1.72;
  String readerTypeface = followAppFont;
  bool keepScreenOn = false;
  bool pdfNightInvert = true;
  ReaderPreferences readerPreferences = const ReaderPreferences();
  String appFontId = appFontSystem.id;

  void load({UserFontStore? fonts}) {
    fontSize = _readClampedPreference(
      _prefs,
      'readerFontSize',
      19,
      readerFontSizeMin,
      readerFontSizeMax,
    );
    lineHeight = _readClampedPreference(
      _prefs,
      'readerLineHeight',
      1.72,
      1.3,
      2.2,
    );
    readerTypeface = switch (_prefs.get('readerTypeface')) {
      final String value when validFontChoice(value, follow: true) => value,
      _ => followAppFont,
    };
    keepScreenOn = _prefs.get('readerKeepScreenOn') == true;
    loadFontState(fonts: fonts);
    loadUiPreferences();
  }

  void loadUiPreferences() {
    pdfNightInvert = _prefs.get(UiPreferenceKeys.pdfNightInvert) != false;
    final reader = _prefs.get(UiPreferenceKeys.readerPreferences);
    readerPreferences = reader == null
        ? const ReaderPreferences()
        : ReaderPreferences.fromRecord(reader);
  }

  void loadFontState({UserFontStore? fonts}) {
    final rawId = _prefs.getString('appFontId');
    if (rawId != null && rawId.isNotEmpty) {
      appFontId = rawId;
    } else {
      appFontId = AppTypeface.fromRecord(_prefs.get('appTypeface')).name ==
              'sourceHanSerif'
          ? appFontSourceHanSerif.id
          : appFontSystem.id;
      unawaited(persistMigratedFontId());
    }
    if (appFontId != appFontSystem.id &&
        appFontId != appFontSourceHanSerif.id &&
        !(fonts?.available(appFontId) ?? false) &&
        !validFontChoice(appFontId)) {
      appFontId = appFontSystem.id;
    }
  }

  Future<void> persistMigratedFontId() async {
    try {
      await _prefs.setString('appFontId', appFontId);
    } catch (_) {}
  }

  Future<void> persistFontState() => _prefs.setString('appFontId', appFontId);

  Future<void> writeTypography({
    double? fontSize,
    double? lineHeight,
  }) async {
    if (fontSize != null) {
      await writeLibraryPreference(_prefs, 'readerFontSize', fontSize);
    }
    if (lineHeight != null) {
      await writeLibraryPreference(_prefs, 'readerLineHeight', lineHeight);
    }
  }

  Future<void> writeKeepScreenOn(bool value) =>
      writeLibraryPreference(_prefs, 'readerKeepScreenOn', value);

  Map<String, Object> toBackupRecords() => {
    'readerFontSize': fontSize,
    'readerLineHeight': lineHeight,
    'appFontId': appFontId,
    'readerTypeface': readerTypeface,
    UiPreferenceKeys.pdfNightInvert: pdfNightInvert,
    UiPreferenceKeys.readerPreferences: jsonEncode(readerPreferences.toJson()),
    'readerKeepScreenOn': keepScreenOn,
  };

  void applyBackupRecords(Map<String, Object> records) {
    if (records['readerFontSize'] case final num value) {
      fontSize = value.toDouble();
    }
    if (records['readerLineHeight'] case final num value) {
      lineHeight = value.toDouble();
    }
    if (records['appFontId'] case final String value) {
      if (validFontChoice(value)) {
        appFontId = value;
      }
    } else if (records['appTypeface'] case final String value) {
      if (validFontChoice(value)) {
        appFontId = value;
      }
    }
    if (records['readerTypeface'] case final String value
        when validFontChoice(value, follow: true)) {
      readerTypeface = value;
    }
    if (records['readerKeepScreenOn'] case final bool value) {
      keepScreenOn = value;
    }
    loadUiPreferences();
  }
}

/// 封装主题、配色、液态玻璃与书架视图偏好。
class AppearancePreferenceStore {
  AppearancePreferenceStore(this._prefs);

  final SharedPreferences _prefs;

  ThemeMode theme = ThemeMode.system;
  AppPalettePreferences appPalette = const AppPalettePreferences();
  OriginalPaletteVariant paletteVariant = OriginalPaletteVariant.vivid;
  double glassBlur = 8;
  double glassOpacity = .87;
  GlassTier? glassTier;
  bool glassAdvanced = false;
  RandomPickPace randomPickPace = RandomPickPace.quick;
  ShelfLayout shelfLayout = ShelfLayout.list;
  TagMatchMode tagMatchMode = TagMatchMode.any;
  String shelfSort = 'recentRead';
  String shelfFilter = 'all';

  void load() {
    theme = switch (_prefs.get('theme')) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    try {
      appPalette = AppPalettePreferences.decode(
        _prefs.get(AppPalettePreferences.key),
      );
    } on FormatException {
      /* Preserve an unreadable record; use the original theme until edited. */
    }
    glassBlur = _readClampedPreference(_prefs, 'glassBlur', 8, 0, 24);
    glassOpacity = _readClampedPreference(_prefs, 'glassOpacity', .87, 0, 1);
    final rawSort = _prefs.get('shelfSort');
    shelfSort = rawSort is String && shelfSortValues.contains(rawSort)
        ? rawSort
        : 'recentRead';
    shelfFilter = switch (_prefs.get('shelfFilter')) {
      'unread' => 'unread',
      'reading' => 'reading',
      'finished' => 'finished',
      'untagged' => 'untagged',
      _ => 'all',
    };
    loadUiPreferences();
  }

  void loadUiPreferences() {
    final tier = _prefs.get(UiPreferenceKeys.glassTier);
    glassTier = tier == glassTierAuto ? null : GlassTier.fromRecord(tier);
    final advanced = _prefs.get(UiPreferenceKeys.glassAdvanced);
    glassAdvanced = advanced is bool
        ? advanced
        : (_prefs.get('glassBlur') is num && glassBlur != 8) ||
              (_prefs.get('glassOpacity') is num && glassOpacity != .87);
    randomPickPace = RandomPickPace.fromRecord(
      _prefs.get(UiPreferenceKeys.randomPickPace),
    );
    shelfLayout = ShelfLayout.fromRecord(
      _prefs.get(UiPreferenceKeys.shelfLayout),
    );
    tagMatchMode = TagMatchMode.fromRecord(
      _prefs.get(UiPreferenceKeys.tagMatchMode),
    );
    paletteVariant = OriginalPaletteVariant.fromRecord(
      _prefs.get(UiPreferenceKeys.paletteVariant),
    );
  }

  void resetRetired() {
    glassBlur = 8;
    glassOpacity = .87;
    glassAdvanced = false;
  }

  Future<void> writeTheme(ThemeMode mode) =>
      writeLibraryPreference(_prefs, 'theme', mode.name);

  bool hasThemeMismatch(ThemeMode mode) =>
      _prefs.get('theme') != null && _prefs.get('theme') != mode.name;

  Future<void> writeAppPalette(AppPalettePreferences value) =>
      writeLibraryPreference(_prefs, AppPalettePreferences.key, value.encode());

  Future<void> writeGlassBlur(double value) async {
    await writeLibraryPreference(_prefs, 'glassBlur', value);
    await persistGlassAdvanced();
  }

  Future<void> writeGlassOpacity(double value) async {
    await writeLibraryPreference(_prefs, 'glassOpacity', value);
    await persistGlassAdvanced();
  }

  Future<void> persistGlassAdvanced() async {
    if (_prefs.get(UiPreferenceKeys.glassAdvanced) != glassAdvanced) {
      await writeLibraryPreference(
        _prefs,
        UiPreferenceKeys.glassAdvanced,
        glassAdvanced,
      );
    }
  }

  Map<String, Object> toBackupRecords() => {
    'theme': theme.name,
    AppPalettePreferences.key: appPalette.encode(),
    'glassBlur': glassBlur,
    'glassOpacity': glassOpacity,
    UiPreferenceKeys.glassTier: glassTier?.name ?? glassTierAuto,
    UiPreferenceKeys.glassAdvanced: glassAdvanced,
    UiPreferenceKeys.randomPickPace: randomPickPace.name,
    UiPreferenceKeys.shelfLayout: shelfLayout.name,
    UiPreferenceKeys.tagMatchMode: tagMatchMode.name,
    UiPreferenceKeys.paletteVariant: paletteVariant.name,
    'shelfSort': shelfSort,
    'shelfFilter': shelfFilter,
  };

  void applyBackupRecords(Map<String, Object> records) {
    if (records['theme'] case final String value) {
      theme = ThemeMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => ThemeMode.system,
      );
    }
    if (records[AppPalettePreferences.key] case final String value) {
      try {
        appPalette = AppPalettePreferences.decode(value);
      } on FormatException {
        /* Keep existing palette if malformed. */
      }
    }
    if (records['glassBlur'] case final num value) {
      glassBlur = value.toDouble();
    }
    if (records['glassOpacity'] case final num value) {
      glassOpacity = value.toDouble();
    }
    if (records['shelfSort'] case final String value
        when shelfSortValues.contains(value)) {
      shelfSort = value;
    }
    if (records['shelfFilter'] case final String value) shelfFilter = value;
    loadUiPreferences();
    resetRetired();
  }
}

/// 封装性能开关、动效等级与触感反馈偏好。
class PerformancePreferenceStore {
  PerformancePreferenceStore(this._prefs);

  final SharedPreferences _prefs;

  PerformancePreferences performance = const PerformancePreferences();
  HapticPreferences haptics = const HapticPreferences();
  bool reduceMotion = false;
  MotionLevel motionLevel = MotionLevel.light;

  void load() {
    reduceMotion = _prefs.get('reduceMotion') == true;
    haptics = HapticPreferences.fromRecords({
      HapticPreferences.preferenceKey: _prefs.get(
        HapticPreferences.preferenceKey,
      ),
    });
    performance = PerformancePreferences.fromRecords({
      for (final key in [
        PerformancePreferences.modeKey,
        ...PerformanceEffect.values.map((effect) => effect.preferenceKey),
      ])
        key: _prefs.get(key),
    });
    loadUiPreferences();
  }

  void loadUiPreferences() {
    motionLevel = MotionLevel.fromRecord(
      _prefs.get(UiPreferenceKeys.motionLevel),
    );
  }

  void resetRetired() {
    reduceMotion = false;
    performance = const PerformancePreferences();
  }

  bool hasReduceMotionMismatch(bool value) =>
      _prefs.get('reduceMotion') != null && _prefs.get('reduceMotion') != value;

  Future<void> writeReduceMotion(bool value) =>
      writeLibraryPreference(_prefs, 'reduceMotion', value);

  Map<String, Object> toBackupRecords() => {
    'reduceMotion': reduceMotion,
    ...haptics.toRecords(),
    ...performance.toRecords(),
    UiPreferenceKeys.motionLevel: motionLevel.name,
  };

  void applyBackupRecords(Map<String, Object> records) {
    if (records['reduceMotion'] case final bool value) {
      reduceMotion = value;
    }
    if (records.containsKey(HapticPreferences.preferenceKey)) {
      haptics = HapticPreferences.fromRecords(records);
    }
    performance = PerformancePreferences.fromRecords({
      ...performance.toRecords(),
      for (final key in performance.toRecords().keys)
        if (records.containsKey(key)) key: records[key],
    });
    loadUiPreferences();
    resetRetired();
  }
}

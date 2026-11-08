import 'dart:convert';

import 'package:flutter/widgets.dart';

/// User-facing interaction groups, independent of the platform vibration API.
enum HapticCategory {
  controls,
  shelf,
  reading,
  adjustment,
  longPress,
  boundary,
  result,
}

/// Strength changes the pulse, not how often accepted interactions respond.
enum HapticStrength {
  light('轻'),
  standard('标准'),
  strong('强');

  const HapticStrength(this.label);
  final String label;
}

/// Four-level global tactile selector shown in the appearance & performance panel.
enum HapticLevel {
  off('关'),
  light('轻', HapticStrength.light),
  standard('标准', HapticStrength.standard),
  strong('强', HapticStrength.strong);

  const HapticLevel(this.label, [this.strength]);
  final String label;
  final HapticStrength? strength;
}

/// A category retains its strength while switched off.
@immutable
class HapticCategoryPreference {
  const HapticCategoryPreference({
    this.enabled = true,
    this.strength = HapticStrength.standard,
  });

  final bool enabled;
  final HapticStrength strength;

  @override
  bool operator ==(Object other) =>
      other is HapticCategoryPreference &&
      enabled == other.enabled &&
      strength == other.strength;

  @override
  int get hashCode => Object.hash(enabled, strength);
}

/// App-wide tactile preferences. The global strength action replaces each
/// category's strength; there is no second multiplier or hidden attenuation.
@immutable
class HapticPreferences {
  const HapticPreferences({this.enabled = true}) : _categories = const {};

  HapticPreferences._({
    required this.enabled,
    required Map<HapticCategory, HapticCategoryPreference> categories,
  }) : _categories = Map.unmodifiable(categories);

  static const preferenceKey = 'hapticPreferences';
  final bool enabled;
  final Map<HapticCategory, HapticCategoryPreference> _categories;

  /// Missing or unreadable legacy storage keeps the existing all-on behavior.
  factory HapticPreferences.fromRecords(Map<String, Object?> records) {
    final record = records[preferenceKey];
    if (record == null) return const HapticPreferences();
    try {
      return HapticPreferences.decode(record);
    } on FormatException {
      return const HapticPreferences();
    }
  }

  /// Validates persisted data before it can participate in a backup restore.
  factory HapticPreferences.decode(Object? record) {
    if (record is! String || record.length > 4096) {
      throw const FormatException('振动设置格式有误');
    }
    final json = jsonDecode(record);
    if (json is! Map<String, dynamic> ||
        (json['version'] != null && json['version'] != 1) ||
        (json['enabled'] != null && json['enabled'] is! bool) ||
        (json['categories'] != null && json['categories'] is! Map)) {
      throw const FormatException('振动设置格式有误');
    }
    final categories = <HapticCategory, HapticCategoryPreference>{};
    final stored = json['categories'] as Map? ?? const {};
    for (final category in HapticCategory.values) {
      final value = stored[category.name];
      if (value == null) continue;
      if (value is! Map ||
          (value['enabled'] != null && value['enabled'] is! bool) ||
          (value['strength'] != null &&
              !HapticStrength.values.any(
                (strength) => strength.name == value['strength'],
              ))) {
        throw const FormatException('振动分类设置格式有误');
      }
      categories[category] = HapticCategoryPreference(
        enabled: value['enabled'] as bool? ?? true,
        strength: HapticStrength.values.firstWhere(
          (strength) => strength.name == value['strength'],
          orElse: () => HapticStrength.standard,
        ),
      );
    }
    return HapticPreferences._(
      enabled: json['enabled'] as bool? ?? true,
      categories: categories,
    );
  }

  HapticCategoryPreference forCategory(HapticCategory category) =>
      _categories[category] ?? const HapticCategoryPreference();

  /// Null means silent. Stored category values are never erased by a switch.
  HapticStrength? levelFor(HapticCategory category) {
    final preference = forCategory(category);
    return enabled && preference.enabled ? preference.strength : null;
  }

  /// Null denotes a customized mix, so the UI does not imply a global scale.
  HapticStrength? get uniformStrength {
    final first = forCategory(HapticCategory.values.first).strength;
    return HapticCategory.values.every(
          (category) => forCategory(category).strength == first,
        )
        ? first
        : null;
  }

  /// Current four-level choice for the unified appearance & performance panel.
  HapticLevel get level {
    if (!enabled) return HapticLevel.off;
    final strength =
        uniformStrength ?? forCategory(HapticCategory.controls).strength;
    return switch (strength) {
      HapticStrength.light => HapticLevel.light,
      HapticStrength.standard => HapticLevel.standard,
      HapticStrength.strong => HapticLevel.strong,
    };
  }

  HapticPreferences withEnabled(bool value) =>
      HapticPreferences._(enabled: value, categories: _categories);

  HapticPreferences withLevel(HapticLevel value) => switch (value.strength) {
    null => withEnabled(false),
    final strength => HapticPreferences._(
      enabled: true,
      categories: {
        for (final category in HapticCategory.values)
          category: HapticCategoryPreference(strength: strength),
      },
    ),
  };

  Map<String, String> toRecords() => {
    preferenceKey: jsonEncode({
      'version': 1,
      'enabled': enabled,
      'categories': {
        for (final category in HapticCategory.values)
          category.name: {
            'enabled': forCategory(category).enabled,
            'strength': forCategory(category).strength.name,
          },
      },
    }),
  };

  @override
  bool operator ==(Object other) =>
      other is HapticPreferences &&
      enabled == other.enabled &&
      HapticCategory.values.every(
        (category) => forCategory(category) == other.forCategory(category),
      );

  @override
  int get hashCode => Object.hash(
    enabled,
    Object.hashAll(HapticCategory.values.map(forCategory)),
  );
}

/// Keeps manual interactions in sync with the current app-level preferences.
class HapticScope extends InheritedWidget {
  const HapticScope({
    super.key,
    required this.preferences,
    required super.child,
  });

  final HapticPreferences preferences;

  static HapticPreferences of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HapticScope>()?.preferences ??
      const HapticPreferences();

  @override
  bool updateShouldNotify(HapticScope oldWidget) =>
      preferences != oldWidget.preferences;
}

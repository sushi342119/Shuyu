import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'reading_activity.dart';
import 'reading_visual_theme.dart';

/// An earned, lifetime reading milestone. Opening the app earns nothing.
enum ReadingMomentKind { firstDay, streak, duration, completion }

/// Presentation preferences never disable measurement or erase earned history.
@immutable
class ReadingMomentsPreferences {
  const ReadingMomentsPreferences({
    this.enabled = true,
    this.milestones = true,
    this.completions = true,
    this.confetti = true,
    this.themeId = 'archive',
  });
  final bool enabled, milestones, completions, confetti;
  final String themeId;

  ReadingMomentsPreferences copyWith({
    bool? enabled,
    bool? milestones,
    bool? completions,
    bool? confetti,
    String? themeId,
  }) => ReadingMomentsPreferences(
    enabled: enabled ?? this.enabled,
    milestones: milestones ?? this.milestones,
    completions: completions ?? this.completions,
    confetti: confetti ?? this.confetti,
    themeId: themeId ?? this.themeId,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'milestones': milestones,
    'completions': completions,
    'confetti': confetti,
    'themeId': themeId,
  };

  factory ReadingMomentsPreferences.fromJson(Object? raw) {
    if (raw == null) return const ReadingMomentsPreferences();
    if (raw is! Map<String, dynamic> ||
        raw['enabled'] is! bool ||
        raw['milestones'] is! bool ||
        raw['completions'] is! bool ||
        raw['confetti'] is! bool ||
        raw['themeId'] is! String ||
        !RegExp(
          r'^[a-z][a-z0-9_-]{0,63}$',
        ).hasMatch(raw['themeId'] as String)) {
      throw const FormatException('阅读纪念设置格式有误');
    }
    return ReadingMomentsPreferences(
      enabled: raw['enabled'] as bool,
      milestones: raw['milestones'] as bool,
      completions: raw['completions'] as bool,
      confetti: raw['confetti'] as bool,
      themeId: ReadingVisualTheme.fromId(raw['themeId'] as String).id,
    );
  }
}

/// A durable book identity and the measurements available at its last page.
/// No field depends on the original local book remaining in the library.
@immutable
class ReadingCompletionSnapshot {
  const ReadingCompletionSnapshot({
    required this.bookId,
    required this.title,
    required this.author,
    required this.completedAt,
    required this.finished,
    this.coverPath,
    this.verifiedSeconds,
    this.readingDays = 0,
    this.firstReadAt,
    this.lastReadAt,
    this.completedOffsetMinutes,
    this.firstReachedEndAt,
    this.firstReachedEndOffsetMinutes,
  });

  final int bookId;
  final String title, author;
  final String? coverPath;
  final DateTime completedAt;
  final int? completedOffsetMinutes;

  /// Retains the first reached-end observation when a serial later finishes.
  final DateTime? firstReachedEndAt;
  final int? firstReachedEndOffsetMinutes;
  final bool finished;
  final int? verifiedSeconds;
  final int readingDays;
  final DateTime? firstReadAt, lastReadAt;

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'title': title,
    'author': author,
    'completedAt': completedAt.millisecondsSinceEpoch,
    if (completedOffsetMinutes != null)
      'completedOffsetMinutes': completedOffsetMinutes,
    if (firstReachedEndAt != null)
      'firstReachedEndAt': firstReachedEndAt!.millisecondsSinceEpoch,
    if (firstReachedEndOffsetMinutes != null)
      'firstReachedEndOffsetMinutes': firstReachedEndOffsetMinutes,
    'finished': finished,
    'coverPath': coverPath,
    'verifiedSeconds': verifiedSeconds,
    'readingDays': readingDays,
    'firstReadAt': firstReadAt?.millisecondsSinceEpoch,
    'lastReadAt': lastReadAt?.millisecondsSinceEpoch,
  };

  factory ReadingCompletionSnapshot.fromJson(Map<String, dynamic> json) {
    final id = json['bookId'], title = json['title'], author = json['author'];
    final finished = json['finished'], seconds = json['verifiedSeconds'];
    final days = json['readingDays'], cover = json['coverPath'];
    final offset = json['completedOffsetMinutes'];
    final firstOffset = json['firstReachedEndOffsetMinutes'];
    if (id is! int ||
        id <= 0 ||
        id > 9999999999 ||
        title is! String ||
        title.isEmpty ||
        title.length > 4096 ||
        author is! String ||
        author.length > 4096 ||
        finished is! bool ||
        days is! int ||
        days < 0 ||
        (offset != null && (offset is! int || offset < -840 || offset > 840)) ||
        (firstOffset != null &&
            (firstOffset is! int ||
                firstOffset < -840 ||
                firstOffset > 840 ||
                json['firstReachedEndAt'] == null)) ||
        (seconds != null && (seconds is! int || seconds < 0)) ||
        (cover != null && (cover is! String || cover.length > 4096))) {
      throw const FormatException('阅读纪念书籍格式有误');
    }
    return ReadingCompletionSnapshot(
      bookId: id,
      title: title,
      author: author,
      completedAt: _timestamp(json['completedAt']),
      completedOffsetMinutes: offset as int?,
      firstReachedEndAt: _optionalTimestamp(json['firstReachedEndAt']),
      firstReachedEndOffsetMinutes: firstOffset as int?,
      finished: finished,
      coverPath: cover as String?,
      verifiedSeconds: seconds as int?,
      readingDays: days,
      firstReadAt: _optionalTimestamp(json['firstReadAt']),
      lastReadAt: _optionalTimestamp(json['lastReadAt']),
    );
  }
}

/// An immutable entry; presentation state is stored separately from its content.
@immutable
class ReadingMoment {
  const ReadingMoment({
    required this.id,
    required this.kind,
    required this.earnedAt,
    this.value = 0,
    this.completion,
  });

  final String id;
  final ReadingMomentKind kind;
  final DateTime earnedAt;
  final int value;
  final ReadingCompletionSnapshot? completion;

  String get title => switch (kind) {
    ReadingMomentKind.firstDay => '故事，从今天开始',
    ReadingMomentKind.streak => '与文字相伴的 $value 天',
    ReadingMomentKind.duration => '把 $value 小时，留给阅读',
    ReadingMomentKind.completion =>
      completion!.finished ? '又读完了一个世界' : '读到故事的此刻',
  };

  String get subtitle => switch (kind) {
    ReadingMomentKind.firstDay => '第一次，认真读满五分钟。',
    ReadingMomentKind.streak => '连续 $value 天，每天至少五分钟。',
    ReadingMomentKind.duration => '一页一页，积攒成自己的时光。',
    ReadingMomentKind.completion =>
      completion!.finished ? '合上书页，故事仍在心里。' : '下一段故事，值得等待。',
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'earnedAt': earnedAt.millisecondsSinceEpoch,
    'value': value,
    if (completion != null) 'completion': completion!.toJson(),
  };

  factory ReadingMoment.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'], id = json['id'], value = json['value'];
    final kind = ReadingMomentKind.values
        .where((k) => k.name == kindName)
        .firstOrNull;
    if (kind == null || id is! String || value is! int || value < 0) {
      throw const FormatException('阅读纪念格式有误');
    }
    final raw = json['completion'];
    final completion = raw is Map<String, dynamic>
        ? ReadingCompletionSnapshot.fromJson(raw)
        : null;
    final valid = switch (kind) {
      ReadingMomentKind.firstDay => id == 'first_day' && value == 1,
      ReadingMomentKind.streak =>
        id == 'streak:$value' &&
            ReadingMomentsStore.streakMilestones.contains(value),
      ReadingMomentKind.duration =>
        id == 'duration:$value' &&
            ReadingMomentsStore.hourMilestones.contains(value),
      ReadingMomentKind.completion =>
        completion != null && id == 'completion:${completion.bookId}',
    };
    if (!valid || (kind != ReadingMomentKind.completion && raw != null)) {
      throw const FormatException('阅读纪念标识有误');
    }
    return ReadingMoment(
      id: id,
      kind: kind,
      earnedAt: _timestamp(json['earnedAt']),
      value: value,
      completion: completion,
    );
  }
}

/// Verified reading has its own new ledger; old foreground totals remain intact.
/// This notifier is also the read-only source for native widget snapshots.
class ReadingMomentsStore extends ChangeNotifier {
  ReadingMomentsStore({String? record, Future<void> Function()? persist})
    : _persist = persist {
    if (record == null) {
      _activity = ReadingActivityStore(collectDetails: false);
    } else {
      final decoded = _decode(record);
      _activity = ReadingActivityStore(
        record: decoded.activity,
        collectDetails: false,
      );
      _moments.addAll(decoded.moments);
      _presented.addAll(decoded.presented);
      _preferences = decoded.preferences;
    }
  }

  static const preferenceKey = 'reading_moments_v1';
  static const qualifyingSeconds = 300;
  static const streakMilestones = [3, 7, 14, 30, 100, 365];
  static const hourMilestones = [1, 10, 50, 100, 500];
  final Future<void> Function()? _persist;
  late final ReadingActivityStore _activity;
  final Map<String, ReadingMoment> _moments = {};
  final Set<String> _presented = {};
  bool _disposed = false;
  ReadingMomentsPreferences _preferences = const ReadingMomentsPreferences();

  ReadingMomentsPreferences get preferences => _preferences;

  DateTime? get trackedSince => _activity.startedAt;
  int get verifiedTotalSeconds => _activity.totalSeconds;

  /// Unknown before measurement began; zero is a measured calendar-day absence.
  int? verifiedSecondsOn(DateTime localDay) {
    final start = trackedSince;
    final date = _day(localDay.toLocal());
    if (start == null || date.isBefore(_day(start))) return null;
    for (final day in _activity.days) {
      if (day.date == date) return day.seconds;
    }
    return 0;
  }

  /// Today's ongoing streak keeps yesterday's qualifying run until today ends.
  int qualifiedStreakDaysAt(DateTime now) {
    var date = _day(now.toLocal());
    if ((verifiedSecondsOn(date) ?? 0) < qualifyingSeconds) {
      date = DateTime(date.year, date.month, date.day - 1);
    }
    var count = 0;
    while ((verifiedSecondsOn(date) ?? 0) >= qualifyingSeconds) {
      count++;
      date = DateTime(date.year, date.month, date.day - 1);
    }
    return count;
  }

  List<ReadingMoment> get moments => List.unmodifiable(
    _moments.values.toList()..sort((a, b) => b.earnedAt.compareTo(a.earnedAt)),
  );

  ReadingCompletionSnapshot? get latestCompletion => moments
      .where((moment) => moment.completion != null)
      .map((moment) => moment.completion)
      .firstOrNull;

  String encode() => jsonEncode({
    'version': 1,
    'activity': _activity.encode(),
    'moments': _moments.values.map((event) => event.toJson()).toList(),
    'presented': _presented.toList()..sort(),
    'preferences': _preferences.toJson(),
  });

  static String validateRecord(String record) {
    final store = ReadingMomentsStore(record: record);
    try {
      return store.encode();
    } finally {
      store.dispose();
    }
  }

  String mergedRecord(String incoming, {bool importPreferences = false}) {
    final copy = ReadingMomentsStore(record: encode());
    try {
      copy._merge(incoming, importPreferences: importPreferences);
      return copy.encode();
    } finally {
      copy.dispose();
    }
  }

  /// Imported achievements are history, not a queue of historical popups.
  Future<void> mergeRecord(
    String incoming, {
    bool persist = true,
    bool importPreferences = false,
  }) async {
    _merge(incoming, importPreferences: importPreferences);
    if (persist) {
      await _save();
    } else {
      _notify();
    }
  }

  void _merge(String incoming, {bool importPreferences = false}) {
    final decoded = _decode(incoming);
    unawaited(_activity.mergeRecord(decoded.activity, persist: false));
    for (final event in decoded.moments.values) {
      final current = _moments[event.id];
      if (current == null) {
        _moments[event.id] = event;
        _presented.add(event.id);
      } else if (current.completion?.finished == false &&
          event.completion?.finished == true) {
        final old = current.completion!, incoming = event.completion!;
        _moments[event.id] = ReadingMoment(
          id: event.id,
          kind: event.kind,
          earnedAt: event.earnedAt,
          value: event.value,
          completion: ReadingCompletionSnapshot(
            bookId: old.bookId,
            title: old.title,
            author: old.author,
            completedAt: incoming.completedAt,
            completedOffsetMinutes: incoming.completedOffsetMinutes,
            firstReachedEndAt: old.firstReachedEndAt ?? old.completedAt,
            firstReachedEndOffsetMinutes:
                old.firstReachedEndOffsetMinutes ?? old.completedOffsetMinutes,
            finished: true,
            coverPath: old.coverPath ?? incoming.coverPath,
            verifiedSeconds: incoming.verifiedSeconds,
            readingDays: incoming.readingDays,
            firstReadAt: incoming.firstReadAt,
            lastReadAt: incoming.lastReadAt,
          ),
        );
        _presented.add(event.id);
      }
    }
    _presented.addAll(decoded.presented);
    if (importPreferences) _preferences = decoded.preferences;
  }

  Future<void> _save() async {
    await _persist?.call();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static ({
    String activity,
    Map<String, ReadingMoment> moments,
    Set<String> presented,
    ReadingMomentsPreferences preferences,
  })
  _decode(String record) {
    final raw = jsonDecode(record);
    if (raw is! Map<String, dynamic> ||
        raw['version'] != 1 ||
        raw['activity'] is! String ||
        raw['moments'] is! List ||
        raw['presented'] is! List) {
      throw const FormatException('阅读纪念记录格式有误');
    }
    final activity = ReadingActivityStore.validateRecord(
      raw['activity'] as String,
    );
    final moments = <String, ReadingMoment>{};
    for (final item in raw['moments'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('阅读纪念格式有误');
      }
      final event = ReadingMoment.fromJson(item);
      if (moments.containsKey(event.id)) {
        throw const FormatException('阅读纪念标识重复');
      }
      moments[event.id] = event;
    }
    final presented = <String>{};
    for (final id in raw['presented'] as List) {
      if (id is! String || !moments.containsKey(id)) {
        throw const FormatException('阅读纪念状态格式有误');
      }
      presented.add(id);
    }
    return (
      activity: activity,
      moments: moments,
      presented: presented,
      preferences: ReadingMomentsPreferences.fromJson(raw['preferences']),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _activity.dispose();
    super.dispose();
  }
}

DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);
DateTime _timestamp(Object? value) {
  if (value is! int || value < 0 || value > 8640000000000000) {
    throw const FormatException('阅读纪念日期格式有误');
  }
  return DateTime.fromMillisecondsSinceEpoch(value);
}

DateTime? _optionalTimestamp(Object? value) =>
    value == null ? null : _timestamp(value);

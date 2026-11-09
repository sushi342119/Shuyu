part of 'local_library.dart';

/// 章节重切后待迁移的阅读进度任务（可恢复、幂等）。
/// 任务先于包含新章节表的 index.json 写入，调用方在
/// [LibraryState.remapChapterProgress] 成功写回进度后，才用
/// [LocalLibraryStore.confirmChapterRemap] 确认删除。
/// 失败时由 [LocalLibraryStore.markChapterRemapFailed] 保留失败信息，
/// 下次扫描仍会返回该任务，不依赖本轮扫描再次发现章节变化。
const _pendingChapterRemapsKey = 'local_library_pending_chapter_remaps_v1';
const _quarantinedChapterRemapsKey =
    'local_library_quarantined_chapter_remaps_v1';

String _chapterRemapMigrationId({
  required int bookId,
  required List<({int offset, int length})> oldChapters,
  required List<({int offset, int length})> newChapters,
}) {
  final source = jsonEncode({
    'bookId': bookId,
    'old': [
      for (final chapter in oldChapters)
        {'offset': chapter.offset, 'length': chapter.length},
    ],
    'new': [
      for (final chapter in newChapters)
        {'offset': chapter.offset, 'length': chapter.length},
    ],
  });
  var hash = 0x811c9dc5;
  for (final codeUnit in source.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return 'chremap-v1-$bookId-${hash.toRadixString(16)}';
}

List<({int offset, int length})> _decodeChapterRanges(Object? value) {
  if (value is! List) {
    throw const FormatException('chapter ranges must be a list');
  }
  final result = <({int offset, int length})>[];
  for (final item in value) {
    if (item is! Map || item.keys.any((key) => key is! String)) {
      throw const FormatException('chapter range must be an object');
    }
    final map = Map<String, dynamic>.from(item);
    final offset = map['offset'];
    final length = map['length'];
    // 损坏的持久化数据不能直接参与进度迁移：小数、负数一律拒绝，
    // 不能用 toInt() 静默截断。
    if (offset is! int || length is! int || offset < 0 || length < 0) {
      throw const FormatException('chapter range offset/length is invalid');
    }
    result.add((offset: offset, length: length));
  }
  return result;
}

class LocalChapterRemap {
  const LocalChapterRemap({
    required this.migrationId,
    required this.bookId,
    required this.oldChapters,
    required this.newChapters,
    this.oldRevision = '',
    this.newRevision = '',
    this.oldTextPath = '',
    this.newTextPath = '',
    this.newTitles = const [],
    this.status = 'pending',
    this.attempts = 0,
    this.lastError,
    this.lastFailedAt,
  });

  factory LocalChapterRemap.create({
    String? migrationId,
    String oldRevision = '',
    String newRevision = '',
    String oldTextPath = '',
    String newTextPath = '',
    List<String> newTitles = const [],
    required int bookId,
    required List<({int offset, int length})> oldChapters,
    required List<({int offset, int length})> newChapters,
  }) {
    return LocalChapterRemap(
      oldRevision: oldRevision,
      newRevision: newRevision,
      oldTextPath: oldTextPath,
      newTextPath: newTextPath,
      newTitles: newTitles,
      migrationId:
          migrationId ??
          '${oldRevision.isEmpty ? '' : '$oldRevision-$newRevision-'}${_chapterRemapMigrationId(bookId: bookId, oldChapters: oldChapters, newChapters: newChapters)}',
      bookId: bookId,
      oldChapters: List.unmodifiable(oldChapters),
      newChapters: List.unmodifiable(newChapters),
    );
  }

  factory LocalChapterRemap.fromJson(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('chapter remap must be an object');
    }
    final map = Map<String, dynamic>.from(value);
    final migrationId = map['migrationId'];
    final rawBookId = map['bookId'];
    final rawStatus = map['status'];
    final rawAttempts = map['attempts'];
    final rawLastError = map['lastError'];
    final rawLastFailedAt = map['lastFailedAt'];
    if (migrationId is! String || migrationId.isEmpty) {
      throw const FormatException('chapter remap migrationId is invalid');
    }
    // 与章节区间一样的严格规则：小数、负数一律拒绝，不能用 toInt() 静默截断。
    if (rawBookId is! int || rawBookId <= 0) {
      throw const FormatException('chapter remap bookId is invalid');
    }
    if (rawStatus != null && rawStatus != 'pending' && rawStatus != 'failed') {
      throw const FormatException('chapter remap status is invalid');
    }
    if (rawAttempts != null && (rawAttempts is! int || rawAttempts < 0)) {
      throw const FormatException('chapter remap attempts is invalid');
    }
    if (rawLastError != null && rawLastError is! String) {
      throw const FormatException('chapter remap lastError is invalid');
    }
    if (rawLastFailedAt != null &&
        (rawLastFailedAt is! int || rawLastFailedAt < 0)) {
      throw const FormatException('chapter remap lastFailedAt is invalid');
    }
    for (final key in [
      'oldRevision',
      'newRevision',
      'oldTextPath',
      'newTextPath',
    ]) {
      if (map[key] != null && map[key] is! String) {
        throw FormatException('chapter remap $key is invalid');
      }
    }
    final titles = map['newTitles'];
    if (titles != null &&
        (titles is! List || titles.any((title) => title is! String))) {
      throw const FormatException('chapter remap newTitles is invalid');
    }
    return LocalChapterRemap(
      migrationId: migrationId,
      bookId: rawBookId,
      oldChapters: List.unmodifiable(_decodeChapterRanges(map['oldChapters'])),
      newChapters: List.unmodifiable(_decodeChapterRanges(map['newChapters'])),
      oldRevision: map['oldRevision'] as String? ?? '',
      newRevision: map['newRevision'] as String? ?? '',
      oldTextPath: map['oldTextPath'] as String? ?? '',
      newTextPath: map['newTextPath'] as String? ?? '',
      newTitles: titles == null ? const [] : List<String>.from(titles as List),
      status: rawStatus as String? ?? 'pending',
      attempts: rawAttempts as int? ?? 0,
      lastError: rawLastError == null ? null : '章节迁移失败',
      lastFailedAt: rawLastFailedAt as int?,
    );
  }

  final String migrationId;
  final int bookId;
  final List<({int offset, int length})> oldChapters;
  final List<({int offset, int length})> newChapters;
  final String oldRevision, newRevision, oldTextPath, newTextPath;
  final List<String> newTitles;
  final String status;
  final int attempts;
  final String? lastError;
  final int? lastFailedAt;

  Map<String, dynamic> toJson() {
    return {
      'migrationId': migrationId,
      'bookId': bookId,
      'oldChapters': [
        for (final chapter in oldChapters)
          {'offset': chapter.offset, 'length': chapter.length},
      ],
      'newChapters': [
        for (final chapter in newChapters)
          {'offset': chapter.offset, 'length': chapter.length},
      ],
      'oldRevision': oldRevision,
      'newRevision': newRevision,
      'oldTextPath': oldTextPath,
      'newTextPath': newTextPath,
      'newTitles': newTitles,
      'status': status,
      'attempts': attempts,
      'lastError': lastError,
      'lastFailedAt': lastFailedAt,
    };
  }

  LocalChapterRemap withFailure(Object error) {
    return LocalChapterRemap(
      migrationId: migrationId,
      bookId: bookId,
      oldChapters: oldChapters,
      newChapters: newChapters,
      oldRevision: oldRevision,
      newRevision: newRevision,
      oldTextPath: oldTextPath,
      newTextPath: newTextPath,
      newTitles: newTitles,
      status: 'failed',
      attempts: attempts + 1,
      lastError: '${error.runtimeType}: 章节迁移失败',
      lastFailedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

extension LocalChapterRemapJournal on LocalLibraryStore {
  List<LocalChapterRemap> _readPendingChapterRemaps() {
    if (_remapsDuringWrite case final pending?) return pending;
    return _decodePendingChapterRemaps(
      _prefs.get(_pendingChapterRemapsKey),
    ).tasks;
  }

  ({List<LocalChapterRemap> tasks, List<int> invalidEntries})
  _decodePendingChapterRemaps(Object? raw) {
    final tasks = <LocalChapterRemap>[];
    final invalidEntries = <int>[];
    if (raw == null) return (tasks: tasks, invalidEntries: invalidEntries);
    try {
      if (raw is! String) throw const FormatException('invalid queue type');
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('invalid queue');
      for (var index = 0; index < decoded.length; index++) {
        try {
          tasks.add(LocalChapterRemap.fromJson(decoded[index]));
        } catch (_) {
          invalidEntries.add(index);
        }
      }
    } catch (_) {
      invalidEntries.add(-1);
    }
    return (tasks: tasks, invalidEntries: invalidEntries);
  }

  Future<void> _recoverChapterRemaps() async {
    if (_remapsDuringWrite != null) return;
    final raw = _prefs.get(_pendingChapterRemapsKey);
    if (raw == null) return;
    final decoded = _decodePendingChapterRemaps(raw);
    final executable = _selectChapterRemaps(
      decoded.tasks,
      stopAtFailure: false,
    ).toSet();
    final abandoned = <LocalChapterRemap>{};
    final abandonmentReasons = <String, String>{};
    final byBook = <int, List<LocalChapterRemap>>{};
    for (final task in decoded.tasks) {
      (byBook[task.bookId] ??= <LocalChapterRemap>[]).add(task);
    }
    for (final chain in byBook.values) {
      for (var index = 1; index < chain.length; index++) {
        if (_remapChainLinks(chain[index - 1], chain[index])) continue;
        for (final task in chain.skip(index)) {
          if (_dirtyBookIds.contains(task.bookId) || executable.contains(task)) {
            continue;
          }
          abandoned.add(task);
          abandonmentReasons[_remapKey(task.bookId, task.migrationId)] =
              'broken_chain';
        }
        break;
      }
    }
    for (final task in decoded.tasks) {
      if (_dirtyBookIds.contains(task.bookId) || abandoned.contains(task)) {
        continue;
      }
      if (!executable.contains(task)) {
        abandoned.add(task);
        abandonmentReasons[_remapKey(task.bookId, task.migrationId)] =
            'unreachable';
      }
    }
    if (decoded.invalidEntries.isEmpty && abandoned.isEmpty) return;
    await archiveRecoveryRecord(
      _prefs,
      _quarantinedChapterRemapsKey,
      raw,
      reason: 'invalid_or_unreachable_remaps',
      details: {
        'invalidEntries': decoded.invalidEntries,
        'abandoned': [
          for (final task in abandoned)
            {
              ...task.toJson(),
              'status': 'abandoned',
              'terminalReason':
                  abandonmentReasons[_remapKey(
                    task.bookId,
                    task.migrationId,
                  )] ??
                  'unreachable',
            },
        ],
      },
    );
    await _writePendingChapterRemaps(
      decoded.tasks.where((task) => !abandoned.contains(task)),
    );
  }

  Future<void> _writePendingChapterRemaps(
    Iterable<LocalChapterRemap> remaps,
  ) async {
    // 不排序：队列必须保留产生顺序，同一本书 A→B、B→C 的迁移
    // 不能因 migrationId 的哈希字典序被打乱，否则调用方按序执行会串章。
    final previous = _readPendingChapterRemaps();
    final next = remaps.toList();
    // SharedPreferences updates its cache before native commit. Keep all tasks
    // visible until the real write completes, especially a timed out confirm.
    _remapsDuringWrite = {
      for (final task in [...previous, ...next])
        _remapKey(task.bookId, task.migrationId): task,
    }.values.toList();
    try {
      await LocalLibraryStore._checkedSet(
        () => next.isEmpty
            ? _prefs.remove(_pendingChapterRemapsKey)
            : _prefs.setString(
                _pendingChapterRemapsKey,
                jsonEncode([for (final remap in next) remap.toJson()]),
              ),
        _pendingChapterRemapsKey,
      );
      _remapsDuringWrite = null;
    } catch (_) {
      _remapsDuringWrite = previous;
      rethrow;
    }
  }

  /// 把任务写成 journal。必须在 _saveIndex() 之前调用（扫描函数内部，
  /// 已在 _synchronized 保护内，不要再套一层锁）。
  Future<void> _stageChapterRemaps(Iterable<LocalChapterRemap> remaps) async {
    final incoming = remaps.toList();
    if (incoming.isEmpty) return;
    final merged = <String, LocalChapterRemap>{
      for (final remap in _readPendingChapterRemaps())
        _remapKey(remap.bookId, remap.migrationId): remap,
    };
    for (final remap in incoming) {
      // 已存在的失败记录要保留 lastError 和 attempts。
      merged.putIfAbsent(
        _remapKey(remap.bookId, remap.migrationId),
        () => remap,
      );
    }
    await _writePendingChapterRemaps(merged.values);
  }

  void _captureSavedRemapRanges([Iterable<int>? changedBookIds]) {
    final ids = changedBookIds?.toSet();
    if (ids == null) {
      _savedRemapRanges = {
        for (final book in _books)
          book.id: [
            for (final c in book.chapters) (offset: c.offset, length: c.length),
          ],
      };
      return;
    }
    for (final id in ids) {
      final book = bookFor(id);
      if (book == null) {
        _savedRemapRanges.remove(id);
      } else if (!identical(_savedBookRefs[id]?.chapters, book.chapters)) {
        _savedRemapRanges[id] = [
          for (final c in book.chapters) (offset: c.offset, length: c.length),
        ];
      }
    }
  }

  bool _sameRemapRanges(
    List<({int offset, int length})> a,
    List<({int offset, int length})> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _remapChainLinks(LocalChapterRemap previous, LocalChapterRemap next) =>
      _sameRemapRanges(previous.newChapters, next.oldChapters) &&
      (previous.newRevision.isEmpty ||
          next.oldRevision.isEmpty ||
          previous.newRevision == next.oldRevision);

  /// 当前待处理任务的公开只读视图，供调用点和页面观察。
  /// 仅返回可以迁移到已持久化章节表的任务；尚未提交索引的任务
  /// 继续保留在原始队列中，不交出去。同一本书的迁移链按产生顺序
  /// 返回（从最终已提交的表反向找链，再正序还原）。
  List<LocalChapterRemap> get pendingChapterRemaps =>
      _selectChapterRemaps(_readPendingChapterRemaps());

  List<LocalChapterRemap> _selectChapterRemaps(
    List<LocalChapterRemap> queued, {
    bool stopAtFailure = true,
  }) {
    // 按小胖补丁：返回终点章节表等于已落盘表的完整连续迁移链，
    // 且按持久化队列原顺序返回，不按书分组重排、不按 migrationId 排序。
    final byBook = <int, List<LocalChapterRemap>>{};
    for (final remap in queued) {
      (byBook[remap.bookId] ??= <LocalChapterRemap>[]).add(remap);
    }
    final selected = <(int, String)>{};
    for (final entry in byBook.entries) {
      final saved = _savedRemapRanges[entry.key];
      if (saved == null) continue;
      final chain = entry.value;
      var end = -1;
      for (var i = 0; i < chain.length; i++) {
        if (_sameRemapRanges(chain[i].newChapters, saved) &&
            (chain[i].newRevision.isEmpty ||
                chain[i].newRevision == _savedBookRefs[entry.key]?.revision)) {
          end = i;
        }
      }
      if (end < 0) continue;
      var start = end;
      while (start > 0 && _remapChainLinks(chain[start - 1], chain[start])) {
        start--;
      }
      for (var i = start; i <= end; i++) {
        selected.add((entry.key, chain[i].migrationId));
        // 失败任务之后的同书任务不再暴露：必须等前置任务确认后
        // 才会再次出现，避免下一轮跳过失败项直接迁移后续。
        if (stopAtFailure && chain[i].status == 'failed') {
          break;
        }
      }
    }
    return List.unmodifiable([
      for (final remap in queued)
        if (selected.contains((remap.bookId, remap.migrationId))) remap,
    ]);
  }

  static String _remapKey(int bookId, String migrationId) =>
      '$bookId\u0000$migrationId';

  /// 一次性提交本轮迁移结果：成功任务删除，失败任务更新错误状态。
  /// 迁移本身仍按书、按队列顺序执行，持久化只读取和写回一次队列。
  Future<void> commitChapterRemapResults({
    required Iterable<({int bookId, String migrationId})> confirmed,
    required Iterable<({LocalChapterRemap remap, Object error})> failures,
  }) {
    return _synchronized(() async {
      final confirmations = confirmed.toList();
      final confirmedKeys = {
        for (final item in confirmations)
          _remapKey(item.bookId, item.migrationId),
      };
      final failedByKey = {
        for (final item in failures)
          _remapKey(item.remap.bookId, item.remap.migrationId): item,
      };
      if (confirmedKeys.isEmpty && failedByKey.isEmpty) return;
      final current = _readPendingChapterRemaps();
      final bookQueues = <int, Queue<String>>{};
      final present = <String>{};
      for (final item in current) {
        final key = _remapKey(item.bookId, item.migrationId);
        (bookQueues[item.bookId] ??= Queue<String>()).add(key);
        present.add(key);
      }
      for (final item in confirmations) {
        final key = _remapKey(item.bookId, item.migrationId);
        if (!present.remove(key)) continue;
        final queue = bookQueues[item.bookId]!;
        if (queue.first != key || failedByKey.containsKey(key)) {
          throw StateError(
            '同一本书必须按迁移任务产生顺序确认：${item.bookId}/${item.migrationId}',
          );
        }
        queue.removeFirst();
      }
      final next = <LocalChapterRemap>[];
      final seenPendingByBook = <int>{};
      final handled = <String>{};
      for (final item in current) {
        final key = _remapKey(item.bookId, item.migrationId);
        final failed = failedByKey[key];
        if (failed != null) {
          next.add(item.withFailure(failed.error));
          seenPendingByBook.add(item.bookId);
          handled.add(key);
        } else if (confirmedKeys.contains(key) &&
            !seenPendingByBook.contains(item.bookId)) {
          handled.add(key);
        } else {
          next.add(item);
          seenPendingByBook.add(item.bookId);
        }
      }
      if (handled.isEmpty && failedByKey.isEmpty) return;
      await _writePendingChapterRemaps(next);
      notifyListeners();
    }, recoverChapterRemaps: false);
  }

  /// state.remapChapterProgress 成功返回后才能调用。
  Future<void> confirmChapterRemap(String migrationId, {required int bookId}) =>
      commitChapterRemapResults(
        confirmed: [(bookId: bookId, migrationId: migrationId)],
        failures: const [],
      );

  /// state 迁移失败后调用。即使任务因某种原因还没有入队，
  /// 这里也会把它重新放回可恢复队列。
  Future<void> markChapterRemapFailed(LocalChapterRemap remap, Object error) =>
      commitChapterRemapResults(
        confirmed: const [],
        failures: [(remap: remap, error: error)],
      );
}

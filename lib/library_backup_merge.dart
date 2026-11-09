part of 'library_state.dart';

extension LibraryBackupMerge on LibraryState {
  Map<String, Object> _backupRecords() {
    final tagStore = TagStore.maybeShared;
    if (tagStore == null) {
      throw const LibraryBackupUnavailable('标签未加载，已拒绝生成备份或恢复前快照；请重启并成功加载标签后重试');
    }
    return {
      'shelf': _shelf.map((id) => '$id').toList(),
      'local_shelf_removed': _prefs.getStringList('local_shelf_removed') ?? <String>[],
      'reading_history_hidden': _hiddenHistory.map((id) => '$id').toList(),
      'recentSearches': _recentSearches,
      ..._appearanceStore.toBackupRecords(),
      ..._readerStore.toBackupRecords(),
      ..._performanceStore.toBackupRecords(),
      for (final entry in _added.entries) 'shelf_added_${entry.key}': entry.value,
      for (final entry in _known.entries)
        'novel_meta_${entry.key}': jsonEncode(entry.value.toSnapshot()),
      for (final entry in _chapters.entries) 'chapter_${entry.key}': entry.value,
      for (final entry in _positions.entries)
        'reading_position_${entry.key}': jsonEncode(entry.value.toJson()),
      for (final entry in _bookmarks.entries)
        'reader_bookmarks_${entry.key}': jsonEncode(
          entry.value.map((mark) => mark.toJson()).toList(),
        ),
      ...tagStore.exportTagRecords(),
    };
  }

  Future<LibraryBackup> createBackup() async {
    _requireShelfLoaded();
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => createBackup());
    }
    late LibraryBackup backup;
    await _queuePositionWrite(() async {
      _requireShelfLoaded();
      backup = await LibraryBackup.fromLocalRecords(_backupRecords());
      _recordOmittedCovers(backup);
    });
    return backup;
  }

  String? get preRestoreBackup => _prefs.getString('library_pre_restore_snapshot_v1');

  /// Merge, do not replace: current newer positions and metadata win. Memory is
  /// published only after all keys commit, with a rollback journal across kills.
  Future<void> restoreBackup(
    LibraryBackup backup, {
    bool importPreferences = false,
  }) async {
    _requireShelfLoaded();
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => restoreBackup(backup, importPreferences: importPreferences),
      );
    }
    final barrier = Completer<void>();
    _restoreBarrier = barrier;
    try {
      await _queuePositionWrite(() async {
        _requireShelfLoaded();
        final previous = await LibraryBackup.fromLocalRecords(_backupRecords());
        _recordOmittedCovers(previous);
        await writeLibraryPreference(_prefs, 'library_pre_restore_snapshot_v1', await previous.encode());
        final records = backup.records;
        final shelf = {
          ..._shelf,
          ...(records['shelf'] as List<String>? ?? const []).map(int.parse),
        };
        final added = {..._added};
        final known = {..._known};
        final chapters = {..._chapters};
        final positions = {..._positions};
        final marks = <int, List<ReaderBookmark>>{
          for (final entry in _bookmarks.entries) entry.key: [...entry.value],
        };
        final hidden = {..._hiddenHistory};
        final changed = <String, Object>{};
        final oldRead = {..._chapters.keys, ..._positions.keys};
        for (final entry in records.entries) {
          final key = entry.key;
          if (key.startsWith('novel_meta_')) {
            final id = int.parse(key.substring('novel_meta_'.length));
            if (!known.containsKey(id)) {
              known[id] = Novel.fromSnapshot(jsonDecode(entry.value as String));
              changed[key] = entry.value;
            }
          } else if (key.startsWith('shelf_added_')) {
            final id = int.parse(key.substring('shelf_added_'.length));
            if (!added.containsKey(id)) {
              added[id] = entry.value as int;
              changed[key] = entry.value;
            }
          } else if (key.startsWith('chapter_')) {
            final id = int.parse(key.substring('chapter_'.length));
            if (!chapters.containsKey(id) && !positions.containsKey(id)) {
              chapters[id] = entry.value as int;
              changed[key] = entry.value;
            }
          } else if (key.startsWith('reading_position_')) {
            final id = int.parse(key.substring('reading_position_'.length));
            final incoming = ReadingPosition.fromJson(
              jsonDecode(entry.value as String),
            );
            if (positions[id] == null ||
                positions[id]!.updatedAt < incoming.updatedAt) {
              positions[id] = incoming;
              chapters[id] = incoming.chapter;
              changed[key] = jsonEncode(incoming.toJson());
              changed['chapter_$id'] = incoming.chapter;
            }
          } else if (key.startsWith('reader_bookmarks_')) {
            final id = int.parse(key.substring('reader_bookmarks_'.length));
            final current = marks.putIfAbsent(id, () => []);
            final fingerprints = current.map(_bookmarkFingerprint).toSet();
            final ids = current.map((mark) => mark.id).toSet();
            for (final raw in jsonDecode(entry.value as String) as List) {
              var mark = ReaderBookmark.fromJson(
                Map<String, dynamic>.from(raw),
              );
              if (!fingerprints.add(_bookmarkFingerprint(mark))) continue;
              var candidate = mark.id;
              for (var suffix = 1; ids.contains(candidate); suffix++) {
                candidate = 'import-${mark.position.updatedAt}-$suffix';
              }
              ids.add(candidate);
              if (candidate != mark.id) {
                mark = ReaderBookmark(
                  id: candidate,
                  chapterTitle: mark.chapterTitle,
                  position: mark.position,
                );
              }
              current.add(mark);
            }
            if (current.length > 1000) {
              throw const FormatException('合并后单本书超过 1000 个书签，请先整理书签');
            }
            current.sort(
              (a, b) => b.position.updatedAt.compareTo(a.position.updatedAt),
            );
            changed[key] = jsonEncode(
              current.map((mark) => mark.toJson()).toList(),
            );
          }
        }
        for (final id in shelf) {
          added.putIfAbsent(id, () => backup.createdAt);
          if (!_added.containsKey(id)) changed['shelf_added_$id'] = added[id]!;
        }
        for (final id
            in (records['reading_history_hidden'] as List<String>? ?? const [])
                .map(int.parse)) {
          if (!oldRead.contains(id) &&
              (positions.containsKey(id) || chapters.containsKey(id))) {
            hidden.add(id);
          }
        }
        final seen = <String>{};
        final searches = <String>[
          ..._recentSearches,
          ...(records['recentSearches'] as List<String>? ?? const []),
        ].map((term) => term.trim())
            .where(validSearchHistory)
            .where((term) => seen.add(term.toLowerCase()))
            .take(12)
            .toList();
        changed['shelf'] = shelf.map((id) => '$id').toList();
        changed['local_shelf_removed'] = {
          ...?_prefs.getStringList('local_shelf_removed'),
          ...(records['local_shelf_removed'] as List<String>? ?? const []),
        }.where((id) => !shelf.contains(int.tryParse(id))).toList();
        changed['reading_history_hidden'] = hidden.map((id) => '$id').toList();
        changed['recentSearches'] = searches;
        if (importPreferences) {
          for (final key in backupPreferenceKeys) {
            if (records[key] case final value?) changed[key] = value;
          }
          // A backup may predate the migration marker. Normalize within the
          // same journaled commit so a restart cannot revive hidden overrides.
          for (final entry in _retiredAppearanceDefaults.entries) {
            if (records.containsKey(entry.key) ||
                _prefs.containsKey(entry.key)) {
              changed[entry.key] = entry.value;
            }
          }
        }
        await _commitLibraryRecords(changed);
        // 标签是独立存储，合并语义与书架一致（只增不减）。
        final tagRecords = <String, Object>{};
        for (final key in const ['tag_defs', 'tag_map']) {
          if (records[key] case final String value) tagRecords[key] = value;
        }
        if (tagRecords.isNotEmpty) {
          await TagStore.shared.importTagRecords(tagRecords);
        }
        final oldShelf = {..._shelf};
        _shelf
          ..clear()
          ..addAll(shelf);
        for (final id in {...oldShelf, ...shelf}) {
          if (oldShelf.contains(id) != shelf.contains(id)) {
            _shelfRevisions[id] = shelfRevision(id) + 1;
          }
        }
        _added
          ..clear()
          ..addAll(added);
        _known
          ..clear()
          ..addAll(known);
        _persistedNovels
          ..clear()
          ..addAll(known);
        _chapters
          ..clear()
          ..addAll(chapters);
        _positions
          ..clear()
          ..addAll(positions);
        _bookmarks
          ..clear()
          ..addAll(marks);
        _underlineRanges.clear();
        _underlinesByChapter.clear();
        _annotationRanges.clear();
        _annotationsByChapter.clear();
        for (final id in _bookmarks.keys) {
          _updateUnderlineIndex(id, notify: false);
        }
        _hiddenHistory
          ..clear()
          ..addAll(hidden);
        _recentSearches = searches;
        if (importPreferences) {
          _appearanceStore.applyBackupRecords(records);
          _readerStore.applyBackupRecords(records);
          _performanceStore.applyBackupRecords(records);
        }
        if (!_disposed) {
          _historyChanged();
          _bookmarkChanges.notifyListeners();
          _underlineChanges.notifyListeners();
          _searchChanges.notifyListeners();
          _shelfViewChanges.notifyListeners();
          if (importPreferences) {
            _application.notifyListeners();
            _appearance.notifyListeners();
            _glassChanges.notifyListeners();
            _readerSettings.notifyListeners();
            _readerBehaviorChanges.notifyListeners();
            _settings.notifyListeners();
          }
          notifyListeners();
        }
      });
    } finally {
      _restoreBarrier = null;
      barrier.complete();
    }
  }

  static String _bookmarkFingerprint(ReaderBookmark bookmark) {
    final position = {...bookmark.position.toJson()}..remove('updatedAt');
    return jsonEncode(position);
  }

  void _recordOmittedCovers(LibraryBackup backup) {
    if (backup.omittedCoverKeys.isNotEmpty) {
      debugPrint('本地备份省略了不支持的封面：${backup.omittedCoverKeys.join(', ')}');
    }
  }
}

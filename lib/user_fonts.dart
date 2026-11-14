import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_typography.dart';
import 'font_download.dart';

const followAppFont = 'followApp';
bool validFontChoice(Object? value, {bool follow = false}) =>
    value is String &&
    (AppTypeface.values.any((font) => font.name == value) ||
        (follow && value == followAppFont) ||
        RegExp(r'^font_[a-z0-9-]{1,64}$').hasMatch(value));

class UserFont {
  const UserFont(
    this.id,
    this.name,
    this.extension, {
    this.filePath,
    this.customFamily,
  });
  final String id, name, extension;
  final String? filePath;
  final String? customFamily;
  String get family => customFamily ?? 'WenkuUser_$id';

  AppFontEntry toAppFontEntry() => AppFontEntry(
    id: id,
    displayName: name,
    family: family,
    source: AppFontSource.imported,
    filePath: filePath,
  );

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'extension': extension,
    'filePath': ?filePath,
    'family': ?customFamily,
  };
}

/// Files stay in private storage. The engine loads a face once, on selection,
/// not on every rebuild or for every entry in the font catalogue.
class UserFontStore extends ChangeNotifier {
  UserFontStore({
    Directory? directory,
    this.loader,
    FontDownloadClient? downloads,
  }) : _directory = directory,
       _downloads = downloads ?? FontDownloadClient();
  static const maxBytes = 32 * 1024 * 1024;
  final Future<void> Function(String family, File file)? loader;
  Directory? _directory;
  SharedPreferences? _prefs;
  bool _pendingLegacyMigrationSave = false;
  final _fonts = <UserFont>[];
  final Map<String, Future<void>> _loads = {};
  final _loadedFaces = <String>{};
  bool isLoaded(String id) =>
      id == AppTypeface.system.name ||
      id == AppTypeface.sourceHanSerif.name ||
      _loadedFaces.contains(id);
  final FontDownloadClient _downloads;
  final _availableDownloads = <String>{};
  Future<void>? _download;
  String? downloadingFontId;
  FontDownloadCancellation? _cancellation;
  final downloadChanges = ValueNotifier<FontDownloadProgress?>(null);
  final _downloadErrors = <String, String>{};
  String? downloadError(String id) => _downloadErrors[id];
  bool get downloading => _download != null;
  bool _loaded = false;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  List<UserFont> get fonts => List.unmodifiable(_fonts);
  UserFont? find(String id) =>
      _fonts.where((font) => font.id == id).firstOrNull;
  bool available(String id) =>
      id == AppTypeface.system.name ||
      id == AppTypeface.sourceHanSerif.name ||
      _availableDownloads.contains(id) ||
      find(id) != null;
  String label(String id) => id == followAppFont
      ? '跟随 App'
      : find(id)?.name ?? AppTypeface.fromRecord(id).label;
  String? family(String id) => available(id)
      ? find(id)?.family ?? AppTypeface.fromRecord(id).family
      : null;

  /// One-time synchronous migration of legacy `importedFonts` entries stored in
  /// [SharedPreferences] so callers see migrated entries immediately.
  void migrateLegacyPreferences(SharedPreferences prefs) {
    _prefs = prefs;
    final rawList = prefs.getString('importedFonts');
    if (rawList == null || rawList.isEmpty) return;
    try {
      final list = jsonDecode(rawList);
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, Object?>) {
            try {
              final entry = AppFontEntry.fromJson(item);
              if (entry.id.isNotEmpty &&
                  entry.source == AppFontSource.imported &&
                  entry.family != null &&
                  find(entry.id) == null) {
                final ext = (entry.filePath ?? '')
                    .split('.')
                    .last
                    .toLowerCase();
                _fonts.add(
                  UserFont(
                    entry.id,
                    entry.displayName,
                    ext == 'otf' ? 'otf' : 'ttf',
                    filePath: entry.filePath,
                    customFamily: entry.family,
                  ),
                );
                _pendingLegacyMigrationSave = true;
              }
            } on FormatException catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<Directory> _root() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/user-fonts',
  );
  File _file(Directory root, UserFont font) => font.filePath != null
      ? File(font.filePath!)
      : File('${root.path}/${font.id}.${font.extension}');

  Future<bool> isPrivateFontFile(File file) async {
    try {
      final actual = await file.resolveSymbolicLinks();
      final separator = Platform.pathSeparator;
      final candidateDirs = <Directory>[
        await _root(),
        Directory(
          '${(await getApplicationSupportDirectory()).path}${separator}fonts',
        ),
      ];
      for (final dir in candidateDirs) {
        if (!await dir.exists()) continue;
        final root = await dir.resolveSymbolicLinks();
        if (actual != root && actual.startsWith('$root$separator')) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void>? _loading;
  Future<void>? _saving;
  int _saveSeq = 0;

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _loadImpl().whenComplete(() => _loading = null);
  }

  Future<void> _loadImpl() async {
    if (_loaded) return;
    final root = await _root();
    for (final font in downloadableFonts) {
      final downloaded = File('${root.path}/${font.fileName}');
      if (await downloaded.exists() &&
          await downloaded.length() == font.bytes) {
        _availableDownloads.add(font.id);
      }
    }
    final index = File('${root.path}/fonts.json');
    if (await index.exists()) {
      if (await index.length() > 128 * 1024) {
        throw const FormatException('字体记录过大');
      }
      final raw = jsonDecode(await index.readAsString());
      if (raw is! List || raw.length > 20) {
        throw const FormatException('字体记录格式有误');
      }
      for (final value in raw) {
        if (value is! Map ||
            value['id'] is! String ||
            (value['id'] as String).isEmpty ||
            (value['filePath'] == null &&
                (!validFontChoice(value['id']) ||
                    !(value['id'] as String).startsWith('font_'))) ||
            value['name'] is! String ||
            value['name'].length > 160 ||
            !['ttf', 'otf'].contains(value['extension'])) {
          throw const FormatException('字体记录格式有误');
        }
        final font = UserFont(
          value['id'] as String,
          value['name'] as String,
          value['extension'] as String,
          filePath: value['filePath'] as String?,
          customFamily: value['family'] as String?,
        );
        if (await _file(root, font).exists() && find(font.id) == null) {
          _fonts.add(font);
        }
      }
    }
    _loaded = true;
    if (_pendingLegacyMigrationSave) {
      _pendingLegacyMigrationSave = false;
      try {
        await _save();
      } catch (_) {}
    }
  }

  Future<void> ensureLoaded(String id) async {
    final font = find(id);
    if (!available(id) ||
        id == AppTypeface.system.name ||
        (id == AppTypeface.sourceHanSerif.name &&
            !_availableDownloads.contains(id))) {
      return;
    }
    final loading = _loads.putIfAbsent(id, () async {
      final root = await _root();
      final file = font == null
          ? File('${root.path}/${downloadableFont(id)!.fileName}')
          : _file(root, font);
      if (font?.filePath != null) {
        if (!await isPrivateFontFile(file)) {
          throw const FormatException('字体文件不在应用字体目录内');
        }
        _validateSfnt(file.path);
      }
      final family = font?.family ?? AppTypeface.fromRecord(id).family!;
      if (loader != null) return loader!(family, file);
      final face = FontLoader(family)
        ..addFont(file.readAsBytes().then(ByteData.sublistView));
      await face.load();
    });
    try {
      await loading;
      _loadedFaces.add(id);
    } catch (_) {
      _loads.remove(id);
      _loadedFaces.remove(id);
      rethrow;
    }
  }

  Future<void> preloadImportedFonts() async {
    final snapshot = List.of(_fonts);
    for (final font in snapshot) {
      try {
        await ensureLoaded(font.id);
      } catch (_) {}
    }
  }

  Future<void> downloadFont(String id) async {
    await load();
    final spec = downloadableFont(id);
    if (spec == null) throw const FormatException('这款字体不在下载目录中');
    if (_availableDownloads.contains(id)) return;
    if (_download case final current?) {
      if (downloadingFontId == id) return current;
      throw const FormatException('请先完成或取消当前字体下载');
    }
    final cancellation = FontDownloadCancellation();
    _cancellation = cancellation;
    downloadingFontId = id;
    _downloadErrors.remove(id);
    final operation = () async {
      final root = await _root();
      await root.create(recursive: true);
      final part = File('${root.path}/${spec.fileName}.part');
      final transfer = spec.archiveEntry == null
          ? part
          : File('${part.path}.zip');
      try {
        await _downloads.download(
          transfer,
          cancellation: cancellation,
          expectedBytes: spec.transferBytes,
          from: spec.sourceUrls.map(Uri.parse).toList(),
          onProgress: (value) {
            if (!_disposed) downloadChanges.value = value;
          },
        );
        if (!_disposed) {
          downloadChanges.value = FontDownloadProgress(
            spec.transferBytes,
            spec.transferBytes,
            validating: true,
          );
        }
        await compute(_prepareDownloadedFont, (
          transfer.path,
          part.path,
          spec.archiveEntry,
          spec.bytes,
        ));
        cancellation.check();
        await part.rename('${root.path}/${spec.fileName}');
        _availableDownloads.add(id);
      } finally {
        if (await part.exists()) await part.delete();
        if (transfer.path != part.path && await transfer.exists()) {
          await transfer.delete();
        }
      }
    }();
    _download = operation;
    _changed();
    try {
      await operation;
    } on FontDownloadCancelled {
      rethrow;
    } catch (_) {
      _downloadErrors[id] = '下载未完成，点击重试';
      rethrow;
    } finally {
      _download = null;
      downloadingFontId = null;
      _cancellation = null;
      if (!_disposed) downloadChanges.value = null;
      _changed();
    }
  }

  void cancelDownload() => _cancellation?.cancel();

  Future<void> _save() {
    Future<void> write() async {
      final root = await _root();
      await root.create(recursive: true);
      final temp = File('${root.path}/fonts.json.${++_saveSeq}.part');
      try {
        await temp.writeAsString(
          jsonEncode(_fonts.map((font) => font.toJson()).toList()),
          flush: true,
        );
        await temp.rename('${root.path}/fonts.json');
      } finally {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
      try {
        await _prefs?.remove('importedFonts');
      } catch (_) {}
    }

    final previous = _saving;
    final next = previous == null ? write() : previous.then((_) => write());
    final barrier = next.then<void>((_) {}, onError: (Object _) {});
    _saving = barrier;
    return next.whenComplete(() {
      if (identical(_saving, barrier)) _saving = null;
    });
  }

  Future<UserFont> importFile(String name, String path) async {
    await load();
    if (_fonts.length >= 20) {
      throw const FormatException('最多保留 20 款导入字体，请先移除不用的字体');
    }
    final extension = name.split('.').last.toLowerCase();
    if (!['ttf', 'otf'].contains(extension)) {
      throw const FormatException('请选择 TTF 或 OTF 字体');
    }
    final source = File(path);
    final size = await source.length();
    if (size <= 0 || size > maxBytes) {
      throw const FormatException('字体文件需要在 32 MiB 以内');
    }
    // Validate SFNT tables before handing an untrusted file to the engine.
    await compute(_validateSfnt, path);
    final id =
        'font_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x100000000).toRadixString(36)}';
    final clean = name
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '')
        .trim();
    final font = UserFont(
      id,
      String.fromCharCodes((clean.isEmpty ? '导入字体' : clean).runes.take(80)),
      extension,
    );
    final root = await _root();
    await root.create(recursive: true);
    final destination = _file(root, font);
    try {
      await source.copy(destination.path);
      _fonts.add(font);
      await ensureLoaded(id);
      await _save();
    } catch (_) {
      _fonts.remove(font);
      _loads.remove(id);
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
    _changed();
    return font;
  }

  /// Registers a font file already placed in private app font storage.
  Future<String> registerImportedFont(
    String filePath,
    String displayName,
  ) async {
    final file = File(filePath);
    if (!await isPrivateFontFile(file)) {
      throw StateError('字体文件不在应用字体目录内');
    }
    await load();
    if (_fonts.length >= 20) {
      throw const FormatException('最多保留 20 款导入字体，请先移除不用的字体');
    }
    final ext = filePath.split('.').last.toLowerCase();
    final id =
        'font_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x100000000).toRadixString(36)}';
    final font = UserFont(
      id,
      displayName.isEmpty ? '导入字体' : displayName,
      ext == 'otf' ? 'otf' : 'ttf',
      filePath: filePath,
      customFamily: 'user_font_$id',
    );
    _fonts.add(font);
    try {
      final size = await file.length();
      if (size <= 0 || size > maxBytes) {
        throw const FormatException('字体文件大小无效');
      }
      _validateSfnt(filePath);
      await ensureLoaded(id);
      await _save();
    } catch (_) {
      _fonts.remove(font);
      _loads.remove(id);
      _loadedFaces.remove(id);
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      throw StateError('字体文件无效或已损坏');
    }
    _changed();
    return id;
  }

  Future<void> remove(String id) async {
    if (downloadableFont(id) case final spec?) {
      if (downloadingFontId == id) {
        throw const FormatException('请先取消这款字体的下载');
      }
      final file = File('${(await _root()).path}/${spec.fileName}');
      if (await file.exists()) await file.delete();
      _availableDownloads.remove(id);
      _loads.remove(id);
      _loadedFaces.remove(id);
      _changed();
      return;
    }
    final font = find(id);
    if (font == null) return;
    final index = _fonts.indexOf(font);
    _fonts.removeAt(index);
    try {
      await _save();
    } catch (_) {
      _fonts.insert(index, font);
      rethrow;
    }
    try {
      if (font.filePath case final customPath?) {
        final customFile = File(customPath);
        if (await isPrivateFontFile(customFile) && await customFile.exists()) {
          await customFile.delete();
        }
      } else {
        final file = _file(await _root(), font);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
    _loads.remove(id);
    _loadedFaces.remove(id);
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    cancelDownload();
    downloadChanges.dispose();
    super.dispose();
  }
}

void _prepareDownloadedFont((String, String, String?, int) input) {
  final (source, target, entry, expectedBytes) = input;
  if (entry != null) {
    final archive = ZipDecoder().decodeBytes(File(source).readAsBytesSync());
    final font = archive.findFile(entry);
    if (font == null || !font.isFile || font.size != expectedBytes) {
      throw const FormatException('字体压缩包内容不完整，请重试');
    }
    // Extract exactly the catalogue entry into a fixed private path. Never
    // unpack archive paths or run font conversion on the UI isolate.
    File(target).writeAsBytesSync(font.content, flush: true);
  }
  if (File(target).lengthSync() != expectedBytes) {
    throw const FormatException('字体文件不完整，请重试');
  }
  _validateSfnt(target);
}

void _validateSfnt(String path) {
  final file = File(path).openSync();
  try {
    final size = file.lengthSync();
    final bytes = file.readSync(12);
    if (bytes.length < 12) throw const FormatException('字体文件不完整');
    final header = ByteData.sublistView(bytes);
    final magic = header.getUint32(0);
    final count = header.getUint16(4);
    if (![0x00010000, 0x4f54544f, 0x74727565].contains(magic) ||
        count < 1 ||
        count > 4096 ||
        12 + count * 16 > size) {
      throw const FormatException('不是有效的 TTF / OTF 字体，不支持字体合集');
    }
    final tables = ByteData.sublistView(file.readSync(count * 16));
    final tags = <int>{};
    for (var i = 0; i < count; i++) {
      final offset = tables.getUint32(i * 16 + 8),
          length = tables.getUint32(i * 16 + 12);
      if (offset < 12 + count * 16 || offset + length > size) {
        throw const FormatException('字体文件损坏，字形数据不完整');
      }
      tags.add(tables.getUint32(i * 16));
    }
    if (!tags.containsAll([0x68656164, 0x636d6170, 0x6d617870]) ||
        !tags.any([0x676c7966, 0x43464620, 0x43464632].contains)) {
      throw const FormatException('字体缺少必要的字形表');
    }
  } finally {
    file.closeSync();
  }
}

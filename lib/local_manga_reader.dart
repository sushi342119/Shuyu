import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_epub_reader.dart';
import 'local_library.dart';
import 'local_pdf_reader.dart';
import 'local_platform.dart';
import 'reader_paging.dart';
import 'reader_preferences.dart';
import 'reader_skeleton.dart';
import 'reading_activity.dart';

/// 漫画单屏展示单元：单页 `[page]` 或双页跨页 `[firstPage, secondPage]`。
@immutable
class MangaSpread {
  const MangaSpread(this.pages);

  final List<int> pages;

  int get firstPage => pages.first;
  int get lastPage => pages.last;
  bool get isDouble => pages.length == 2;

  bool contains(int page) => pages.contains(page);

  @override
  bool operator ==(Object other) =>
      other is MangaSpread && listEquals(other.pages, pages);

  @override
  int get hashCode => Object.hashAll(pages);

  @override
  String toString() => 'MangaSpread($pages)';
}

/// 漫画章节目录项（用于多话归档、多话文件夹或漫画 EPUB 目录）。
@immutable
class MangaChapterEntry {
  const MangaChapterEntry({
    required this.title,
    required this.startPage,
    required this.pageCount,
  });

  final String title;
  final int startPage;
  final int pageCount;
}

bool _isWideComicPage(Size? size) =>
    size != null && size.height > 0 && size.width > size.height * 1.05;

/// 根据总页数、双页开关、首页单页偏移、已知页面尺寸与章节起始页构建跨页序列。
///
/// 规则：
/// 1. `spreadEnabled == false` 时每页独立成屏；
/// 2. `coverOffset == true` 时第 0 页（封面）独立成屏，后续内页按对拼合；
/// 3. 宽幅跨页原图（`width > height * 1.05`）自动独占一屏，且不会与前一页强行拼合；
/// 4. 新章节起始页（`chapterStartPages`）不会与上一章末尾页拼合。
@visibleForTesting
List<MangaSpread> buildMangaSpreads({
  required int pageCount,
  required bool spreadEnabled,
  required bool coverOffset,
  required Map<int, Size> knownPageSizes,
  Set<int> chapterStartPages = const {},
}) {
  if (pageCount <= 0) return const [];
  if (!spreadEnabled) {
    return List<MangaSpread>.unmodifiable([
      for (var i = 0; i < pageCount; i++) MangaSpread([i]),
    ]);
  }
  final spreads = <MangaSpread>[];
  var i = 0;
  while (i < pageCount) {
    if (i == 0 && coverOffset) {
      spreads.add(const MangaSpread([0]));
      i += 1;
      continue;
    }
    if (_isWideComicPage(knownPageSizes[i])) {
      spreads.add(MangaSpread([i]));
      i += 1;
      continue;
    }
    if (i + 1 >= pageCount ||
        chapterStartPages.contains(i + 1) ||
        _isWideComicPage(knownPageSizes[i + 1])) {
      spreads.add(MangaSpread([i]));
      i += 1;
      continue;
    }
    spreads.add(MangaSpread([i, i + 1]));
    i += 2;
  }
  return List<MangaSpread>.unmodifiable(spreads);
}

int _spreadIndexForPage(List<MangaSpread> spreads, int page) {
  if (spreads.isEmpty) return 0;
  for (var i = 0; i < spreads.length; i++) {
    if (spreads[i].contains(page)) return i;
  }
  return page <= spreads.first.firstPage ? 0 : spreads.length - 1;
}

/// 扫描 RGBA 像素四边纯白或纯黑留白，返回归一化 `[0..1]` 内容区域。
///
/// 为防止误裁切正文分镜或对话气泡：
/// - 仅当外边框采样像素 >= 78% 一致为浅白（亮度 >= 236）或深黑（亮度 <= 20）时启用；
/// - 每侧最大裁切比例限制为 18%，并保留约 0.6% 呼吸留白。
@visibleForTesting
Rect detectMangaContentRect(Uint8List rgbaPixels, int width, int height) {
  const full = Rect.fromLTWH(0, 0, 1, 1);
  if (width < 16 || height < 16 || rgbaPixels.length < width * height * 4) {
    return full;
  }

  int lumaAt(int x, int y) {
    final idx = (y * width + x) * 4;
    final r = rgbaPixels[idx];
    final g = rgbaPixels[idx + 1];
    final b = rgbaPixels[idx + 2];
    return (r * 299 + g * 587 + b * 114) ~/ 1000;
  }

  int alphaAt(int x, int y) => rgbaPixels[(y * width + x) * 4 + 3];

  final stepX = math.max(1, width ~/ 64);
  final stepY = math.max(1, height ~/ 64);
  var sampleTotal = 0;
  var lightCount = 0;
  var darkCount = 0;

  void sampleBorderPixel(int x, int y) {
    if (alphaAt(x, y) < 16) return;
    sampleTotal += 1;
    final luma = lumaAt(x, y);
    if (luma >= 236) {
      lightCount += 1;
    } else if (luma <= 20) {
      darkCount += 1;
    }
  }

  for (var x = 0; x < width; x += stepX) {
    sampleBorderPixel(x, 0);
    sampleBorderPixel(x, height - 1);
  }
  for (var y = 0; y < height; y += stepY) {
    sampleBorderPixel(0, y);
    sampleBorderPixel(width - 1, y);
  }
  if (sampleTotal == 0) return full;

  final bool isLightMargin;
  if (lightCount / sampleTotal >= 0.78) {
    isLightMargin = true;
  } else if (darkCount / sampleTotal >= 0.78) {
    isLightMargin = false;
  } else {
    return full;
  }

  bool isInkPixel(int x, int y) {
    if (alphaAt(x, y) < 16) return false;
    final luma = lumaAt(x, y);
    return isLightMargin ? luma < 228 : luma > 28;
  }

  final maxCropX = (width * 0.18).floor();
  final maxCropY = (height * 0.18).floor();
  final scanStepX = math.max(1, width ~/ 120);
  final scanStepY = math.max(1, height ~/ 120);

  bool rowIsMargin(int y) {
    var samples = 0;
    var ink = 0;
    for (var x = 0; x < width; x += scanStepX) {
      samples += 1;
      if (isInkPixel(x, y)) ink += 1;
    }
    return samples == 0 || (ink / samples) <= 0.02;
  }

  bool colIsMargin(int x) {
    var samples = 0;
    var ink = 0;
    for (var y = 0; y < height; y += scanStepY) {
      samples += 1;
      if (isInkPixel(x, y)) ink += 1;
    }
    return samples == 0 || (ink / samples) <= 0.02;
  }

  var top = 0;
  while (top < maxCropY && rowIsMargin(top)) {
    top += 1;
  }
  var bottom = height;
  while (height - bottom < maxCropY && bottom > top + 8 && rowIsMargin(bottom - 1)) {
    bottom -= 1;
  }
  var left = 0;
  while (left < maxCropX && colIsMargin(left)) {
    left += 1;
  }
  var right = width;
  while (width - right < maxCropX && right > left + 8 && colIsMargin(right - 1)) {
    right -= 1;
  }

  final padX = math.max(1, (width * 0.006).round());
  final padY = math.max(1, (height * 0.006).round());
  left = math.max(0, left - padX);
  top = math.max(0, top - padY);
  right = math.min(width, right + padX);
  bottom = math.min(height, bottom + padY);

  final normLeft = left / width;
  final normTop = top / height;
  final normRight = right / width;
  final normBottom = bottom / height;
  if (normLeft < 0.012 &&
      normTop < 0.012 &&
      (1.0 - normRight) < 0.012 &&
      (1.0 - normBottom) < 0.012) {
    return full;
  }
  if (normRight - normLeft < 0.5 || normBottom - normTop < 0.5) {
    return full;
  }
  return Rect.fromLTRB(normLeft, normTop, normRight, normBottom);
}

@visibleForTesting
Future<Rect> computeNormalizedCropRect(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return const Rect.fromLTWH(0, 0, 1, 1);
  return detectMangaContentRect(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    image.width,
    image.height,
  );
}

class _MangaPageData {
  _MangaPageData({
    required this.bytes,
    required this.intrinsicSize,
    this.cropRect,
  });

  final Uint8List bytes;
  final Size intrinsicSize;
  Rect? cropRect;
}

/// 本地漫画阅读器：支持 CBZ/ZIP 漫画归档、图片文件夹漫画、漫画 EPUB 与漫画模式 PDF。
class LocalMangaReaderPage extends StatefulWidget {
  const LocalMangaReaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.local,
    this.initialPage,
    this.initialChapter,
  });

  final Novel novel;
  final LibraryState state;
  final LocalLibraryStore local;

  /// 指定从 0 基页码打开（如从页码书签或 PDF 切换进入）。
  final int? initialPage;

  /// 指定从 `novel.chapters` 对应的 0 基章节打开（如从详情页点击章节）。
  final int? initialChapter;

  @override
  State<LocalMangaReaderPage> createState() => _LocalMangaReaderPageState();
}

class _LocalMangaReaderPageState extends State<LocalMangaReaderPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _maxCachedPages = 20;
  static const _darkCanvasColor = Color(0xFF101114);
  static const _invertFilter = ColorFilter.matrix(<double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0, //
  ]);

  late final AnimationController _chrome;
  bool _chromeTarget = true;
  late final ReadingActivitySession _readingActivity;
  bool _activityAttached = true;
  bool _activityForeground = true;
  bool _activityRouteCurrent = true;
  bool _addingBookmark = false;
  String? _openedPdfFileUri;

  bool _loadingDescriptor = true;
  Object? _descriptorError;
  int _pageCount = 0;
  List<MangaChapterEntry> _chapters = const [];
  Set<int> _chapterStartPages = const {};

  /// 仅用于图片文件夹漫画：页面 URI 清单。
  ComicFolderManifest? _folderManifest;

  /// 仅用于 `LocalBookKind.epub`：图片条目路径与对应的 spine 章节下标。
  List<String> _epubPages = const [];
  List<int> _epubPageToSpine = const [];

  int _page = 0;
  PageController? _pageController;
  final ScrollController _webtoonController = ScrollController();
  bool _jumpingProgrammatically = false;
  bool _dirtyPosition = false;
  Timer? _scrollSaveTimer;
  double _viewportWidth = 0;
  double _viewportHeight = 0;

  final LinkedHashMap<int, _MangaPageData> _pageCache =
      LinkedHashMap<int, _MangaPageData>();
  final Map<int, Future<_MangaPageData>> _pendingPages = {};
  final Map<int, Size> _knownSizes = {};
  final Map<int, GlobalKey> _webtoonItemKeys = {};

  List<MangaSpread> _currentSpreads = const [];
  bool _lastSpreadEnabled = false;
  bool _lastCoverOffset = true;

  LocalBook? get _book => widget.local.bookFor(widget.novel.id);

  void _syncReadingActivity() {
    _readingActivity.setActive(
      _activityAttached &&
          _activityForeground &&
          _activityRouteCurrent &&
          !_loadingDescriptor &&
          _pageCount > 0,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final initialBook = _book;
    if (initialBook != null && initialBook.kind == LocalBookKind.pdf) {
      _openedPdfFileUri = acquireActivePdfReader(initialBook.fileUri);
    }
    _readingActivity = ReadingActivitySession(
      store: widget.state.readingActivity,
      bookId: widget.novel.id,
    );
    _chrome = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 140),
      value: 1,
    );
    _webtoonController.addListener(_onWebtoonScroll);
    unawaited(_initBookSource());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (_activityRouteCurrent != routeCurrent) {
      _activityRouteCurrent = routeCurrent;
      _syncReadingActivity();
    }
  }

  Future<void> _initBookSource() async {
    setState(() {
      _loadingDescriptor = true;
      _descriptorError = null;
    });
    try {
      await widget.local.ensureReady(widget.novel.id);
      final book = _book;
      if (book == null) {
        throw StateError('本地漫画不存在或已被移除');
      }
      int resolvedCount = 0;
      var resolvedChapters = const <MangaChapterEntry>[];
      ComicFolderManifest? folderManifest;
      var epubPages = const <String>[];
      var epubSpineMap = const <int>[];

      switch (book.kind) {
        case LocalBookKind.comic:
          if (book.isComicFolder) {
            folderManifest = await widget.local.loadComicFolderManifest(
              book.id,
            );
            resolvedCount = folderManifest?.pages.length ?? book.pageCount;
          } else {
            resolvedCount = book.pageCount;
          }
          if (book.chapters.length > 1) {
            resolvedChapters = List<MangaChapterEntry>.unmodifiable([
              for (final ch in book.chapters)
                MangaChapterEntry(
                  title: ch.title,
                  startPage: ch.offset,
                  pageCount: ch.length,
                ),
            ]);
          }
        case LocalBookKind.epub:
          final descriptor = await widget.local.loadEpubMangaDescriptor(
            book.id,
          );
          epubPages = descriptor.pages;
          epubSpineMap = descriptor.pageToSpineChapter;
          resolvedCount = epubPages.length;
          if (descriptor.chapters.length > 1) {
            resolvedChapters = List<MangaChapterEntry>.unmodifiable([
              for (final ch in descriptor.chapters)
                MangaChapterEntry(
                  title: ch.title,
                  startPage: ch.startPage,
                  pageCount: ch.pageCount,
                ),
            ]);
          }
        case LocalBookKind.pdf:
          resolvedCount = book.pageCount;
        case LocalBookKind.txt:
          throw StateError('纯文本书籍不支持漫画模式');
      }

      final startPage = _resolveInitialPage(
        book: book,
        pageCount: resolvedCount,
        epubSpineMap: epubSpineMap,
      );

      if (!mounted) return;
      _pageCount = resolvedCount;
      _chapters = resolvedChapters;
      _chapterStartPages = {
        for (final ch in resolvedChapters)
          if (ch.startPage > 0) ch.startPage,
      };
      _folderManifest = folderManifest;
      _epubPages = epubPages;
      _epubPageToSpine = epubSpineMap;
      _page = startPage;
      _loadingDescriptor = false;
      _syncReadingActivity();
      setState(() {});

      if (resolvedCount > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _preloadNeighbors(_page);
          if (widget.state.readerPreferences.mangaMode ==
                  MangaReadingMode.webtoon &&
              _page > 0) {
            _scrollToWebtoonPage(_page, animate: false);
          }
          unawaited(_saveCurrentPosition(_page));
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDescriptor = false;
        _descriptorError = error;
      });
      _syncReadingActivity();
    }
  }

  int _resolveInitialPage({
    required LocalBook book,
    required int pageCount,
    required List<int> epubSpineMap,
  }) {
    if (pageCount <= 0) return 0;
    if (widget.initialPage != null) {
      return widget.initialPage!.clamp(0, pageCount - 1);
    }
    if (book.kind == LocalBookKind.epub) {
      final saved = widget.state.positionFor(widget.novel.id);
      final targetChapter =
          widget.initialChapter ?? widget.state.chapterForNovel(widget.novel);
      if (saved?.paragraphIndex != null) {
        final savedImg = saved!.paragraphIndex!.clamp(0, pageCount - 1);
        if (widget.initialChapter == null ||
            (savedImg < epubSpineMap.length &&
                epubSpineMap[savedImg] == targetChapter)) {
          return savedImg;
        }
      }
      final firstMatch = epubSpineMap.indexOf(targetChapter);
      if (firstMatch >= 0) return firstMatch;
      return 0;
    }
    final raw =
        widget.initialChapter ?? widget.state.chapterForNovel(widget.novel);
    return raw.clamp(0, pageCount - 1);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activityForeground = state == AppLifecycleState.resumed;
    _syncReadingActivity();
  }

  @override
  void deactivate() {
    _activityAttached = false;
    _readingActivity.setActive(false);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _activityAttached = true;
    _syncReadingActivity();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readingActivity.dispose();
    _scrollSaveTimer?.cancel();
    if (_dirtyPosition && _pageCount > 0) {
      unawaited(_saveCurrentPosition(_page, notify: false));
    }
    if (_openedPdfFileUri != null) {
      releaseActivePdfReader(_openedPdfFileUri);
    } else {
      final book = _book;
      if (book != null && book.kind == LocalBookKind.pdf) {
        releaseActivePdfReader(book.fileUri);
      }
    }
    _webtoonController.removeListener(_onWebtoonScroll);
    _webtoonController.dispose();
    _pageController?.dispose();
    _chrome.dispose();
    _pageCache.clear();
    _pendingPages.clear();
    super.dispose();
  }

  void _toggleChrome() {
    _chromeTarget = !_chromeTarget;
    if (widget.state.effectiveReduceMotion ||
        MediaQuery.disableAnimationsOf(context)) {
      _chrome.value = _chromeTarget ? 1 : 0;
    } else if (_chromeTarget) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  Future<Uint8List> _readRawPageBytes(int page) async {
    final book = _book;
    if (book == null) throw StateError('书籍已移除');
    switch (book.kind) {
      case LocalBookKind.comic:
        if (book.isComicFolder) {
          final manifest =
              _folderManifest ??
              await widget.local.loadComicFolderManifest(book.id);
          if (manifest == null || page < 0 || page >= manifest.pages.length) {
            throw StateError('漫画文件夹清单缺失或页码越界');
          }
          _folderManifest = manifest;
          return widget.local.readComicFolderPage(manifest.pages[page]);
        }
        return widget.local.readComicArchivePage(book.id, page);
      case LocalBookKind.epub:
        if (page < 0 || page >= _epubPages.length) {
          throw RangeError.index(page, _epubPages, 'page');
        }
        return widget.local.readEpubMangaEntry(book.id, _epubPages[page]);
      case LocalBookKind.pdf:
        final width = _targetDecodeWidth().clamp(900, 2400);
        final path = await LocalPlatform.renderPdfPage(
          book.fileUri,
          page,
          width,
        );
        if (path.isEmpty) throw StateError('PDF 页面渲染失败');
        return File(path).readAsBytes();
      case LocalBookKind.txt:
        throw StateError('不支持的图片格式');
    }
  }

  int _targetDecodeWidth() {
    if (!mounted) return 1440;
    final media = MediaQuery.maybeOf(context);
    if (media == null) return 1440;
    return (media.size.width * media.devicePixelRatio).round().clamp(800, 2600);
  }

  Future<_MangaPageData> _loadPageData(int page, {required bool cropMargins}) {
    final cached = _pageCache.remove(page);
    if (cached != null) {
      _pageCache[page] = cached;
      if (cropMargins && cached.cropRect == null) {
        return _ensureCropRect(page, cached);
      }
      return Future<_MangaPageData>.value(cached);
    }
    return _pendingPages.putIfAbsent(page, () async {
      try {
        final bytes = await _readRawPageBytes(page);
        final (intrinsicSize, cropRect) = await _probeImageGeometry(
          bytes,
          computeCrop: cropMargins,
        );
        final entry = _MangaPageData(
          bytes: bytes,
          intrinsicSize: intrinsicSize,
          cropRect: cropRect,
        );
        _putPageCache(page, entry);
        final previousSize = _knownSizes[page];
        _knownSizes[page] = intrinsicSize;
        if (mounted &&
            (previousSize == null ||
                _isWideComicPage(previousSize) !=
                    _isWideComicPage(intrinsicSize))) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        return entry;
      } finally {
        _pendingPages.remove(page);
      }
    });
  }

  Future<_MangaPageData> _ensureCropRect(int page, _MangaPageData entry) async {
    if (entry.cropRect != null) return entry;
    final (_, crop) = await _probeImageGeometry(
      entry.bytes,
      computeCrop: true,
    );
    entry.cropRect = crop ?? const Rect.fromLTWH(0, 0, 1, 1);
    return entry;
  }

  Future<(Size, Rect?)> _probeImageGeometry(
    Uint8List bytes, {
    required bool computeCrop,
  }) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      if (!computeCrop) return (size, null);
      final sampleWidth = math.min(descriptor.width, 360);
      codec = await descriptor.instantiateCodec(targetWidth: sampleWidth);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final crop = await computeNormalizedCropRect(image);
      return (size, crop);
    } catch (_) {
      return (const Size(1000, 1414), computeCrop ? const Rect.fromLTWH(0, 0, 1, 1) : null);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _putPageCache(int page, _MangaPageData data) {
    _pageCache.remove(page);
    _pageCache[page] = data;
    while (_pageCache.length > _maxCachedPages) {
      _pageCache.remove(_pageCache.keys.first);
    }
  }

  void _preloadNeighbors(int centerPage) {
    if (!mounted || _pageCount <= 0) return;
    final cropMargins = widget.state.readerPreferences.mangaCropMargins;
    for (final delta in const [1, 2, -1]) {
      final target = centerPage + delta;
      if (target >= 0 && target < _pageCount && !_pageCache.containsKey(target)) {
        _loadPageData(target, cropMargins: cropMargins).ignore();
      }
    }
  }

  MangaChapterEntry? _chapterForPage(int page) {
    if (_chapters.isEmpty) return null;
    MangaChapterEntry? current;
    for (final ch in _chapters) {
      if (page >= ch.startPage) {
        current = ch;
      } else {
        break;
      }
    }
    return current;
  }

  int _chapterIndexForPage(int page) {
    if (_chapters.isEmpty) return -1;
    var found = 0;
    for (var i = 0; i < _chapters.length; i++) {
      if (page >= _chapters[i].startPage) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }

  Future<void> _saveCurrentPosition(int page, {bool notify = true}) async {
    if (_pageCount <= 0) return;
    final book = _book;
    if (book == null) return;
    _dirtyPosition = false;
    final clamped = page.clamp(0, _pageCount - 1);

    if (book.kind == LocalBookKind.epub && _epubPageToSpine.isNotEmpty) {
      final totalChapters = widget.novel.chapters.length;
      if (totalChapters <= 0) return;
      final spineChapter = _epubPageToSpine[clamped].clamp(
        0,
        totalChapters - 1,
      );
      var firstInSpine = clamped;
      while (firstInSpine > 0 &&
          _epubPageToSpine[firstInSpine - 1] == spineChapter) {
        firstInSpine -= 1;
      }
      var lastInSpine = clamped;
      while (lastInSpine + 1 < _epubPageToSpine.length &&
          _epubPageToSpine[lastInSpine + 1] == spineChapter) {
        lastInSpine += 1;
      }
      final countInSpine = math.max(1, lastInSpine - firstInSpine + 1);
      final isFinalPage = clamped >= _pageCount - 1 || _spreadCoversLastPage(clamped);
      final offsetInSpine = isFinalPage
          ? countInSpine
          : (clamped - firstInSpine + 1).clamp(1, countInSpine);
      await widget.state
          .savePosition(
            novel: widget.novel,
            chapter: spineChapter,
            offset: offsetInSpine.toDouble(),
            maximum: countInSpine.toDouble(),
            paragraphIndex: clamped,
            width: _viewportWidth,
            notify: notify,
          )
          .catchError((_) {});
      return;
    }

    final effectivePage = _spreadCoversLastPage(clamped)
        ? _pageCount - 1
        : clamped;
    await widget.state
        .savePosition(
          novel: widget.novel,
          chapter: effectivePage,
          offset: 1.0,
          maximum: 1.0,
          width: _viewportWidth,
          notify: notify,
        )
        .catchError((_) {});
  }

  bool _spreadCoversLastPage(int page) {
    if (_pageCount <= 0) return false;
    if (widget.state.readerPreferences.mangaMode == MangaReadingMode.webtoon) {
      return page >= _pageCount - 1;
    }
    if (_currentSpreads.isEmpty) return page >= _pageCount - 1;
    final idx = _spreadIndexForPage(_currentSpreads, page);
    return _currentSpreads[idx].contains(_pageCount - 1);
  }

  void _scheduleScrollSave() {
    _dirtyPosition = true;
    _scrollSaveTimer?.cancel();
    _scrollSaveTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      unawaited(_saveCurrentPosition(_page));
    });
  }

  void _onSpreadChanged(int spreadIndex) {
    if (_jumpingProgrammatically) return;
    if (spreadIndex < 0 || spreadIndex >= _currentSpreads.length) return;
    final nextPage = _currentSpreads[spreadIndex].firstPage;
    if (_page == nextPage) return;
    setState(() => _page = nextPage);
    _preloadNeighbors(nextPage);
    unawaited(_saveCurrentPosition(nextPage));
  }

  void _onWebtoonScroll() {
    if (_jumpingProgrammatically ||
        !_webtoonController.hasClients ||
        _pageCount <= 0) {
      return;
    }
    final pos = _webtoonController.position;
    if (pos.maxScrollExtent <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - 24) {
      if (_page != _pageCount - 1) {
        setState(() => _page = _pageCount - 1);
        _preloadNeighbors(_page);
      }
      _scheduleScrollSave();
      return;
    }
    final estimated = _estimateWebtoonPageFromOffset(
      pos.pixels + math.max(80.0, _viewportHeight * 0.35),
    );
    if (estimated != _page) {
      setState(() => _page = estimated);
      _preloadNeighbors(estimated);
    }
    _scheduleScrollSave();
  }

  double _estimatedWebtoonItemHeight(int page, double width) {
    final safeWidth = width > 0 ? width : 360.0;
    final size = _knownSizes[page];
    final crop = widget.state.readerPreferences.mangaCropMargins
        ? _pageCache[page]?.cropRect
        : null;
    if (size != null && size.width > 0 && size.height > 0) {
      final w = size.width * (crop?.width ?? 1.0);
      final h = size.height * (crop?.height ?? 1.0);
      if (w > 0 && h > 0) {
        return (safeWidth * (h / w)).clamp(64.0, safeWidth * 6.0);
      }
    }
    return safeWidth * 1.414;
  }

  int _estimateWebtoonPageFromOffset(double targetOffset) {
    if (_pageCount <= 1) return 0;
    final width = _viewportWidth > 0 ? _viewportWidth : 360.0;
    var cursor = 0.0;
    for (var i = 0; i < _pageCount; i++) {
      final h = _estimatedWebtoonItemHeight(i, width);
      if (cursor + h >= targetOffset) return i;
      cursor += h;
    }
    return _pageCount - 1;
  }

  double _estimateOffsetForWebtoonPage(int targetPage) {
    final width = _viewportWidth > 0 ? _viewportWidth : 360.0;
    var offset = 0.0;
    final limit = targetPage.clamp(0, _pageCount - 1);
    for (var i = 0; i < limit; i++) {
      offset += _estimatedWebtoonItemHeight(i, width);
    }
    return offset;
  }

  void _scrollToWebtoonPage(int targetPage, {bool animate = false}) {
    if (!_webtoonController.hasClients || _pageCount <= 0) return;
    final clamped = targetPage.clamp(0, _pageCount - 1);
    final keyContext = _webtoonItemKeys[clamped]?.currentContext;
    if (keyContext != null) {
      _jumpingProgrammatically = true;
      Scrollable.ensureVisible(
        keyContext,
        duration: animate && !widget.state.effectiveReduceMotion
            ? const Duration(milliseconds: 220)
            : Duration.zero,
        curve: Curves.easeOutCubic,
      ).whenComplete(() => _jumpingProgrammatically = false);
      return;
    }
    final offset = _estimateOffsetForWebtoonPage(clamped).clamp(
      0.0,
      _webtoonController.position.maxScrollExtent,
    );
    _jumpingProgrammatically = true;
    if (animate && !widget.state.effectiveReduceMotion) {
      _webtoonController
          .animateTo(
            offset,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() => _jumpingProgrammatically = false);
    } else {
      _webtoonController.jumpTo(offset);
      _jumpingProgrammatically = false;
    }
  }

  void _jumpToPage(int targetPage, {bool animate = false}) {
    if (_pageCount <= 0) return;
    _readingActivity.notifyInteraction();
    final clamped = targetPage.clamp(0, _pageCount - 1);
    setState(() => _page = clamped);
    _preloadNeighbors(clamped);
    final mode = widget.state.readerPreferences.mangaMode;
    if (mode == MangaReadingMode.webtoon) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToWebtoonPage(clamped, animate: animate);
      });
    } else if (_pageController != null &&
        _pageController!.hasClients &&
        _currentSpreads.isNotEmpty) {
      final spreadIdx = _spreadIndexForPage(_currentSpreads, clamped);
      _jumpingProgrammatically = true;
      if (animate && !widget.state.effectiveReduceMotion) {
        _pageController!
            .animateToPage(
              spreadIdx,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() => _jumpingProgrammatically = false);
      } else {
        _pageController!.jumpToPage(spreadIdx);
        _jumpingProgrammatically = false;
      }
    }
    unawaited(_saveCurrentPosition(clamped));
  }

  void _stepPageOrSpread(int delta) {
    if (_pageCount <= 0 || delta == 0) return;
    _readingActivity.notifyInteraction();
    final mode = widget.state.readerPreferences.mangaMode;
    if (mode == MangaReadingMode.webtoon) {
      if (!_webtoonController.hasClients) return;
      final step = (_viewportHeight > 0 ? _viewportHeight : 600.0) * 0.82;
      final nextOffset = (_webtoonController.offset + step * delta).clamp(
        0.0,
        _webtoonController.position.maxScrollExtent,
      );
      if (widget.state.effectiveReduceMotion) {
        _webtoonController.jumpTo(nextOffset);
      } else {
        unawaited(
          _webtoonController.animateTo(
            nextOffset,
            duration: const Duration(milliseconds: 190),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      return;
    }
    if (_currentSpreads.isEmpty) return;
    final currentIdx = _spreadIndexForPage(_currentSpreads, _page);
    final nextIdx = (currentIdx + delta).clamp(0, _currentSpreads.length - 1);
    if (nextIdx == currentIdx) {
      showNovelFeedback(context, delta > 0 ? '已是最后一页' : '已是第一页');
      return;
    }
    _jumpToPage(_currentSpreads[nextIdx].firstPage, animate: true);
  }

  void _handleViewportTap(Offset localPos, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      _toggleChrome();
      return;
    }
    final prefs = widget.state.readerPreferences;
    if (prefs.edgeDeadZone > 0 &&
        (localPos.dx < prefs.edgeDeadZone ||
            localPos.dx > size.width - prefs.edgeDeadZone)) {
      return;
    }
    final rx = localPos.dx / size.width;
    final ry = localPos.dy / size.height;

    if (!prefs.mangaTapPaging) {
      _toggleChrome();
      return;
    }

    if (prefs.mangaMode == MangaReadingMode.webtoon) {
      if (rx >= 0.28 && rx <= 0.72 && ry >= 0.28 && ry <= 0.72) {
        _toggleChrome();
      } else if (ry < 0.34 || rx < 0.24) {
        _stepPageOrSpread(-1);
      } else {
        _stepPageOrSpread(1);
      }
      return;
    }

    if (rx >= 0.32 && rx <= 0.68) {
      _toggleChrome();
      return;
    }
    final tappedLeft = rx < 0.32;
    if (prefs.mangaMode == MangaReadingMode.rtl) {
      _stepPageOrSpread(tappedLeft ? 1 : -1);
    } else {
      _stepPageOrSpread(tappedLeft ? -1 : 1);
    }
  }

  List<ReaderBookmark> _pageBookmarks([int? targetPage]) {
    if (_pageCount <= 0) return const [];
    final page = targetPage ?? _page;
    return [
      for (final mark in widget.state.bookmarksFor(widget.novel.id))
        if (!mark.isUnderline &&
            mark.quote.isEmpty &&
            mark.position.chapterId == 0 &&
            mark.position.chapter == page)
          mark,
    ];
  }

  Future<void> _toggleBookmark() async {
    if (_addingBookmark || _pageCount <= 0) return;
    _addingBookmark = true;
    final page = _page;
    final matched = _pageBookmarks(page);
    if (matched.isNotEmpty) {
      try {
        for (final mark in matched) {
          await widget.state.removeBookmark(widget.novel.id, mark.id);
        }
        if (mounted) showNovelFeedback(context, '已取消书签');
      } catch (_) {
        if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
      } finally {
        _addingBookmark = false;
      }
      return;
    }
    try {
      final ch = _chapterForPage(page);
      final title = ch != null
          ? '${ch.title} · 第 ${page + 1} 页'
          : '第 ${page + 1} 页';
      final mark = await widget.state.addPageBookmark(
        novel: widget.novel,
        page: page,
        pageCount: _pageCount,
        title: title,
      );
      if (mounted) {
        showNovelFeedback(
          context,
          mark == null ? '书签保存失败，请重试' : '已添加$title书签',
        );
      }
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '书签保存失败，请重试',
        );
      }
    } finally {
      _addingBookmark = false;
    }
  }

  Future<void> _switchToNormalReader() async {
    final book = _book;
    if (book == null) return;
    if (book.kind != LocalBookKind.epub && book.kind != LocalBookKind.pdf) {
      return;
    }
    await _saveCurrentPosition(_page);
    await widget.state.setBookMangaModeOverride(widget.novel.id, 'normal');
    if (!mounted) return;
    final Widget destination;
    if (book.kind == LocalBookKind.pdf) {
      destination = LocalPdfReaderPage(
        novel: widget.novel,
        state: widget.state,
        local: widget.local,
        initialPage: _page,
      );
    } else {
      final spineChapter =
          (_page >= 0 && _page < _epubPageToSpine.length)
              ? _epubPageToSpine[_page]
              : widget.state.chapterForNovel(widget.novel);
      destination = LocalEpubReaderPage(
        novel: widget.novel,
        state: widget.state,
        local: widget.local,
        initialChapter: spineChapter,
      );
    }
    await Navigator.of(context).pushReplacement(
      softRoute<void>(
        destination,
        reduceMotion: widget.state.effectiveReduceMotion,
      ),
    );
  }

  Future<void> _openNavigationSheet() async {
    final picked = await showJellySheet<int>(
      context: context,
      reduceMotion: widget.state.effectiveReduceMotion,
      builder: (sheetContext) => _MangaNavigationSheet(
        state: widget.state,
        novelId: widget.novel.id,
        pageCount: _pageCount,
        currentPage: _page,
        chapters: _chapters,
        currentChapterIndex: _chapterIndexForPage(_page),
      ),
    );
    if (picked != null && mounted) {
      _jumpToPage(picked);
    }
  }

  Future<void> _openModeSheet() async {
    final book = _book;
    final canSwitchNormal =
        book != null &&
        (book.kind == LocalBookKind.epub || book.kind == LocalBookKind.pdf);
    final switched = await showJellySheet<bool>(
      context: context,
      reduceMotion: widget.state.effectiveReduceMotion,
      builder: (sheetContext) => _MangaModeSheet(
        state: widget.state,
        canSwitchNormal: canSwitchNormal,
      ),
    );
    if (switched == true && mounted) {
      await _switchToNormalReader();
    }
  }

  Future<void> _openVisualSheet() async {
    await showJellySheet<void>(
      context: context,
      reduceMotion: widget.state.effectiveReduceMotion,
      builder: (sheetContext) => _MangaVisualSheet(state: widget.state),
    );
  }

  List<ReaderAction> _actions() => [
    ReaderAction(
      key: const ValueKey('reader-catalogue-entry'),
      icon: CupertinoIcons.list_bullet,
      caption: '目录',
      label: '目录与书签',
      onPressed: _pageCount == 0 ? null : _openNavigationSheet,
      unavailable: _pageCount == 0 ? '暂无页面可导航' : null,
    ),
    ReaderAction(
      key: const ValueKey('manga-mode-entry'),
      icon: CupertinoIcons.square_split_2x1,
      caption: '模式',
      label: '阅读模式与跨页',
      onPressed: _openModeSheet,
    ),
    ReaderAction(
      key: const ValueKey('reader-appearance-entry'),
      icon: CupertinoIcons.sun_max,
      caption: '画面',
      label: '画面增强与纸色',
      onPressed: _openVisualSheet,
    ),
    ReaderAction(
      key: const ValueKey('manga-quick-bookmark-entry'),
      icon: _pageBookmarks().isNotEmpty
          ? CupertinoIcons.bookmark_fill
          : CupertinoIcons.bookmark,
      caption: '书签',
      label: '添加或取消书签',
      onPressed: _pageCount == 0 ? null : _toggleBookmark,
      unavailable: _pageCount == 0 ? '暂无页面可添加书签' : null,
    ),
  ];

  String _statusText(ReaderPreferences prefs) {
    if (_loadingDescriptor || _pageCount <= 0) return '';
    final ch = _chapterForPage(_page);
    final prefix = ch != null ? '${ch.title} · ' : '';
    String pageLabel = '第 ${_page + 1} / $_pageCount 页';
    if (prefs.mangaMode != MangaReadingMode.webtoon &&
        _currentSpreads.isNotEmpty) {
      final spread = _currentSpreads[_spreadIndexForPage(_currentSpreads, _page)];
      if (spread.isDouble) {
        pageLabel =
            '第 ${spread.firstPage + 1}-${spread.lastPage + 1} / $_pageCount 页';
      }
    }
    final pct = (((_page + 1) / _pageCount) * 100).round().clamp(0, 100);
    return '$prefix$pageLabel · $pct%';
  }

  bool _resolveSpreadEnabled(
    BoxConstraints constraints,
    ReaderPreferences prefs,
  ) {
    if (prefs.mangaMode == MangaReadingMode.webtoon) return false;
    return switch (prefs.mangaSpread) {
      MangaSpreadMode.off => false,
      MangaSpreadMode.autoLandscape =>
        constraints.maxWidth > constraints.maxHeight * 1.05,
      MangaSpreadMode.always => true,
    };
  }

  void _syncSpreads(BoxConstraints constraints, ReaderPreferences prefs) {
    final spreadEnabled = _resolveSpreadEnabled(constraints, prefs);
    final nextSpreads = buildMangaSpreads(
      pageCount: _pageCount,
      spreadEnabled: spreadEnabled,
      coverOffset: prefs.mangaCoverOffset,
      knownPageSizes: _knownSizes,
      chapterStartPages: _chapterStartPages,
    );
    final targetIdx = _spreadIndexForPage(nextSpreads, _page);
    final changed =
        !listEquals(_currentSpreads, nextSpreads) ||
        _lastSpreadEnabled != spreadEnabled ||
        _lastCoverOffset != prefs.mangaCoverOffset;
    _currentSpreads = nextSpreads;
    _lastSpreadEnabled = spreadEnabled;
    _lastCoverOffset = prefs.mangaCoverOffset;

    if (_pageController == null) {
      _pageController = PageController(initialPage: targetIdx);
    } else if (changed && _pageController!.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _pageController == null ||
            !_pageController!.hasClients ||
            _currentSpreads.isEmpty) {
          return;
        }
        final syncedIdx = _spreadIndexForPage(_currentSpreads, _page);
        if (_pageController!.page?.round() != syncedIdx) {
          _jumpingProgrammatically = true;
          _pageController!.jumpToPage(syncedIdx);
          _jumpingProgrammatically = false;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _readingActivity.notifyInteraction(),
    child: ReaderPaperScope(
      state: widget.state,
      child: Builder(builder: _buildScaffold),
    ),
  );

  Widget _buildScaffold(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.state.readerSettingsChanges,
        widget.state.bookmarkChanges,
      ]),
      builder: (context, _) {
        final prefs = widget.state.readerPreferences;
        final canvasColor = prefs.mangaDarkCanvas
            ? _darkCanvasColor
            : theme.colorScheme.surface;
        final brightness = prefs.mangaDarkCanvas
            ? Brightness.dark
            : theme.brightness;
        return ReaderVolumePaging(
          enabled: prefs.volumePaging && _pageCount > 0,
          onPage: _stepPageOrSpread,
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: novelSystemUiStyle(brightness),
            child: ReaderScaffold(
              chrome: _chrome,
              novelId: widget.novel.id,
              title: widget.novel.title,
              bookmarkListenable: widget.state.bookmarkChanges,
              isBookmarked: () => _pageBookmarks().isNotEmpty,
              onAddBookmark: _pageCount == 0 ? null : _toggleBookmark,
              actions: _actions(),
              progress: _pageCount > 1 ? _buildProgressBar(context, prefs) : null,
              useAtmosphere: false,
              blurBottom: false,
              maskTopSafeArea: () => false,
              bottomMaxWidth: 520,
              backgroundColor: canvasColor,
              statusText: _statusText(prefs),
              body: _buildBody(context, prefs, canvasColor),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    ReaderPreferences prefs,
    Color canvasColor,
  ) {
    final muted = prefs.mangaDarkCanvas
        ? Colors.white70
        : Theme.of(context).colorScheme.onSurfaceVariant;
    if (_loadingDescriptor) {
      return Center(child: CircularProgressIndicator(color: muted));
    }
    if (_descriptorError != null) {
      final book = _book;
      final canFallback =
          book != null &&
          (book.kind == LocalBookKind.epub || book.kind == LocalBookKind.pdf);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, color: muted, size: 48),
              const SizedBox(height: 12),
              Text(
                _descriptorError is FormatException
                    ? (_descriptorError as FormatException).message
                    : '漫画加载失败，请检查文件是否完整',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                children: [
                  TextButton(
                    onPressed: _initBookSource,
                    child: const Text('重试'),
                  ),
                  if (canFallback)
                    TextButton(
                      onPressed: _switchToNormalReader,
                      child: const Text('切换为常规阅读器'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (_pageCount <= 0) {
      final book = _book;
      final isEpub = book?.kind == LocalBookKind.epub;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isEpub ? '该 EPUB 未提取到可展示的漫画图片' : '未找到可阅读的漫画页面',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
              if (isEpub) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _switchToNormalReader,
                  child: const Text('切换为常规阅读器'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        _syncSpreads(constraints, prefs);

        final invert =
            prefs.mangaInvert ||
            (_book?.kind == LocalBookKind.pdf &&
                Theme.of(context).brightness == Brightness.dark &&
                widget.state.pdfNightInvert);

        final Widget viewport = prefs.mangaMode == MangaReadingMode.webtoon
            ? _buildWebtoonView(context, prefs, invert, muted)
            : _buildPagedView(context, prefs, invert, muted);

        final dim = prefs.mangaNightDim.clamp(0.0, 0.75);
        final statusLabel = _statusText(prefs);
        return ColoredBox(
          key: const ValueKey('manga-canvas'),
          color: canvasColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              viewport,
              if (prefs.showStatusInfo &&
                  !prefs.showReaderStatus &&
                  statusLabel.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _chrome,
                      builder: (context, child) {
                        final alpha = (1.0 - _chrome.value).clamp(0.0, 1.0);
                        if (alpha <= 0.01) return const SizedBox.shrink();
                        return Opacity(opacity: alpha, child: child);
                      },
                      child: DecoratedBox(
                        key: const ValueKey('manga-page-hud'),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.52),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Text(
                            statusLabel,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              height: 1.2,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (dim > 0)
                IgnorePointer(
                  child: ColoredBox(
                    key: const ValueKey('manga-night-dim-overlay'),
                    color: Colors.black.withValues(alpha: dim),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPagedView(
    BuildContext context,
    ReaderPreferences prefs,
    bool invert,
    Color muted,
  ) {
    final isRtl = prefs.mangaMode == MangaReadingMode.rtl;
    final spreads = _currentSpreads;
    final controller =
        _pageController ??= PageController(
          initialPage: _spreadIndexForPage(spreads, _page),
        );

    return PageView.builder(
      key: ValueKey('manga-pageview-${prefs.mangaMode.name}'),
      controller: controller,
      reverse: isRtl,
      itemCount: spreads.length,
      onPageChanged: _onSpreadChanged,
      itemBuilder: (context, spreadIndex) {
        final spread = spreads[spreadIndex];
        return _ZoomableMangaSurface(
          key: ValueKey('manga-spread-${spread.pages.join("_")}'),
          onViewportTap: _handleViewportTap,
          onCenterToggle: _toggleChrome,
          reduceMotion: widget.state.effectiveReduceMotion,
          child: spread.isDouble
              ? _buildDoubleSpread(
                  context,
                  spread: spread,
                  isRtl: isRtl,
                  cropMargins: prefs.mangaCropMargins,
                  invert: invert,
                  muted: muted,
                )
              : Center(
                  child: _buildSinglePageImage(
                    context,
                    page: spread.firstPage,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    cropMargins: prefs.mangaCropMargins,
                    invert: invert,
                    muted: muted,
                  ),
                ),
        );
      },
    );
  }

  Widget _buildDoubleSpread(
    BuildContext context, {
    required MangaSpread spread,
    required bool isRtl,
    required bool cropMargins,
    required bool invert,
    required Color muted,
  }) {
    final leftPage = isRtl ? spread.lastPage : spread.firstPage;
    final rightPage = isRtl ? spread.firstPage : spread.lastPage;
    return Row(
      key: ValueKey('manga-double-spread-${spread.firstPage}-${spread.lastPage}'),
      children: [
        Expanded(
          child: _buildSinglePageImage(
            context,
            page: leftPage,
            fit: BoxFit.contain,
            alignment: Alignment.centerRight,
            cropMargins: cropMargins,
            invert: invert,
            muted: muted,
          ),
        ),
        Expanded(
          child: _buildSinglePageImage(
            context,
            page: rightPage,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            cropMargins: cropMargins,
            invert: invert,
            muted: muted,
          ),
        ),
      ],
    );
  }

  Widget _buildWebtoonView(
    BuildContext context,
    ReaderPreferences prefs,
    bool invert,
    Color muted,
  ) {
    final cacheExtent = (_viewportHeight > 0 ? _viewportHeight : 800.0) * 2.0;
    return _ZoomableMangaSurface(
      key: const ValueKey('manga-webtoon-zoom'),
      onViewportTap: _handleViewportTap,
      onCenterToggle: _toggleChrome,
      reduceMotion: widget.state.effectiveReduceMotion,
      child: ListView.builder(
        key: const ValueKey('manga-webtoon-list'),
        controller: _webtoonController,
        padding: EdgeInsets.zero,
        cacheExtent: cacheExtent,
        itemCount: _pageCount,
        itemBuilder: (context, page) {
          final itemKey = _webtoonItemKeys.putIfAbsent(
            page,
            () => GlobalKey(debugLabel: 'webtoon-page-$page'),
          );
          return KeyedSubtree(
            key: itemKey,
            child: _buildWebtoonPageItem(
              context,
              page: page,
              cropMargins: prefs.mangaCropMargins,
              invert: invert,
              muted: muted,
            ),
          );
        },
      ),
    );
  }

  Widget _buildWebtoonPageItem(
    BuildContext context, {
    required int page,
    required bool cropMargins,
    required bool invert,
    required Color muted,
  }) {
    final width = _viewportWidth > 0
        ? _viewportWidth
        : MediaQuery.sizeOf(context).width;
    final decodeWidth = _targetDecodeWidth();
    return FutureBuilder<_MangaPageData>(
      future: _loadPageData(page, cropMargins: cropMargins),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final data = snapshot.data!;
          final rect = cropMargins
              ? (data.cropRect ?? const Rect.fromLTWH(0, 0, 1, 1))
              : const Rect.fromLTWH(0, 0, 1, 1);
          Widget painted = _CroppedMemoryMangaImage(
            bytes: data.bytes,
            intrinsicSize: data.intrinsicSize,
            cropRect: rect,
            decodeWidth: decodeWidth,
            muted: muted,
            onError: () => _pageCache.remove(page),
          );
          if (invert) {
            painted = ColorFiltered(
              key: ValueKey('manga-color-invert-$page'),
              colorFilter: _invertFilter,
              child: painted,
            );
          }
          final croppedW = math.max(1.0, data.intrinsicSize.width * rect.width);
          final croppedH = math.max(
            1.0,
            data.intrinsicSize.height * rect.height,
          );
          return AspectRatio(
            aspectRatio: croppedW / croppedH,
            child: FittedBox(fit: BoxFit.fill, child: painted),
          );
        }
        final placeholderHeight = _estimatedWebtoonItemHeight(page, width);
        if (snapshot.hasError) {
          return SizedBox(
            height: math.min(placeholderHeight, 320),
            child: _buildPageError(page, muted),
          );
        }
        return SizedBox(
          height: placeholderHeight,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: muted),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSinglePageImage(
    BuildContext context, {
    required int page,
    required BoxFit fit,
    required Alignment alignment,
    required bool cropMargins,
    required bool invert,
    required Color muted,
  }) {
    final decodeWidth = _targetDecodeWidth();
    return FutureBuilder<_MangaPageData>(
      future: _loadPageData(page, cropMargins: cropMargins),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final data = snapshot.data!;
          final rect = cropMargins
              ? (data.cropRect ?? const Rect.fromLTWH(0, 0, 1, 1))
              : const Rect.fromLTWH(0, 0, 1, 1);
          Widget painted = _CroppedMemoryMangaImage(
            bytes: data.bytes,
            intrinsicSize: data.intrinsicSize,
            cropRect: rect,
            decodeWidth: decodeWidth,
            muted: muted,
            onError: () => _pageCache.remove(page),
          );
          if (invert) {
            painted = ColorFiltered(
              key: ValueKey('manga-color-invert-$page'),
              colorFilter: _invertFilter,
              child: painted,
            );
          }
          return SizedBox.expand(
            child: FittedBox(
              fit: fit,
              alignment: alignment,
              child: painted,
            ),
          );
        }
        if (snapshot.hasError) {
          return _buildPageError(page, muted);
        }
        return Center(child: CircularProgressIndicator(color: muted));
      },
    );
  }

  Widget _buildPageError(int page, Color muted) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, color: muted, size: 42),
        const SizedBox(height: 8),
        Text('第 ${page + 1} 页加载失败', style: TextStyle(color: muted, fontSize: 13)),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () {
            _pageCache.remove(page);
            _pendingPages.remove(page);
            if (mounted) setState(() {});
          },
          child: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _buildProgressBar(BuildContext context, ReaderPreferences prefs) {
    final scheme = Theme.of(context).colorScheme;
    final count = _pageCount;
    final isRtl = prefs.mangaMode == MangaReadingMode.rtl;
    final chapterIdx = _chapterIndexForPage(_page);
    final hasMultiChapters = _chapters.length > 1;
    final canPrevChapter = hasMultiChapters && chapterIdx > 0;
    final canNextChapter =
        hasMultiChapters && chapterIdx >= 0 && chapterIdx + 1 < _chapters.length;

    void goPrevChapter() {
      if (!canPrevChapter) return;
      _jumpToPage(_chapters[chapterIdx - 1].startPage);
    }

    void goNextChapter() {
      if (!canNextChapter) return;
      _jumpToPage(_chapters[chapterIdx + 1].startPage);
    }

    final statusCaption = _statusText(prefs);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (statusCaption.isNotEmpty)
          AnimatedBuilder(
            animation: _chrome,
            builder: (context, child) =>
                _chrome.value > 0.01 ? child! : const SizedBox.shrink(),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                statusCaption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        Row(
          children: [
            if (hasMultiChapters)
              IconButton(
                key: const ValueKey('manga-prev-chapter'),
                visualDensity: VisualDensity.compact,
                tooltip: isRtl ? '下一话' : '上一话',
                onPressed: isRtl
                    ? (canNextChapter ? goNextChapter : null)
                    : (canPrevChapter ? goPrevChapter : null),
                icon: Icon(
                  CupertinoIcons.chevron_left_2,
                  size: 16,
                  color: (isRtl ? canNextChapter : canPrevChapter)
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                ),
              ),
            Text(
              isRtl ? '$count' : '${_page + 1}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: Directionality(
                textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                child: Slider(
                  key: const ValueKey('manga-page-slider'),
                  value: _page.clamp(0, count - 1).toDouble(),
                  min: 0,
                  max: (count - 1).toDouble(),
                  divisions: count > 1 ? count - 1 : null,
                  activeColor: scheme.secondary,
                  inactiveColor: scheme.outlineVariant,
                  label: '第 ${_page + 1} 页',
                  onChanged: (value) =>
                      _jumpToPage(value.round().clamp(0, count - 1)),
                ),
              ),
            ),
            Text(
              isRtl ? '${_page + 1}' : '$count',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (hasMultiChapters)
              IconButton(
                key: const ValueKey('manga-next-chapter'),
                visualDensity: VisualDensity.compact,
                tooltip: isRtl ? '上一话' : '下一话',
                onPressed: isRtl
                    ? (canPrevChapter ? goPrevChapter : null)
                    : (canNextChapter ? goNextChapter : null),
                icon: Icon(
                  CupertinoIcons.chevron_right_2,
                  size: 16,
                  color: (isRtl ? canPrevChapter : canNextChapter)
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _CroppedMemoryMangaImage extends StatelessWidget {
  const _CroppedMemoryMangaImage({
    required this.bytes,
    required this.intrinsicSize,
    required this.cropRect,
    required this.decodeWidth,
    required this.muted,
    required this.onError,
  });

  final Uint8List bytes;
  final Size intrinsicSize;
  final Rect cropRect;
  final int decodeWidth;
  final Color muted;
  final VoidCallback onError;

  @override
  Widget build(BuildContext context) {
    final fullW = intrinsicSize.width > 0 ? intrinsicSize.width : 1000.0;
    final fullH = intrinsicSize.height > 0 ? intrinsicSize.height : 1414.0;
    final croppedW = math.max(1.0, fullW * cropRect.width);
    final croppedH = math.max(1.0, fullH * cropRect.height);

    final rawImage = Image.memory(
      bytes,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      cacheWidth: decodeWidth,
      errorBuilder: (context, error, stack) {
        onError();
        return SizedBox(
          width: 160,
          height: 220,
          child: Center(
            child: Icon(Icons.broken_image_outlined, color: muted, size: 42),
          ),
        );
      },
    );

    if (cropRect.left == 0 &&
        cropRect.top == 0 &&
        cropRect.right == 1 &&
        cropRect.bottom == 1) {
      return SizedBox(width: fullW, height: fullH, child: rawImage);
    }

    return SizedBox(
      width: croppedW,
      height: croppedH,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: -cropRect.left * fullW,
              top: -cropRect.top * fullH,
              width: fullW,
              height: fullH,
              child: rawImage,
            ),
          ],
        ),
      ),
    );
  }
}

/// 支持 1x 单指穿透翻页/滚动、双指捏合缩放、双击焦点放大复位的交互画布。
class _ZoomableMangaSurface extends StatefulWidget {
  const _ZoomableMangaSurface({
    super.key,
    required this.child,
    required this.onViewportTap,
    required this.onCenterToggle,
    required this.reduceMotion,
  });

  final Widget child;
  final void Function(Offset localPosition, Size viewportSize) onViewportTap;
  final VoidCallback onCenterToggle;
  final bool reduceMotion;

  @override
  State<_ZoomableMangaSurface> createState() => _ZoomableMangaSurfaceState();
}

class _ZoomableMangaSurfaceState extends State<_ZoomableMangaSurface>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<Matrix4>? _matrixTween;
  Offset _doubleTapPosition = Offset.zero;
  Offset? _lastTapUpPosition;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
    _zoomAnim.addListener(() {
      if (_matrixTween != null) {
        _transform.value = _matrixTween!.value;
      }
    });
  }

  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.02;
    if (zoomed != _isZoomed && mounted) {
      setState(() => _isZoomed = zoomed);
    }
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _zoomAnim.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _animateToMatrix(Matrix4 end) {
    if (widget.reduceMotion) {
      _transform.value = end;
      return;
    }
    _matrixTween = Matrix4Tween(begin: _transform.value, end: end).animate(
      CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOutCubic),
    );
    _zoomAnim.forward(from: 0);
  }

  void _handleDoubleTap(Size viewport) {
    if (_isZoomed) {
      _animateToMatrix(Matrix4.identity());
      return;
    }
    const targetScale = 2.25;
    final focal = _doubleTapPosition;
    final maxDx = 0.0;
    final minDx = viewport.width * (1.0 - targetScale);
    final maxDy = 0.0;
    final minDy = viewport.height * (1.0 - targetScale);
    final dx = (viewport.width / 2 - focal.dx * targetScale).clamp(minDx, maxDx);
    final dy = (viewport.height / 2 - focal.dy * targetScale).clamp(
      minDy,
      maxDy,
    );
    final zoomed = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(targetScale, targetScale, 1, 1);
    _animateToMatrix(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          key: const ValueKey('reader-content-tap'),
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) => _lastTapUpPosition = details.localPosition,
          onTap: () {
            final pos =
                _lastTapUpPosition ?? Offset(size.width / 2, size.height / 2);
            if (_isZoomed) {
              widget.onCenterToggle();
            } else {
              widget.onViewportTap(pos, size);
            }
          },
          onDoubleTapDown: (details) =>
              _doubleTapPosition = details.localPosition,
          onDoubleTap: () => _handleDoubleTap(size),
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1.0,
            maxScale: 4.0,
            panEnabled: _isZoomed,
            scaleEnabled: true,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

class _MangaNavigationSheet extends StatefulWidget {
  const _MangaNavigationSheet({
    required this.state,
    required this.novelId,
    required this.pageCount,
    required this.currentPage,
    required this.chapters,
    required this.currentChapterIndex,
  });

  final LibraryState state;
  final int novelId;
  final int pageCount;
  final int currentPage;
  final List<MangaChapterEntry> chapters;
  final int currentChapterIndex;

  @override
  State<_MangaNavigationSheet> createState() => _MangaNavigationSheetState();
}

class _MangaNavigationSheetState extends State<_MangaNavigationSheet> {
  late bool _showBookmarks = widget.chapters.isEmpty;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state.bookmarkChanges,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final marks = [
        for (final mark in widget.state.bookmarksFor(widget.novelId))
          if (!mark.isUnderline &&
              mark.position.chapter >= 0 &&
              mark.position.chapter < widget.pageCount)
            mark,
      ];
      return Padding(
        key: const ValueKey('manga-navigation-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '目录与书签', code: 'MANGA / NAVIGATION'),
            if (widget.chapters.isNotEmpty) ...[
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment<bool>(
                    value: false,
                    label: Text('章节 (${widget.chapters.length})'),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text('书签 (${marks.length})'),
                  ),
                ],
                selected: {_showBookmarks},
                onSelectionChanged: (next) =>
                    setState(() => _showBookmarks = next.first),
              ),
            ],
            const SizedBox(height: 12),
            if (!_showBookmarks && widget.chapters.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.chapters.length,
                  itemBuilder: (context, index) {
                    final ch = widget.chapters[index];
                    final active = index == widget.currentChapterIndex;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        ch.title,
                        style: TextStyle(
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: active ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                      subtitle: Text(
                        '第 ${ch.startPage + 1} 页起 · 共 ${ch.pageCount} 页',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: active
                          ? Icon(Icons.circle, size: 8, color: scheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, ch.startPage),
                    );
                  },
                ),
              )
            else if (marks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '还没有书签。点击顶栏或底栏书签按钮即可记录当前漫画页。',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: marks.length,
                  itemBuilder: (context, index) {
                    final mark = marks[index];
                    final active = mark.position.chapter == widget.currentPage;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(mark.chapterTitle),
                      subtitle: Text(
                        '第 ${mark.position.chapter + 1} / ${widget.pageCount} 页',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (active)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Icon(
                                Icons.circle,
                                size: 8,
                                color: scheme.primary,
                              ),
                            ),
                          IconButton(
                            icon: Icon(
                              CupertinoIcons.delete,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                            tooltip: '删除书签',
                            onPressed: () => widget.state.removeBookmark(
                              widget.novelId,
                              mark.id,
                            ),
                          ),
                        ],
                      ),
                      onTap: () =>
                          Navigator.pop(context, mark.position.chapter),
                    );
                  },
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _MangaModeSheet extends StatelessWidget {
  const _MangaModeSheet({
    required this.state,
    required this.canSwitchNormal,
  });

  final LibraryState state;
  final bool canSwitchNormal;

  Future<void> _update(BuildContext context, ReaderPreferences next) async {
    try {
      await state.setReaderPreferences(next);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.readerSettingsChanges,
    builder: (context, _) {
      final prefs = state.readerPreferences;
      final scheme = Theme.of(context).colorScheme;
      final paged = prefs.mangaMode != MangaReadingMode.webtoon;
      return SingleChildScrollView(
        key: const ValueKey('manga-mode-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '阅读模式与辅助', code: 'MANGA / MODE'),
            const SizedBox(height: 12),
            Text(
              '翻页方向',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<MangaReadingMode>(
              key: const ValueKey('manga-reading-mode-segment'),
              segments: [
                for (final mode in MangaReadingMode.values)
                  ButtonSegment<MangaReadingMode>(
                    value: mode,
                    label: Text(mode.label),
                  ),
              ],
              selected: {prefs.mangaMode},
              onSelectionChanged: (next) =>
                  _update(context, prefs.copyWith(mangaMode: next.first)),
            ),
            const SizedBox(height: 16),
            Text(
              '双页跨页拼合',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<MangaSpreadMode>(
              key: const ValueKey('manga-spread-mode-segment'),
              segments: [
                for (final mode in MangaSpreadMode.values)
                  ButtonSegment<MangaSpreadMode>(
                    value: mode,
                    label: Text(mode.label),
                  ),
              ],
              selected: {prefs.mangaSpread},
              onSelectionChanged: paged
                  ? (next) =>
                        _update(context, prefs.copyWith(mangaSpread: next.first))
                  : null,
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('manga-cover-offset-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('首页单页偏移（封面独立）'),
              subtitle: const Text('双页模式下第 1 页单独显示，保证内页跨页左右对齐'),
              value: prefs.mangaCoverOffset,
              onChanged: paged && prefs.mangaSpread != MangaSpreadMode.off
                  ? (val) =>
                        _update(context, prefs.copyWith(mangaCoverOffset: val))
                  : null,
            ),
            const Divider(height: 20),
            SwitchListTile.adaptive(
              key: const ValueKey('manga-crop-margins-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('自动裁切四周留白'),
              subtitle: const Text('智能识别并裁去扫描版四周纯白或纯黑留白，放大画面占比'),
              value: prefs.mangaCropMargins,
              onChanged: (val) =>
                  _update(context, prefs.copyWith(mangaCropMargins: val)),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('manga-tap-paging-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('点击边缘翻页'),
              subtitle: Text(
                prefs.mangaMode == MangaReadingMode.rtl
                    ? '日漫模式下点击左侧翻下一页，点击右侧翻上一页'
                    : '点击左右或上下边缘区域快速翻页',
              ),
              value: prefs.mangaTapPaging,
              onChanged: (val) =>
                  _update(context, prefs.copyWith(mangaTapPaging: val)),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('manga-volume-paging-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('音量键翻页'),
              value: prefs.volumePaging,
              onChanged: (val) =>
                  _update(context, prefs.copyWith(volumePaging: val)),
            ),
            if (canSwitchNormal) ...[
              const Divider(height: 20),
              OutlinedButton.icon(
                key: const ValueKey('manga-switch-normal-reader'),
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(CupertinoIcons.doc_richtext, size: 18),
                label: const Text('切换为常规阅读器'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _MangaVisualSheet extends StatelessWidget {
  const _MangaVisualSheet({required this.state});

  final LibraryState state;

  Future<void> _update(BuildContext context, ReaderPreferences next) async {
    try {
      await state.setReaderPreferences(next);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '画面设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.readerSettingsChanges,
    builder: (context, _) {
      final prefs = state.readerPreferences;
      final scheme = Theme.of(context).colorScheme;
      final dimPct = (prefs.mangaNightDim * 100).round();
      return SingleChildScrollView(
        key: const ValueKey('manga-visual-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '画面增强与护眼', code: 'MANGA / VISUAL'),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              key: const ValueKey('manga-dark-canvas-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('深色背景沉浸画布'),
              subtitle: const Text('使用深灰黑画布衬托画面，避免四周亮色刺眼'),
              value: prefs.mangaDarkCanvas,
              onChanged: (val) =>
                  _update(context, prefs.copyWith(mangaDarkCanvas: val)),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('manga-invert-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('反色模式'),
              subtitle: const Text('适合黑白线条漫画在暗光环境下翻转白底'),
              value: prefs.mangaInvert,
              onChanged: (val) =>
                  _update(context, prefs.copyWith(mangaInvert: val)),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('夜间降亮护眼遮罩'),
                Text(
                  dimPct == 0 ? '关闭' : '$dimPct%',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Slider(
              key: const ValueKey('manga-night-dim-slider'),
              value: prefs.mangaNightDim.clamp(0.0, 0.75),
              min: 0.0,
              max: 0.75,
              divisions: 15,
              activeColor: scheme.secondary,
              inactiveColor: scheme.outlineVariant,
              onChanged: (val) =>
                  _update(context, prefs.copyWith(mangaNightDim: val)),
            ),
            const Divider(height: 20),
            OutlinedButton.icon(
              key: const ValueKey('manga-open-paper-sheet'),
              onPressed: () {
                Navigator.pop(context);
                showReaderAppearanceSheet(context, state: state, pdf: true);
              },
              icon: const Icon(CupertinoIcons.sun_max, size: 18),
              label: const Text('纸张底色与暖光调节'),
            ),
          ],
        ),
      );
    },
  );
}

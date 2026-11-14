import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'book_import_limits.dart';
import 'local_comic.dart';
import 'local_mobi.dart';

typedef PreparedCloudBook = ({
  String name,
  Uint8List? epubBytes,
  Uint8List? cbzBytes,
  Uint8List? pdfBytes,
  Uint8List? rawTextBytes,
  String? text,
});

class PortableBookPreparer {
  const PortableBookPreparer._();

  static const int _maxSingleFileBytes = maxLocalArchiveBytes;
  static const int _maxZipTotalBytes = 1024 * 1024 * 1024;
  static const int _maxZipEntries = 256;

  static Future<List<PreparedCloudBook>> prepareFile(
    String name,
    String path,
  ) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (ext == 'cbr' || ext == 'rar') {
      throw const FormatException('暂不支持 RAR/CBR 压缩格式，请转换为 CBZ 或 ZIP 后导入');
    }
    if (ext == 'cb7' || ext == '7z') {
      throw const FormatException('暂不支持 7z/CB7 压缩格式，请转换为 CBZ 或 ZIP 后导入');
    }
    final file = File(path);
    final length = await file.length();
    if (length > _maxSingleFileBytes) {
      throw const FormatException('文件超过 512 MiB 大小限制');
    }
    final bytes = await file.readAsBytes();
    return Isolate.run(() => _prepareBytes(name, ext, bytes));
  }

  static PreparedCloudBook _book({
    required String name,
    Uint8List? epubBytes,
    Uint8List? cbzBytes,
    Uint8List? pdfBytes,
    Uint8List? rawTextBytes,
    String? text,
  }) => (
    name: name,
    epubBytes: epubBytes,
    cbzBytes: cbzBytes,
    pdfBytes: pdfBytes,
    rawTextBytes: rawTextBytes,
    text: text,
  );

  static List<PreparedCloudBook> _prepareBytes(
    String name,
    String ext,
    Uint8List bytes,
  ) {
    switch (ext) {
      case 'cbr':
      case 'rar':
        throw const FormatException('暂不支持 RAR/CBR 压缩格式，请转换为 CBZ 或 ZIP 后导入');
      case 'cb7':
      case '7z':
        throw const FormatException('暂不支持 7z/CB7 压缩格式，请转换为 CBZ 或 ZIP 后导入');
      case 'cbz':
        checkComicArchiveMagicBytes(bytes);
        final pkg = ComicArchivePackage.openBytes(bytes);
        pkg.close();
        return [_book(name: name, cbzBytes: bytes)];
      case 'epub':
        return [_book(name: name, epubBytes: bytes)];
      case 'pdf':
        return [_book(name: name, pdfBytes: bytes)];
      case 'mobi':
      case 'azw3':
      case 'azw':
      case 'prc':
        final mobi = extractMobiBook(bytes, fallbackTitle: name);
        final outName = mobi.author.isNotEmpty
            ? '${mobi.title} - ${mobi.author}.txt'
            : '${mobi.title}.txt';
        return [_book(name: outName, text: mobi.text)];
      case 'txt':
      case 'md':
      case 'markdown':
        return [_book(name: name, rawTextBytes: bytes)];
      case 'html':
      case 'htm':
      case 'xhtml':
        final doc = html_parser.parse(utf8.decode(bytes, allowMalformed: true));
        return [_book(name: name, text: doc.body?.text ?? doc.text ?? '')];
      case 'fb2':
        try {
          final xml = XmlDocument.parse(
            utf8.decode(bytes, allowMalformed: true),
          );
          final paragraphs = xml
              .findAllElements('p')
              .map((e) => e.innerText.trim())
              .where((s) => s.isNotEmpty)
              .join('\n\n');
          return [_book(name: name, text: paragraphs)];
        } catch (_) {
          return [_book(name: name, rawTextBytes: bytes)];
        }
      case 'docx':
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          final docEntry = archive.findFile('word/document.xml');
          if (docEntry == null ||
              docEntry.size < 0 ||
              docEntry.size > 64 * 1024 * 1024) {
            return const [];
          }
          final rawXml = docEntry.readBytes();
          if (rawXml == null || rawXml.length > 64 * 1024 * 1024) {
            return const [];
          }
          final xml = XmlDocument.parse(
            utf8.decode(rawXml, allowMalformed: true),
          );
          final lines = <String>[];
          for (final p in xml.descendants.whereType<XmlElement>().where(
            (e) => e.name.local == 'p',
          )) {
            final line = p.descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 't')
                .map((e) => e.innerText)
                .join()
                .trim();
            if (line.isNotEmpty) lines.add(line);
          }
          return [_book(name: name, text: lines.join('\n\n'))];
        } catch (_) {
          return const [];
        }
      case 'rtf':
        final raw = latin1.decode(bytes, allowInvalid: true);
        final stripped = raw
            .replaceAll(RegExp(r'\\par\b\s*'), '\n')
            .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d*\s?'), '')
            .replaceAll(RegExp(r'[{}]'), '');
        return [_book(name: name, text: stripped.trim())];
      case 'zip':
        checkComicArchiveMagicBytes(bytes);
        if (isComicZipBytes(bytes)) {
          final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
          return [_book(name: '$stem.cbz', cbzBytes: bytes)];
        }
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          final results = <PreparedCloudBook>[];
          var totalBytes = 0;
          var count = 0;
          for (final entry in archive) {
            if (!entry.isFile) continue;
            final entryName = entry.name.split('/').last;
            if (entryName.isEmpty || entryName.startsWith('.')) continue;
            final entryExt = entryName.contains('.')
                ? entryName.split('.').last.toLowerCase()
                : '';
            if (entryExt == 'zip') continue;
            if (++count > _maxZipEntries) break;
            if (entry.size < 0 ||
                entry.size > _maxSingleFileBytes ||
                totalBytes + entry.size > _maxZipTotalBytes) {
              break;
            }
            final entryBytes = entry.readBytes();
            if (entryBytes == null) continue;
            totalBytes += entryBytes.length;
            if (totalBytes > _maxZipTotalBytes) break;
            results.addAll(_prepareBytes(entryName, entryExt, entryBytes));
          }
          return results;
        } catch (_) {
          return const [];
        }
      default:
        return [_book(name: name, rawTextBytes: bytes)];
    }
  }
}

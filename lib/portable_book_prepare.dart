import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'local_mobi.dart';

typedef PreparedCloudBook = ({
  String name,
  Uint8List? epubBytes,
  Uint8List? rawTextBytes,
  String? text,
});

class PortableBookPreparer {
  const PortableBookPreparer._();

  static const int _maxSingleFileBytes = 256 * 1024 * 1024;
  static const int _maxZipTotalBytes = 1024 * 1024 * 1024;
  static const int _maxZipEntries = 256;

  static Future<List<PreparedCloudBook>> prepareFile(
    String name,
    String path,
  ) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final file = File(path);
    final length = await file.length();
    if (length > _maxSingleFileBytes) {
      throw const FormatException('文件超过 256 MiB 大小限制');
    }
    final bytes = await file.readAsBytes();
    return Isolate.run(() => _prepareBytes(name, ext, bytes));
  }

  static List<PreparedCloudBook> _prepareBytes(
    String name,
    String ext,
    Uint8List bytes,
  ) {
    switch (ext) {
      case 'epub':
        return [
          (name: name, epubBytes: bytes, rawTextBytes: null, text: null),
        ];
      case 'mobi':
      case 'azw3':
      case 'azw':
      case 'prc':
        final mobi = extractMobiBook(bytes, fallbackTitle: name);
        final outName = mobi.author.isNotEmpty
            ? '${mobi.title} - ${mobi.author}.txt'
            : '${mobi.title}.txt';
        return [
          (name: outName, epubBytes: null, rawTextBytes: null, text: mobi.text),
        ];
      case 'txt':
      case 'md':
      case 'markdown':
        return [
          (name: name, epubBytes: null, rawTextBytes: bytes, text: null),
        ];
      case 'html':
      case 'htm':
      case 'xhtml':
        final doc = html_parser.parse(utf8.decode(bytes, allowMalformed: true));
        return [
          (
            name: name,
            epubBytes: null,
            rawTextBytes: null,
            text: doc.body?.text ?? doc.text ?? '',
          ),
        ];
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
          return [
            (
              name: name,
              epubBytes: null,
              rawTextBytes: null,
              text: paragraphs,
            ),
          ];
        } catch (_) {
          return [
            (name: name, epubBytes: null, rawTextBytes: bytes, text: null),
          ];
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
          return [
            (
              name: name,
              epubBytes: null,
              rawTextBytes: null,
              text: lines.join('\n\n'),
            ),
          ];
        } catch (_) {
          return const [];
        }
      case 'rtf':
        final raw = latin1.decode(bytes, allowInvalid: true);
        final stripped = raw
            .replaceAll(RegExp(r'\\par\b\s*'), '\n')
            .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d*\s?'), '')
            .replaceAll(RegExp(r'[{}]'), '');
        return [
          (
            name: name,
            epubBytes: null,
            rawTextBytes: null,
            text: stripped.trim(),
          ),
        ];
      case 'zip':
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
        return [
          (name: name, epubBytes: null, rawTextBytes: bytes, text: null),
        ];
    }
  }
}

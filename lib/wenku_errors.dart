import 'dart:io';

import 'package:flutter/foundation.dart';

/// Returns a short diagnostic without embedding exception text, paths or URIs.
String describeSafeError(Object error, {String fallback = '操作失败，请重试'}) =>
    kDebugMode ? '${error.runtimeType}: $fallback' : fallback;

const _scanDetailEmpty = '文件为空';
const _scanDetailDecodeFailed = '解码失败';
const _scanDetailTooLarge = '文件过大';
const _scanDetailUnreadable = '文件不可读';
const _scanDetailFailed = '扫描失败';

const _safeScanStateMessages = <String>{
  '不支持加密的 EPUB',
  '不支持 RAR 压缩包（请先解压）',
  '不支持 7z 压缩包（请先解压）',
  '不支持含符号链接的 EPUB',
  'EPUB 解压后大小超过上限',
  '无效的 EPUB：缺少 META-INF/container.xml',
  '无效的 EPUB：找不到 OPF 文件',
  '无效的 EPUB：OPF 格式损坏',
  '无效的 EPUB：没有可读章节',
  'EPUB 缓存长度不一致，请重新扫描',
};

/// 扫描失败详情只返回固定类别文案，不带异常原文、路径或 URI。
String describeLocalScanError(Object error) {
  if (error is FormatException) {
    final message = error.message;
    if (message.startsWith('TXT ') ||
        message.startsWith('EPUB ') ||
        message == _scanDetailEmpty ||
        message == _scanDetailDecodeFailed ||
        message == _scanDetailTooLarge) {
      return message;
    }
    return _scanDetailDecodeFailed;
  }
  if (error is StateError && _safeScanStateMessages.contains(error.message)) {
    return error.message;
  }
  if (error is FileSystemException) return _scanDetailUnreadable;
  return _scanDetailFailed;
}

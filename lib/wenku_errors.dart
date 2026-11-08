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
  if (error is FileSystemException) return _scanDetailUnreadable;
  return _scanDetailFailed;
}

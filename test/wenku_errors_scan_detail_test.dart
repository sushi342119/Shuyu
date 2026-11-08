import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shuyu/wenku_errors.dart';

void main() {
  test('扫描失败详情只返回固定类别文案，不带路径或 URI', () {
    // 受控 FormatException 原样返回。
    expect(describeLocalScanError(const FormatException('TXT 文件为空')),
        'TXT 文件为空');
    expect(describeLocalScanError(const FormatException('TXT 解码失败')),
        'TXT 解码失败');
    expect(
        describeLocalScanError(
            const FormatException('TXT 文件过大：超过 256 MiB 导入上限')),
        contains('文件过大'));
    expect(
        describeLocalScanError(
            const FormatException('EPUB 文件超过 256 MiB，无法导入')),
        'EPUB 文件超过 256 MiB，无法导入');
    // 非受控 FormatException 归为解码失败，不带原文。
    expect(
        describeLocalScanError(
            const FormatException('Unexpected extension byte (at offset 3)')),
        '解码失败');
    // FileSystemException 一律归为文件不可读，不带路径或 osError。
    expect(
        describeLocalScanError(const FileSystemException(
            'denied', '/abs/x/0.txt', OSError('Permission denied', 13))),
        '文件不可读');
    // 受控 EPUB StateError 诊断文案原样返回，帮助定位加密或改后缀压缩包。
    expect(describeLocalScanError(StateError('不支持加密的 EPUB')), '不支持加密的 EPUB');
    expect(
      describeLocalScanError(StateError('不支持 RAR 压缩包（请先解压）')),
      '不支持 RAR 压缩包（请先解压）',
    );
    expect(
      describeLocalScanError(StateError('不支持 7z 压缩包（请先解压）')),
      '不支持 7z 压缩包（请先解压）',
    );
    expect(
      describeLocalScanError(StateError('无效的 EPUB：没有可读章节')),
      '无效的 EPUB：没有可读章节',
    );
    // 其他类型归为扫描失败，不带原文（含路径、URI 的也不带）。
    expect(describeLocalScanError(StateError('/abs/x/0.txt')), '扫描失败');
    expect(
        describeLocalScanError(Exception('content://a/b')), '扫描失败');
  });
}

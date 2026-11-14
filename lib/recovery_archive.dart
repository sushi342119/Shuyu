import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _recoveryFailures = <String, String>{};

Map<String, String> get recoveryFailures => Map.unmodifiable(_recoveryFailures);

void recordRecoveryFailure(String operation, Object error) {
  final message = '${error.runtimeType}: 恢复未完成，原记录已保留待重试';
  _recoveryFailures[operation] = message;
  debugPrint('$operation: $message');
}

const maxRecoveryArchiveEntries = 16;
const maxRecoveryRawChars = 64 * 1024;

String _truncateUtf16Safe(String input, int maxChars) {
  if (input.length <= maxChars) return input;
  var end = maxChars;
  if (end > 0) {
    final prev = input.codeUnitAt(end - 1);
    if (prev >= 0xD800 && prev <= 0xDBFF) end--;
  }
  return input.substring(0, end);
}

Future<void> archiveRecoveryRecord(
  SharedPreferences prefs,
  String key,
  Object raw, {
  required String reason,
  Map<String, Object?>? details,
}) async {
  try {
    final previous = prefs.get(key);
    final records = previous is List<String>
        ? List<String>.of(previous)
        : <String>[
            if (previous != null)
              jsonEncode({
                'raw': previous is String
                    ? _truncateUtf16Safe(previous, maxRecoveryRawChars)
                    : _truncateUtf16Safe('$previous', maxRecoveryRawChars),
                'reason': 'invalid_archive',
              }),
          ];
    var truncated = false;
    Object boundedRaw = raw;
    if (raw is String && raw.length > maxRecoveryRawChars) {
      boundedRaw = _truncateUtf16Safe(raw, maxRecoveryRawChars);
      truncated = true;
    } else if (raw is! String && raw is! num && raw is! bool) {
      String encoded;
      try {
        encoded = jsonEncode(raw);
      } catch (_) {
        encoded = '$raw';
      }
      if (encoded.length > maxRecoveryRawChars) {
        boundedRaw = _truncateUtf16Safe(encoded, maxRecoveryRawChars);
        truncated = true;
      }
    }
    records.add(
      jsonEncode({
        'raw': boundedRaw,
        if (truncated) 'truncated': true,
        'reason': reason,
        'details': ?details,
        'archivedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    if (records.length > maxRecoveryArchiveEntries) {
      records.removeRange(0, records.length - maxRecoveryArchiveEntries);
    }
    if (!await prefs.setStringList(key, records)) {
      throw StateError('恢复记录隔离失败：$key');
    }
    _recoveryFailures.remove(key);
  } catch (error) {
    recordRecoveryFailure(key, error);
    rethrow;
  }
}

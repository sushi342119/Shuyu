/// Detects regex patterns prone to catastrophic backtracking (ReDoS) or
/// excessive complexity before they can block the Dart isolate.
String? detectUnsafeRegexPattern(String pattern) {
  if (pattern.length > 512) {
    return '正则表达式过长，已禁用以防卡顿';
  }
  var inCharClass = false;
  // Each stack frame records (hasInnerQuantifier, alternationBranches).
  final groupStack = <(bool, List<StringBuffer>)>[];
  var wildcardRuns = 0;

  bool isRepeatingQuantifierAt(int index) {
    var i = index;
    while (i < pattern.length && (pattern[i] == ' ' || pattern[i] == '\t')) {
      i++;
    }
    if (i >= pattern.length) return false;
    final ch = pattern[i];
    if (ch == '+' || ch == '*') return true;
    if (ch == '{') {
      final close = pattern.indexOf('}', i + 1);
      if (close > i + 1) {
        final spec = pattern.substring(i + 1, close).trim();
        final parts = spec.split(',');
        if (parts.length == 1) {
          final exact = int.tryParse(parts[0].trim());
          return exact != null && exact > 1;
        }
        if (parts.length == 2) {
          final maxPart = parts[1].trim();
          if (maxPart.isEmpty) return true;
          final upper = int.tryParse(maxPart);
          return upper != null && upper > 1;
        }
      }
    }
    return false;
  }

  bool hasOverlappingAlternation(List<StringBuffer> branches) {
    if (branches.length < 2) return false;
    final nonEmpty = [for (final b in branches) b.toString()];
    for (var a = 0; a < nonEmpty.length; a++) {
      for (var b = a + 1; b < nonEmpty.length; b++) {
        final left = nonEmpty[a];
        final right = nonEmpty[b];
        if (left.isEmpty || right.isEmpty) return true;
        if (left.startsWith(right) || right.startsWith(left)) return true;
      }
    }
    return false;
  }

  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    if (ch == r'\') {
      if (!inCharClass && i + 1 < pattern.length) {
        final esc = pattern[i + 1];
        if (groupStack.isNotEmpty) {
          groupStack.last.$2.last.write('\\$esc');
        }
        if ((esc == 's' || esc == 'S' || esc == 'w' || esc == 'W') &&
            isRepeatingQuantifierAt(i + 2)) {
          wildcardRuns++;
        }
      }
      i++;
      continue;
    }
    if (inCharClass) {
      if (ch == ']') inCharClass = false;
      continue;
    }
    if (ch == '[') {
      inCharClass = true;
      if (groupStack.isNotEmpty) groupStack.last.$2.last.write('[');
      continue;
    }
    if (ch == '(') {
      if (i + 1 < pattern.length && pattern[i + 1] == '?') {
        var j = i + 2;
        while (j < pattern.length && 'ims'.contains(pattern[j])) {
          j++;
        }
        if (j < pattern.length && pattern[j] == ')') {
          i = j;
          continue;
        }
        if (i + 2 < pattern.length &&
            (pattern[i + 2] == ':' ||
                pattern[i + 2] == '=' ||
                pattern[i + 2] == '!')) {
          groupStack.add((false, [StringBuffer()]));
          i += 2;
          continue;
        }
      }
      groupStack.add((false, [StringBuffer()]));
      continue;
    }
    if (ch == '|' && groupStack.isNotEmpty) {
      groupStack.last.$2.add(StringBuffer());
      wildcardRuns = 0;
      continue;
    }
    if (ch == ')' && groupStack.isNotEmpty) {
      final (hasQuant, branches) = groupStack.removeLast();
      final repeatedOuter = isRepeatingQuantifierAt(i + 1);
      if (repeatedOuter && (hasQuant || hasOverlappingAlternation(branches))) {
        return '正则表达式存在灾难性回溯风险，已自动禁用';
      }
      if (groupStack.isNotEmpty && (hasQuant || repeatedOuter)) {
        final parent = groupStack.removeLast();
        groupStack.add((true, parent.$2));
      }
      continue;
    }
    if (ch == '.' && isRepeatingQuantifierAt(i + 1)) {
      wildcardRuns++;
      if (wildcardRuns >= 2) {
        return '正则表达式存在灾难性回溯风险，已自动禁用';
      }
    }
    if ((ch == '+' || ch == '*' || ch == '{') && groupStack.isNotEmpty) {
      if (ch != '{' || isRepeatingQuantifierAt(i)) {
        final parent = groupStack.removeLast();
        groupStack.add((true, parent.$2));
      }
    } else if (groupStack.isNotEmpty && ch != '?') {
      groupStack.last.$2.last.write(ch);
    }
  }
  return null;
}

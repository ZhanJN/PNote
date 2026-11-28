import 'package:flutter/painting.dart';

/// 1.65 代码块高亮：一个不依赖任何插件的轻量着色器。
///
/// 只做「看得出是代码」的那一档：注释、字符串、数字、常见关键字各一种颜色，
/// 其余文字保持正文色。不做语法分析，也不判断上下文，换来的是几十行代码、
/// 零依赖、任何语言都不会挂。
class CodeHighlightColors {
  const CodeHighlightColors({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
  });

  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
}

const Map<String, Set<String>> _keywordSets = {
  'dart': {
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
    'dynamic', 'else', 'enum', 'extends', 'extension', 'factory', 'false',
    'final', 'finally', 'for', 'get', 'if', 'implements', 'import', 'in',
    'interface', 'is', 'late', 'library', 'mixin', 'new', 'null', 'on',
    'operator', 'part', 'required', 'rethrow', 'return', 'sealed', 'set',
    'show', 'static', 'super', 'switch', 'sync', 'this', 'throw', 'true',
    'try', 'typedef', 'var', 'void', 'when', 'while', 'with', 'yield',
  },
  'js': {
    'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
    'debugger', 'default', 'delete', 'do', 'else', 'export', 'extends',
    'false', 'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof',
    'let', 'new', 'null', 'of', 'return', 'static', 'super', 'switch', 'this',
    'throw', 'true', 'try', 'typeof', 'undefined', 'var', 'void', 'while',
    'with', 'yield',
  },
  'python': {
    'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
    'def', 'del', 'elif', 'else', 'except', 'False', 'finally', 'for', 'from',
    'global', 'if', 'import', 'in', 'is', 'lambda', 'None', 'nonlocal', 'not',
    'or', 'pass', 'raise', 'return', 'True', 'try', 'while', 'with', 'yield',
  },
  'sql': {
    'ALTER', 'AND', 'AS', 'ASC', 'BEGIN', 'BETWEEN', 'BY', 'CASE', 'COMMIT',
    'CREATE', 'DELETE', 'DESC', 'DISTINCT', 'DROP', 'ELSE', 'END', 'EXISTS',
    'FROM', 'GROUP', 'HAVING', 'IN', 'INDEX', 'INNER', 'INSERT', 'INTO', 'IS',
    'JOIN', 'LEFT', 'LIKE', 'LIMIT', 'NOT', 'NULL', 'ON', 'OR', 'ORDER',
    'OUTER', 'PRIMARY', 'RIGHT', 'ROLLBACK', 'SELECT', 'SET', 'TABLE', 'THEN',
    'UNION', 'UPDATE', 'VALUES', 'WHEN', 'WHERE',
  },
  'sh': {
    'case', 'do', 'done', 'elif', 'else', 'esac', 'fi', 'for', 'function',
    'if', 'in', 'return', 'then', 'until', 'while',
  },
  'json': {'true', 'false', 'null'},
  'yaml': {'true', 'false', 'null', 'yes', 'no', 'on', 'off'},
};

const Set<String> _genericKeywords = {
  'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do',
  'else', 'enum', 'false', 'final', 'finally', 'for', 'if', 'import', 'in',
  'new', 'null', 'private', 'protected', 'public', 'return', 'static',
  'switch', 'this', 'throw', 'true', 'try', 'void', 'while',
};

/// 这些语言的 `#` 是注释；SQL 的 `--` 单独判断。
const Set<String> _hashCommentLanguages = {
  'python', 'sh', 'yaml', 'toml', 'ruby', 'perl', 'r',
};

/// 把一段代码切成带颜色的 [TextSpan]；拼接起来的文字与原代码逐字相同。
List<TextSpan> highlightCode(
  String code,
  String language, {
  required TextStyle style,
  required CodeHighlightColors colors,
}) {
  final spans = <TextSpan>[];
  final lang = _normalizeLanguage(language);
  final keywords = _keywordSets[lang] ?? _genericKeywords;
  final hashComments = _hashCommentLanguages.contains(lang);
  final sqlComments = lang == 'sql';

  final plain = StringBuffer();
  void flushPlain() {
    if (plain.isEmpty) return;
    spans.add(TextSpan(text: plain.toString(), style: style));
    plain.clear();
  }

  void addColored(String text, Color color) {
    flushPlain();
    spans.add(TextSpan(text: text, style: style.copyWith(color: color)));
  }

  var i = 0;
  final length = code.length;
  while (i < length) {
    final char = code[i];

    // 行注释：//、#（部分语言）、--（SQL）
    if ((char == '/' && i + 1 < length && code[i + 1] == '/') ||
        (char == '#' && hashComments) ||
        (sqlComments && char == '-' && i + 1 < length && code[i + 1] == '-')) {
      final end = code.indexOf('\n', i);
      final stop = end == -1 ? length : end;
      addColored(code.substring(i, stop), colors.comment);
      i = stop;
      continue;
    }

    // 块注释：/* … */
    if (char == '/' && i + 1 < length && code[i + 1] == '*') {
      final end = code.indexOf('*/', i + 2);
      final stop = end == -1 ? length : end + 2;
      addColored(code.substring(i, stop), colors.comment);
      i = stop;
      continue;
    }

    // 字符串：单引号 / 双引号 / 反引号
    if (char == '"' || char == "'" || char == '`') {
      var j = i + 1;
      var escaped = false;
      while (j < length) {
        final c = code[j];
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == char) {
          j++;
          break;
        } else if (c == '\n' && char != '`') {
          break;
        }
        j++;
      }
      addColored(code.substring(i, j), colors.string);
      i = j;
      continue;
    }

    // 数字
    if (_isDigit(char)) {
      var j = i + 1;
      while (j < length && (_isDigit(code[j]) || code[j] == '.')) {
        j++;
      }
      addColored(code.substring(i, j), colors.number);
      i = j;
      continue;
    }

    // 标识符 / 关键字
    if (_isIdentifierStart(char)) {
      var j = i + 1;
      while (j < length && _isIdentifierPart(code[j])) {
        j++;
      }
      final word = code.substring(i, j);
      if (keywords.contains(word) || keywords.contains(word.toUpperCase())) {
        addColored(word, colors.keyword);
      } else {
        plain.write(word);
      }
      i = j;
      continue;
    }

    plain.write(char);
    i++;
  }
  flushPlain();
  return spans;
}

String _normalizeLanguage(String language) {
  switch (language.trim().toLowerCase()) {
    case 'js':
    case 'javascript':
    case 'jsx':
    case 'ts':
    case 'typescript':
    case 'tsx':
      return 'js';
    case 'py':
      return 'python';
    case 'bash':
    case 'shell':
    case 'zsh':
      return 'sh';
    case 'yml':
      return 'yaml';
    default:
      return language.trim().toLowerCase();
  }
}

bool _isDigit(String char) {
  final code = char.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}

bool _isIdentifierStart(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      char == '_' ||
      char == r'$';
}

bool _isIdentifierPart(String char) =>
    _isIdentifierStart(char) || _isDigit(char);

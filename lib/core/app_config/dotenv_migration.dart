/// A note about something the migration could not change automatically.
class MigrationNote {
  const MigrationNote(this.line, this.message, {this.blocking = false});

  final int line;
  final String message;

  /// True when leaving it as-is would break the app after migrating
  /// (e.g. a `dotenv.load()` that would throw once .env is no longer bundled).
  final bool blocking;
}

class MigrationResult {
  MigrationResult(this.source, this.changes, this.notes);

  final String source;
  final List<String> changes;
  final List<MigrationNote> notes;

  bool get changed => changes.isNotEmpty;
  bool get blocked => notes.any((n) => n.blocking);
}

/// Rewrites flutter_dotenv usages in one Dart file to the generated config
/// class. Only mechanical, behaviour-preserving edits are made; everything
/// else is reported for a human to handle.
class DotenvMigration {
  const DotenvMigration._();

  /// Members that behave the same on the generated class.
  static const compatibleMembers = [
    'env',
    'get',
    'maybeGet',
    'getInt',
    'getDouble',
    'getBool',
    'isEveryDefined',
    'isInitialized',
  ];

  static final _import = RegExp(
      r'''^[ \t]*import[ \t]+['"]package:flutter_dotenv/flutter_dotenv\.dart['"]([^;]*);[ \t]*\r?\n?''',
      multiLine: true);
  static final _member =
      RegExp('(?<![\\w.\$])dotenv\\.(${compatibleMembers.join('|')})\\b');
  static final _anyDotenv = RegExp(r'(?<![\w.$])dotenv\.(\w+)');
  static final _mutation = RegExp(
      r'''(?<![\w.$])dotenv\.env\s*(\[[^\]]*\]\s*(=(?!=)|\?\?=|\+=)|\.(addAll|remove|clear|putIfAbsent|update)\b)''');
  static final _dotEnvClass = RegExp(r'\bDotEnv\s*\(');

  static final _literalRead = RegExp(
      r'''(?<![\w.$])dotenv\.(?:env\s*\[|(?:get|maybeGet|getInt|getDouble|getBool)\s*\()\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1''');
  static final _dynamicRead = RegExp(
      r'''(?<![\w.$])dotenv\.(?:env\s*\[|(?:get|maybeGet|getInt|getDouble|getBool)\s*\()\s*(?!['"])''');
  static final _everyDefined =
      RegExp(r'(?<![\w.$])dotenv\.isEveryDefined\s*\(');
  static final _wholeEnv = RegExp(r'(?<![\w.$])dotenv\.env(?!\s*\[)\b');

  /// The .env keys [source] reads by literal name, whether it also reads
  /// keys it computes at runtime (then no complete allow-list can be
  /// proven), and every KEY_LIKE string literal in it, which is how computed
  /// keys are usually spelled (e.g. a switch returning 'CONNECTION_STRING_PROD').
  static ({Set<String> keys, bool dynamic, Set<String> literals}) scanKeys(
      String source) {
    final literals = RegExp(r'''(['"])([A-Z][A-Z0-9_]*)\1''')
        .allMatches(source)
        .map((m) => m.group(2)!)
        .toSet();
    final keys =
        _literalRead.allMatches(source).map((m) => m.group(2)!).toSet();
    final dynamic = _dynamicRead.hasMatch(source) ||
        _everyDefined.hasMatch(source) ||
        _wholeEnv.hasMatch(source);
    return (keys: keys, dynamic: dynamic, literals: literals);
  }

  static MigrationResult migrateSource(
    String source, {
    required String className,
    required String importUri,
  }) {
    final notes = <MigrationNote>[];
    final changes = <String>[];
    int lineOf(int index) =>
        '\n'.allMatches(source.substring(0, index)).length + 1;

    final imports = _import.allMatches(source).toList();
    if (imports.isEmpty && !_anyDotenv.hasMatch(source)) {
      return MigrationResult(source, changes, notes);
    }

    // Cases that need a human; the file is left untouched.
    for (final m in imports) {
      if (RegExp(r'\bas\s+\w+').hasMatch(m.group(1) ?? '')) {
        notes.add(MigrationNote(lineOf(m.start),
            'flutter_dotenv is imported with a prefix; update this file by hand.',
            blocking: true));
      }
    }
    for (final m in _mutation.allMatches(source)) {
      notes.add(MigrationNote(lineOf(m.start),
          'Code writes to dotenv.env; the generated values are constant. Update by hand.',
          blocking: true));
    }
    if (notes.any((n) => n.blocking))
      return MigrationResult(source, changes, notes);

    var out = source;

    // 1. `await dotenv.load(...);` statements are no longer needed.
    out = _removeLoads(out, className, changes, notes, lineOf);

    // 2. Compatible members become the generated class.
    final memberCount = _member.allMatches(out).length;
    if (memberCount > 0) {
      out = out.replaceAllMapped(_member, (m) => '$className.${m.group(1)}');
      changes.add(
          '$memberCount dotenv usage${memberCount == 1 ? '' : 's'} → $className');
    }

    // 3. What's left can't be translated automatically.
    for (final m in _anyDotenv.allMatches(out)) {
      final member = m.group(1)!;
      if (member == 'load') continue; // already reported by _removeLoads
      final hint =
          member == 'testLoad' ? ' (tests can read $className directly)' : '';
      notes.add(MigrationNote(lineOf(source.indexOf(m.group(0)!)),
          'dotenv.$member has no compiled equivalent; update by hand$hint.'));
    }
    for (final m in _dotEnvClass.allMatches(out)) {
      notes.add(MigrationNote(lineOf(m.start < source.length ? m.start : 0),
          'A DotEnv() instance is created here; switch it to $className by hand.'));
    }
    out = _removeUnusedClientEnvConstant(out, changes, notes, lineOf, source);

    if (!changes.isNotEmpty) return MigrationResult(source, changes, notes);

    // 4. Imports: add the generated file, drop flutter_dotenv when unused.
    if (!out.contains(importUri)) {
      out = _addImport(out, importUri);
      changes.add("import '$importUri'");
    }
    final withoutImports = out.replaceAll(_import, '');
    if (!RegExp(r'(?<![\w$])(dotenv|DotEnv)\b').hasMatch(withoutImports)) {
      final before = out;
      out = out.replaceAll(_import, '');
      if (out != before) changes.add('removed the flutter_dotenv import');
    }
    return MigrationResult(out, changes, notes);
  }

  static String _removeLoads(String src, String className, List<String> changes,
      List<MigrationNote> notes, int Function(int) lineOf) {
    final load = RegExp(r'(?<![\w.$])dotenv\.load\s*\(');
    var out = src;
    var removed = 0;
    var searchFrom = 0;
    while (true) {
      final m = load.firstMatch(out.substring(searchFrom));
      if (m == null) break;
      final start = searchFrom + m.start;
      final close = _matchingParen(out, searchFrom + m.end - 1);
      if (close < 0) break;

      // Statement start: optional `await`, then only whitespace back to the
      // start of the line.
      var stmtStart = start;
      final beforeCall = out.substring(0, start);
      final awaitMatch = RegExp(r'await\s+$').firstMatch(beforeCall);
      if (awaitMatch != null) stmtStart = awaitMatch.start;
      final lineStart = out.lastIndexOf('\n', stmtStart - 1) + 1;
      final isStatementStart =
          out.substring(lineStart, stmtStart).trim().isEmpty;

      var end = close + 1;
      while (end < out.length && (out[end] == ' ' || out[end] == '\t')) {
        end++;
      }
      final isStatementEnd = end < out.length && out[end] == ';';

      if (isStatementStart && isStatementEnd) {
        final replacement =
            '// $className: values are compiled in, nothing to load.';
        out = out.replaceRange(stmtStart, end + 1, replacement);
        removed++;
        searchFrom = stmtStart + replacement.length;
      } else {
        // Part of a bigger expression (e.g. `.then(...)`): leave it for a human.
        notes.add(MigrationNote(
            lineOf(src.indexOf(out.substring(start, close + 1))),
            'dotenv.load() is part of a larger expression; remove it by hand '
            '(.env is no longer bundled, so it would fail at startup).',
            blocking: true));
        searchFrom = close + 1;
      }
    }
    if (removed > 0)
      changes
          .add('removed $removed dotenv.load() call${removed == 1 ? '' : 's'}');
    return out;
  }

  /// `const envFile = String.fromEnvironment('CLIENT_ENV', ...);` only fed
  /// dotenv.load(). Once that is gone, drop the declaration if nothing else
  /// reads it (otherwise it would be an unused-variable warning); if
  /// something still does, leave it and say so.
  static String _removeUnusedClientEnvConstant(String out, List<String> changes,
      List<MigrationNote> notes, int Function(int) lineOf, String original) {
    final decl = RegExp(
        r'''^[ \t]*(?:const|final|var)\s+(?:String\s+)?(\w+)\s*=\s*(?:const\s+)?String\.fromEnvironment\(\s*['"]CLIENT_ENV['"]''',
        multiLine: true);
    final m = decl.firstMatch(out);
    if (m == null) return out;
    final name = m.group(1)!;
    final open = out.indexOf('String.fromEnvironment(', m.start) +
        'String.fromEnvironment'.length;
    final close = _matchingParen(out, open);
    if (close < 0) return out;
    var end = close + 1;
    while (end < out.length &&
        (out[end] == ' ' ||
            out[end] == '\t' ||
            out[end] == '\n' ||
            out[end] == '\r')) {
      if (out[end] == ';') break;
      end++;
    }
    if (end >= out.length || out[end] != ';') return out;

    final rest = out.substring(0, m.start) + out.substring(end + 1);
    if (RegExp('(?<![\\w\$])${RegExp.escape(name)}(?![\\w\$])')
        .hasMatch(rest)) {
      notes.add(MigrationNote(lineOf(original.indexOf(m.group(0)!.trim())),
          'The CLIENT_ENV constant "$name" is still used; it no longer selects a config.'));
      return out;
    }
    // Remove the whole declaration, including its line break.
    var lineEnd = end + 1;
    if (lineEnd < out.length && out[lineEnd] == '\r') lineEnd++;
    if (lineEnd < out.length && out[lineEnd] == '\n') lineEnd++;
    changes.add('removed the unused CLIENT_ENV constant "$name"');
    return out.substring(0, m.start) + out.substring(lineEnd);
  }

  /// Index of the parenthesis closing the one at [open], skipping strings.
  static int _matchingParen(String s, int open) {
    var depth = 0;
    String? quote;
    for (var i = open; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == '\\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static String _addImport(String src, String uri) {
    final line = "import '$uri';\n";
    final directives = RegExp(
            r'''^(import|export)\s+['"][^'"]+['"][^;]*;[ \t]*\r?\n''',
            multiLine: true)
        .allMatches(src)
        .toList();
    if (directives.isNotEmpty) {
      // Keep package imports together (directives_ordering): after the last
      // package: import when there is one.
      final packageImports = directives.where((d) =>
          d.group(0)!.contains("'package:") ||
          d.group(0)!.contains('"package:'));
      final at =
          (packageImports.isNotEmpty ? packageImports.last : directives.last)
              .end;
      return src.substring(0, at) + line + src.substring(at);
    }
    final library =
        RegExp(r'^library\b[^;]*;[ \t]*\r?\n', multiLine: true).firstMatch(src);
    if (library != null) {
      return '${src.substring(0, library.end)}\n$line${src.substring(library.end)}';
    }
    return '$line\n$src';
  }
}

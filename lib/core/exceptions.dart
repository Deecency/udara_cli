import 'dart:io';

class BuildException implements Exception {
  BuildException(
    this.message, {
    this.fix,
    this.originalStackTrace,
  });

  final String message;
  final String? fix;
  final StackTrace? originalStackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('BuildException: $message');
    if (fix != null) buffer.write('\n💡 Suggested Fix: $fix');
    return buffer.toString();
  }
}

/// Centralized logging so build output is scannable and failures are
/// easy to pinpoint. Replaces ad-hoc `print()` calls throughout the CLI.

class Logger {
  static bool verbose = false;

  static const _reset = '\x1B[0m';
  static const _red = '\x1B[31m';
  static const _yellow = '\x1B[33m';
  static const _green = '\x1B[32m';
  static const _bold = '\x1B[1m';

  static bool get _colorEnabled => stdout.supportsAnsiEscapes;

  static String _c(String text, String color) =>
      _colorEnabled ? '$color$text$_reset' : text;

  static void phase(String name) {
    stdout.writeln('\n${_c('═══ $name ═══', _bold)}');
  }

  static void info(String message) => stdout.writeln('  $message');

  static void success(String message) =>
      stdout.writeln('  ${_c('SUCCESS', _green)} $message');

  static void warning(String message) =>
      stdout.writeln('  ${_c('WARNING', _yellow)} $message');

  static void error(
    String message, {
    Object? cause,
    StackTrace? stackTrace,
  }) {
    stderr.writeln('\n${_c('ERROR', _red)} $message');
    if (cause != null) {
      stderr.writeln('  ${_c('FIX', _yellow)} $cause');
    }
    if (verbose && stackTrace != null) {
      stderr.writeln('\n  STACK TRACE:\n$stackTrace');
    }
  }
}

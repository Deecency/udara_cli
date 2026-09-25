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
  /// Enabled by the global `--verbose` flag. Prints stack traces on errors
  /// and turns on Slack debug output.
  static bool verbose = false;

  /// When true, informational output goes to stderr so stdout stays a
  /// clean machine-readable stream (used by the `--json` flags).
  static bool jsonMode = false;

  static IOSink get _out => jsonMode ? stderr : stdout;

  static const _reset = '\x1B[0m';
  static const _red = '\x1B[31m';
  static const _yellow = '\x1B[33m';
  static const _green = '\x1B[32m';
  static const _dim = '\x1B[2m';
  static const _bold = '\x1B[1m';

  static String _c(String text, String color, {IOSink? sink}) {
    final supportsColor = identical(sink, stderr)
        ? stderr.supportsAnsiEscapes
        : stdout.supportsAnsiEscapes;
    return supportsColor ? '$color$text$_reset' : text;
  }

  static void phase(String name) {
    _out.writeln('\n${_c('═══ $name ═══', _bold)}');
  }

  static void info(String message) => _out.writeln('  $message');

  /// Only printed when [verbose] is on.
  static void debug(String message) {
    if (verbose) _out.writeln('  ${_c(message, _dim)}');
  }

  static void success(String message) =>
      _out.writeln('  ${_c('SUCCESS', _green)} $message');

  static void warning(String message) =>
      _out.writeln('  ${_c('WARNING', _yellow)} $message');

  static void error(
    String message, {
    Object? cause,
    StackTrace? stackTrace,
  }) {
    stderr.writeln('\n${_c('ERROR', _red, sink: stderr)} $message');
    if (cause != null) {
      stderr.writeln('  ${_c('FIX', _yellow, sink: stderr)} $cause');
    }
    if (verbose && stackTrace != null) {
      stderr.writeln('\n  STACK TRACE:\n$stackTrace');
    }
  }
}

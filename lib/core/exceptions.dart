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

  static void phase(String name) {
    stdout.writeln('\n═══ $name ═══');
  }

  static void info(String message) => stdout.writeln('  ℹ️  $message');

  static void success(String message) => stdout.writeln('  ✅ $message');

  static void warning(String message) => stdout.writeln('  ⚠️  $message');

  /// Fatal-level error. Always goes to stderr so it's distinguishable
  /// from normal build output.
  static void error(
    String message, {
    Object? cause,
    StackTrace? stackTrace,
  }) {
    stderr.writeln('\n❌ ERROR: $message');
    if (cause != null) {
      stderr.writeln('  💡 FIX / REASON: $cause');
    }
    if (verbose && stackTrace != null) {
      stderr.writeln('\n  🔍 STACK TRACE:\n$stackTrace');
    }
  }
}

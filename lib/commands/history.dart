import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

/// Displays and manages the project-local build history recorded by
/// [BuildCommand] on every run (success or failure).
class HistoryCommand extends UdaraCommand {
  HistoryCommand() {
    argParser
      ..addOption(
        'client',
        abbr: 'c',
        help: 'Only show history for a specific client.',
      )
      ..addOption(
        'limit',
        abbr: 'n',
        defaultsTo: '10',
        help: 'Number of most recent builds to show.',
      )
      ..addFlag(
        'clear',
        negatable: false,
        help: 'Clear all recorded build history for this project.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Print history entries as JSON.',
      );
  }

  @override
  final String name = 'history';

  @override
  final String description = '''View recent build history for this project.

  USAGE:
  udara_cli history [OPTIONS]

  EXAMPLES:
  # Show the 10 most recent builds
  udara_cli history

  # Show the last 25 builds for a specific client
  udara_cli history --client apple --limit 25

  # Clear all recorded history
  udara_cli history --clear

Each build (success or failure) is automatically recorded to
".udara_build_history.json" in the project root. Only the most recent
50 entries are kept.''';

  late ConfigService config;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);

    final shouldClear = argResults!['clear'] as bool;
    if (shouldClear) {
      await _clearHistory();
      return;
    }

    final clientFilter = argResults!['client'] as String?;
    Logger.jsonMode = argResults!['json'] as bool;
    final limitArg = argResults!['limit'] as String;
    final limit = int.tryParse(limitArg);
    if (limit == null || limit <= 0) {
      throw UsageException(
          '--limit must be a positive integer (got "$limitArg").', usage);
    }

    var entries = await config.loadBuildHistory();

    if (clientFilter != null) {
      entries = entries.where((e) => e['client'] == clientFilter).toList();
    }

    if (argResults!['json'] as bool) {
      stdout.writeln(const JsonEncoder.withIndent('  ')
          .convert(entries.take(limit).toList()));
      return;
    }

    if (entries.isEmpty) {
      Logger.info(
          'No build history recorded yet. Run "udara_cli build" to create some.');
      return;
    }

    Logger.phase('Build History (showing ${entries.length.clamp(0, limit)} '
        'of ${entries.length})');

    for (final entry in entries.take(limit)) {
      _printEntry(entry);
    }
  }

  void _printEntry(Map<String, dynamic> entry) {
    final client = entry['client'] ?? 'unknown';
    final platform = entry['platform'] ?? 'unknown';
    final type = entry['type'] ?? 'unknown';
    final version = entry['version'] ?? 'unknown';
    final success = entry['success'] == true;
    final durationSeconds = entry['durationSeconds'] as int? ?? 0;
    final timestamp = DateTime.tryParse(entry['timestamp'] as String? ?? '');
    final formattedTime =
        timestamp != null ? _formatTimestamp(timestamp) : 'unknown time';

    final summary =
        '$client • $platform/$type • v$version • ${durationSeconds}s • $formattedTime';

    if (success) {
      Logger.success(summary);
      final artifact = entry['artifact'] as String?;
      if (artifact != null) {
        Logger.info('    ${p.relative(artifact, from: projectDir)}');
      }
    } else {
      Logger.error(summary, cause: entry['error'] as String?);
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _clearHistory() async {
    final cleared = await config.clearBuildHistory();
    if (cleared) {
      Logger.success('Build history cleared.');
    } else {
      Logger.info('No build history to clear.');
    }
  }
}

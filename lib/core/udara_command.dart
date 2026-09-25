import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

/// Environment keys every client env file must define for a build.
const requiredEnvKeys = [
  'APP_NAME_PROD',
  'BUNDLE_ID',
  'ASSETS_PATH',
  'APP_ICON_PATH',
];

abstract class UdaraCommand extends Command<void> {
  final String projectDir = Directory.current.path;

  Directory get clientsDir => Directory(p.join(projectDir, 'clients'));

  /// Runs a shell command in the project directory with structured logging
  /// and exception contextualization.
  Future<void> runShell(String command, {String? workingDir}) async {
    Logger.info('Running shell command: `$command`');
    try {
      await Shell(
        workingDirectory: workingDir ?? projectDir,
      ).run(command);
    } catch (e, s) {
      throw BuildException(
        'Failed to execute command: `$command`',
        fix:
            'Review the terminal logs above to see specific output from Flutter/Dart tools.',
        originalStackTrace: s,
      );
    }
  }

  /// Wraps a unit of work in consistent logging and exception translation.
  Future<T> runStep<T>(String description, Future<T> Function() action) async {
    Logger.info('Running: $description...');
    try {
      return await action();
    } on BuildException {
      rethrow;
    } catch (e, s) {
      throw BuildException(
        'Failed step: "$description" ($e)',
        fix: 'Check task logs above or underlying system prerequisites.',
        originalStackTrace: s,
      );
    }
  }

  /// Returns the sorted names of every client directory, or an empty list
  /// when the `clients` directory does not exist.
  Future<List<String>> listClientNames() async {
    if (!clientsDir.existsSync()) return [];
    final names = <String>[];
    await for (final entity in clientsDir.list()) {
      if (entity is Directory) names.add(p.basename(entity.path));
    }
    return names..sort();
  }

  /// Resolves the env file for [client], failing with a helpful message
  /// (including the list of known clients) when the client or file is missing.
  Future<File> resolveClientEnvFile(String client,
      {bool isTest = false}) async {
    if (client.trim().isEmpty ||
        client.contains('/') ||
        client.contains('\\') ||
        client == '.' ||
        client == '..') {
      throw BuildException(
        'Invalid client name "$client".',
        fix: 'Client names must match a folder directly under "clients/".',
      );
    }

    final clientDir = Directory(p.join(clientsDir.path, client));
    if (!clientDir.existsSync()) {
      final known = await listClientNames();
      final hint = known.isEmpty
          ? 'No clients exist yet. Run "udara_cli setup --clients $client".'
          : 'Available clients: ${known.join(', ')}. '
              'Run "udara_cli setup --clients $client" to create it.';
      throw BuildException('Client "$client" not found.', fix: hint);
    }

    final envFileName = isTest ? '.env_test' : '.env';
    final envFile = File(p.join(clientDir.path, envFileName));
    if (!envFile.existsSync()) {
      throw BuildException(
        'Environment file missing for client "$client": $envFileName',
        fix: 'Create "${envFile.path}" or run '
            '"udara_cli setup --clients $client" to generate a template.',
      );
    }
    return envFile;
  }

  /// Fails when any of [requiredEnvKeys] is missing or blank in [vars].
  void validateEnvVariables(
      String client, String file, Map<String, String> vars) {
    final missing = requiredEnvKeys
        .where((key) => (vars[key] ?? '').trim().isEmpty)
        .toList();

    if (missing.isNotEmpty) {
      throw BuildException(
        'Missing required variables in $file for client "$client": ${missing.join(', ')}',
        fix: 'Add ${missing.join(', ')} to clients/$client/$file '
            '(run "udara_cli doctor --client $client" for a full check).',
      );
    }
  }

  /// Fails early when files the pipeline depends on are absent, pointing at
  /// the command that creates them instead of failing mid-build.
  void checkProjectPrerequisites() {
    final pubspec = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found at "$projectDir".',
        fix: 'Run this command from the root of your Flutter project.',
      );
    }

    final icons = File(p.join(projectDir, 'flutter_launcher_icons.yaml'));
    if (!icons.existsSync()) {
      throw BuildException(
        'flutter_launcher_icons.yaml not found at project root.',
        fix: 'Run "udara_cli setup" to generate it, then '
            '"udara_cli doctor" to verify the project.',
      );
    }
  }

  /// Restores the project if a previous build or whitelabel was interrupted
  /// (its `.udara` backups still exist). Without this, the stale backups
  /// would be restored by this run's cleanup, silently reverting part of the
  /// new client's branding.
  Future<void> recoverInterruptedRun(CleanupService cleanup) async {
    if (!Directory(p.join(projectDir, '.udara')).existsSync()) return;
    Logger.warning('Found leftover state from an interrupted run. '
        'Restoring the project before continuing...');
    await cleanup.performFullCleanup();
  }

  /// Builds a [SlackService] from the stored bot token, or returns null
  /// (with a warning) when Slack has not been configured.
  Future<SlackService?> initializeSlackService(String channel) async {
    final slackToken = await ConfigService.getSlackBotToken();

    if (slackToken == null || slackToken.isEmpty) {
      Logger.warning(
          'Slack notifications disabled (not configured). Run "udara_cli setup --notify" to enable.');
      return null;
    }

    Logger.info('Slack notifications enabled for channel: $channel');
    return SlackService(
      botToken: slackToken,
      channel: channel,
      debugMode: Logger.verbose,
    );
  }

  /// Sends a build step notification, never letting Slack failures
  /// interrupt the pipeline.
  Future<void> notifyBuildStep(
    SlackService? slack, {
    required String step,
    required String client,
    required String platform,
    required String status,
    String? additionalInfo,
    String? errorMessage,
  }) async {
    if (slack == null) return;

    try {
      await slack.sendBuildStepNotification(
        step: step,
        client: client,
        platform: platform,
        status: status,
        additionalInfo: additionalInfo,
        errorMessage: errorMessage,
      );
    } catch (e) {
      Logger.warning('Failed to send Slack notification: $e');
    }
  }
}

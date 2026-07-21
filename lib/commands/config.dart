import 'package:udara_cli/core/core.dart';

class ConfigCommand extends UdaraCommand {
  @override
  final String name = 'config';

  @override
  final String description = '''View and manage CLI configuration settings.

  USAGE:
  udara_cli config [OPTIONS]

  EXAMPLES:
  # View current configuration
  udara_cli config

  DISPLAYS:
  • Slack notification settings
  • Bot token status
  • CLI config file location

  MANAGEMENT:
  • Use "udara_cli setup --notify" to modify Slack settings
  • Use "udara_cli setup --reset" to clear all settings''';

  @override
  Future<void> run() async {
    try {
      await ConfigService.showConfig();

      Logger.phase('Tips & Shortcuts');
      Logger.info('• Run "udara_cli setup" to modify CLI settings.');
      Logger.info(
          '• Use the --slack-channel parameter during builds to override the default channel.');
      Logger.info(
          '• Run "udara_cli setup --reset" to clear all stored CLI configuration.');
    } on BuildException catch (e, s) {
      Logger.error(e.message,
          cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      rethrow;
    } catch (e, s) {
      Logger.error('An unexpected error occurred while reading configuration.',
          cause: e, stackTrace: s);
      rethrow;
    }
  }
}

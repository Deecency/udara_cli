import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/services/config_service.dart';

class ConfigCommand extends UdaraCommand {
  @override
  final String name = 'config';

  @override
  final String description = '''View and manage CLI configuration settings.

  🎯 USAGE:
    udara_cli config [OPTIONS]

  📋 EXAMPLES:
    # View current configuration
    udara_cli config

    # Show detailed configuration
    udara_cli config --verbose

  🔧 DISPLAYS:
    • Slack notification settings
    • Bot token status (configured/not configured)
    • Default build preferences
    • Client directory information
    • Recent build history

  💡 MANAGEMENT:
    • Use "udara_cli setup --notify" to modify Slack settings
    • Use "udara_cli setup --reset" to clear all settings''';

  @override
  Future<void> run() async {
    await ConfigService.showConfig();

    print('\n💡 Tips:');
    print('• Run "udara_cli setup" to modify these settings');
    print(
        '• Use --slack-channel parameter in build command to specify channel');
    print('• Run "udara_cli setup --reset" to reset all settings');
  }
}

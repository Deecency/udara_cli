import 'package:udara_cli/config.dart';
import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/scripts.dart';
import 'package:udara_cli/services/config_service.dart';
import 'package:udara_cli/set_up.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'udara_cli',
    '''A self-contained tool to create a new whitelabel of the current Flutter project.

  Prerequisites:
    1. A 'clients' directory must exist at the project root.
    2. Each client must have its own sub-directory (e.g., 'clients/client_a/').
    3. Each client directory needs an environment file (.env or .env_test) as well as image asset.
    4. The .env file must define BUNDLE_ID, APP_NAME_PROD, APP_ICON_PATH, and ASSETS_PATH.
    5. A default client should exist to hold the base configurations for the app.

    Check README.md for project requirements -> https://github.com/Deecency/udara_cli/blob/55641e186803e843acb13e559783abbb7a2e3923/README.md

  Additional Commands:
    • setup - Configure CLI settings (Slack notifications, etc.)
    • config - View current CLI configuration
  ''',
  )
    ..addCommand(BuildCommand())
    ..addCommand(CleanCommand())
    ..addCommand(ListClientsCommand())
    ..addCommand(SetupCommand())
    ..addCommand(ConfigCommand());

  try {
    // Check if this is the first time running the CLI
    await _checkFirstTimeSetup(arguments);

    await runner.run(arguments);
  } on UsageException catch (e) {
    print('❌ Error: ${e.message}');
    print('\n${e.usage}');
    exit(64);
  } on BuildException catch (e) {
    print('\n❌ Build Failed: ${e.message}');
    if (e.fix != null) {
      print('🛠️  Suggestion: ${e.fix}');
    }
    exit(1);
  } catch (e) {
    print('An unexpected error occurred: $e');
    exit(1);
  }
}

Future<void> _checkFirstTimeSetup(List<String> arguments) async {
  // Don't show welcome message if running setup or config commands
  if (arguments.isNotEmpty && (arguments.first == 'setup' || arguments.first == 'config')) {
    return;
  }

  try {
    final config = await ConfigService.loadConfig();
    final hasAnyConfig = config.isNotEmpty;

    if (!hasAnyConfig) {
      print('👋 Welcome to Udara CLI!');
      print('This appears to be your first time using the CLI.');
      print('💡 Run "udara_cli setup" to configure Slack notifications and other preferences.');
      print('💡 Or continue with current command using default settings.\n');
    }
  } catch (e) {
    // If there's an error loading config, just continue silently
    // This ensures the CLI still works even if config system has issues
  }
}

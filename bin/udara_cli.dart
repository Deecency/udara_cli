import 'package:udara_cli/commands.dart';
import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/version.dart';

const _usageDescription = '''🚀 Udara CLI - Flutter Whitelabel Build Tool

A powerful CLI tool that streamlines creating whitelabeled versions of your Flutter project.
Build multiple branded versions of your app with different configurations, assets, and branding.

📋 QUICK START:
  1. udara_cli setup                    # Configure dependencies and project structure
  2. udara_cli setup --clients a,b,c   # Initialize client directories
  3. udara_cli doctor                   # Validate the setup
  4. udara_cli build --client a        # Build whitelabeled version

📁 PROJECT STRUCTURE:
  your_project/
  ├── clients/                  # Client configurations
  │   ├── default/             # Fallback client (required)
  │   └── client_a/            # Individual client setup
  │       ├── .env             # Production config
  │       ├── .env_test        # Test config (--test)
  │       ├── logo_small.png   # App icon
  │       ├── logo_large.png   # Splash screen
  │       └── fonts/           # Custom fonts (optional)
  ├── .udaraignore             # Patterns never copied into the app bundle
  └── flutter_launcher_icons.yaml

  AVAILABLE COMMANDS:
  • build        - Build whitelabeled app for a client (project is restored afterwards)
  • whitelabel   - Apply a client's branding and leave it applied for local runs
  • list-clients - Show all available clients
  • doctor       - Validate project & client setup before building
  • history      - View recent build history for this project
  • diff         - Compare env configuration between two clients
  • clean        - Restore project state and run flutter clean
  • setup        - Configure project, clients, or notifications
  • config       - View current CLI configuration
  • slack-test   - Test Slack notification setup

  Add --verbose to any command for stack traces and Slack debug output.

  For detailed documentation and examples:
    https://github.com/Deecency/udara_cli#readme
  ''';

class UdaraCommandRunner extends CommandRunner<void> {
  UdaraCommandRunner() : super('udara_cli', _usageDescription) {
    argParser
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Print the current version of Udara CLI.',
      )
      ..addFlag(
        'verbose',
        negatable: false,
        help: 'Show stack traces and extra debug output.',
      );
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] == true) {
      print('udara_cli version: $udaraCliVersion');
      return;
    }
    Logger.verbose = topLevelResults['verbose'] == true;
    await _checkFirstTimeSetup(topLevelResults.command?.name);
    return super.runCommand(topLevelResults);
  }
}

Future<void> main(List<String> arguments) async {
  final runner = UdaraCommandRunner()
    ..addCommand(BuildCommand())
    ..addCommand(WhiteLabelCommand())
    ..addCommand(CleanCommand())
    ..addCommand(ListClientsCommand())
    ..addCommand(SetupCommand())
    ..addCommand(ConfigCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(HistoryCommand())
    ..addCommand(DiffCommand())
    ..addCommand(SlackTestCommand());

  try {
    await runner.run(arguments);
  } on UsageException catch (e) {
    _printError('Invalid Command Usage', e.message);
    print('\n${e.usage}');
    exit(64);
  } on BuildException catch (e) {
    // Commands already logged the details; keep the exit concise.
    if (e.fix != null) _printSuggestion(e.fix!);
    exit(1);
  } catch (e, s) {
    _printError('Unexpected Error', e.toString());
    if (Logger.verbose) print(s);
    _printSuggestion(
        'Re-run with --verbose for details, or report this issue at: https://github.com/Deecency/udara_cli/issues');
    exit(1);
  }
}

Future<void> _checkFirstTimeSetup(String? commandName) async {
  if (commandName == null ||
      ['setup', 'config', 'doctor', 'help'].contains(commandName)) {
    return;
  }

  try {
    if (!await _checkProjectInitialization()) {
      _printWelcomeMessage();
      _printProjectSetupGuidance();
    }
  } catch (e) {
    // If there's an error loading config, just continue silently
    // This ensures the CLI still works even if config system has issues
  }
}

Future<bool> _checkProjectInitialization() async {
  if (Directory('clients').existsSync()) return true;
  if (File('flutter_launcher_icons.yaml').existsSync()) return true;

  final pubspec = File('pubspec.yaml');
  if (pubspec.existsSync()) {
    final content = await pubspec.readAsString();
    return content.contains('flutter_launcher_icons') ||
        content.contains('splash_master');
  }
  return false;
}

void _printWelcomeMessage() {
  print('');
  print('🎉 Welcome to Udara CLI!');
  print('═' * 50);
  print('Transform your Flutter app into multiple whitelabeled versions');
  print('with different branding, configurations, and assets.');
  print('');
}

void _printProjectSetupGuidance() {
  print('GET STARTED:');
  print('');
  print('Step 1: Initialize your project');
  print('  udara_cli setup');
  print('  └─ Sets up dependencies and configuration files');
  print('');
  print('Step 2: Create client directories');
  print('  udara_cli setup --clients apple,google,microsoft');
  print('  └─ Creates branded client folders with templates');
  print('');
  print('Step 3: Configure your assets and settings');
  print('  └─ Update .env files and replace placeholder images');
  print('');
  print('Step 4: Validate and build your first whitelabeled app');
  print('  udara_cli doctor');
  print('  udara_cli build --client apple');
  print('  └─ Generates branded APK/AAB/IPA for the client');
  print('');
  print('Optional: Set up Slack notifications');
  print('  udara_cli setup --notify');
  print('');
  print('Run "udara_cli --help" for detailed command documentation');
  print('═' * 50);
  print('');
}

void _printError(String title, String message) {
  Logger.error(title);
  Logger.info(message);
}

void _printSuggestion(String suggestion) {
  Logger.info('');
  Logger.info('Suggestion: $suggestion');
}

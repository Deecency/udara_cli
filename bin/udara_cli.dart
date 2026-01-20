import 'package:udara_cli/config.dart';
import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/scripts.dart';
import 'package:udara_cli/set_up.dart';
import 'package:udara_cli/slack_test.dart';
import 'package:udara_cli/version.dart';
import 'package:udara_cli/white_label.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'udara_cli',
    '''🚀 Udara CLI - Flutter Whitelabel Build Tool

A powerful CLI tool that streamlines creating whitelabeled versions of your Flutter project.
Build multiple branded versions of your app with different configurations, assets, and branding.

📋 QUICK START:
  1. udara_cli setup                    # Configure dependencies and project structure
  2. udara_cli setup --clients a,b,c   # Initialize client directories
  3. udara_cli build --client a        # Build whitelabeled version

🎯 KEY FEATURES:
  • Multiple client configurations with separate branding
  • Automated icon and splash screen generation
  • Environment-specific builds (production/test)
  • Slack notifications for build status
  • Clean project structure management

📁 PROJECT STRUCTURE:
  your_project/
  ├── clients/                  # Client configurations
  │   ├── client_a/            # Individual client setup
  │   │   ├── .env             # Production config
  │   │   ├── .env_test        # Development config
  │   │   ├── logo_small.png   # App icon
  │   │   ├── logo_large.png   # Splash screen
  │   │   └── fonts/           # Custom fonts
  │   └── client_b/            # Another client...
  └── flutter_launcher_icons.yaml

🛠️  AVAILABLE COMMANDS:
  • build   - Build whitelabeled app for specific client
  • whitelabel   -  Whitelabel the app with client-specific assets, app name, bundle ID, branding, custom icons and splash screens.
  • list    - Show all available clients
  • clean   - Clean build artifacts and reset project
  • setup   - Configure project, clients, or notifications
  • config  - View current CLI configuration
  • slack-test - Test Slack notification setup

📚 For detailed documentation and examples:
    https://github.com/Deecency/udara_cli#readme
  ''',
  )
    ..addCommand(BuildCommand())
    ..addCommand(WhiteLabelCommand())
    ..addCommand(CleanCommand())
    ..addCommand(ListClientsCommand())
    ..addCommand(SetupCommand())
    ..addCommand(ConfigCommand())
    ..addCommand(SlackTestCommand());

  runner.argParser.addFlag(
    'version',
    abbr: 'v',
    negatable: false,
    help: 'Print the current version of Udara CLI.',
  );

  try {
    final results = runner.argParser.parse(arguments);

    // 2. Handle the version flag
    if (results['version'] == true) {
      print('udara_cli version: $udaraCliVersion');
      return; // Exit successfully
    }
    // Check if this is the first time running the CLI
    await _checkFirstTimeSetup(arguments);
    await runner.run(arguments);
  } on UsageException catch (e) {
    _printError('Invalid Command Usage', e.message);
    print('\n${e.usage}');
    _printSuggestion('Run "udara_cli --help" to see all available commands');
    exit(64);
  } on BuildException catch (e) {
    _printError('Build Failed', e.message);
    if (e.fix != null) {
      _printSuggestion(e.fix!);
    }
    _printSuggestion('Run "udara_cli clean" to reset your project state');
    exit(1);
  } catch (e) {
    _printError('Unexpected Error', e.toString());
    _printSuggestion(
        'Please report this issue at: https://github.com/Deecency/udara_cli/issues');
    exit(1);
  }
}

Future<void> _checkFirstTimeSetup(List<String> arguments) async {
  // Don't show welcome message for certain commands
  if (arguments.isNotEmpty &&
      ['setup', 'config', 'help', '--help', '-h'].contains(arguments.first)) {
    return;
  }

  try {
    // Check if project is initialized
    final isProjectInitialized = await _checkProjectInitialization();
    final config = await ConfigService.loadConfig();
    final hasAnyConfig = config.isNotEmpty;

    if (!isProjectInitialized) {
      _printWelcomeMessage();
      _printProjectSetupGuidance();
      return;
    }

    if (!hasAnyConfig) {
      _printReturningUserMessage();
    }
  } catch (e) {
    // If there's an error loading config, just continue silently
    // This ensures the CLI still works even if config system has issues
  }
}

Future<bool> _checkProjectInitialization() async {
  // Check for key indicators that the project has been set up
  final indicators = [
    'flutter_launcher_icons.yaml',
    'pubspec.yaml',
    'clients',
  ];

  for (final indicator in indicators) {
    final file = File(indicator);
    final dir = Directory(indicator);
    if (await file.exists() || await dir.exists()) {
      if (indicator == 'pubspec.yaml') {
        // Check if pubspec.yaml has our dependencies
        final content = await file.readAsString();
        if (content.contains('flutter_launcher_icons') ||
            content.contains('splash_master')) {
          return true;
        }
      } else {
        return true;
      }
    }
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
  print('🚀 GET STARTED:');
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
  print('Step 4: Build your first whitelabeled app');
  print('  udara_cli build --client apple');
  print('  └─ Generates branded APK/IPA for the client');
  print('');
  print('💡 Optional: Set up Slack notifications');
  print('  udara_cli setup --notify');
  print('');
  print('📚 Run "udara_cli --help" for detailed command documentation');
  print('═' * 50);
  print('');
}

void _printReturningUserMessage() {
  print('');
  print('👋 Welcome back to Udara CLI!');
  print('');
  print('💡 QUICK TIPS:');
  print('  • Run "udara_cli list-clients" to see all available clients');
  print('  • Run "udara_cli setup --notify" to enable Slack notifications');
  print('  • Run "udara_cli --help" for command reference');
  print('');
}

void _printError(String title, String message) {
  print('');
  print('❌ $title');
  print('─' * (title.length + 3));
  print(message);
}

void _printSuggestion(String suggestion) {
  print('');
  print('🛠️  Suggestion: $suggestion');
}

String _formatErrorHelp(String command, String issue, List<String> solutions) {
  final buffer = StringBuffer();
  buffer.writeln('❌ $issue');
  buffer.writeln('');
  buffer.writeln('🛠️  SOLUTIONS:');
  for (var i = 0; i < solutions.length; i++) {
    buffer.writeln('  ${i + 1}. ${solutions[i]}');
  }
  buffer.writeln('');
  buffer.writeln('💡 Get help: udara_cli $command --help');
  return buffer.toString();
}

// Usage in BuildException or other error contexts:
String getBuildErrorHelp(String errorType) {
  switch (errorType) {
    case 'missing_client':
      return _formatErrorHelp('setup', 'Client directory not found', [
        'Run "udara_cli setup --clients <client_name>" to create the client',
        'Check that clients/ directory exists in your project root',
        'Run "udara_cli list-clients" to see available clients',
      ]);

    case 'missing_env':
      return _formatErrorHelp('build', 'Environment file (.env) not found', [
        'Check that .env file exists in clients/<client_name>/ directory',
        'Ensure .env file contains required variables: BUNDLE_ID, APP_NAME_PROD, APP_ICON_PATH, ASSETS_PATH',
        'Run "udara_cli setup --clients <client_name>" to regenerate client structure',
      ]);

    case 'missing_assets':
      return _formatErrorHelp('build', 'Required assets not found', [
        'Check that logo_small.png and logo_large.png exist in client directory',
        'Verify APP_ICON_PATH in .env points to valid image file',
        'Ensure image files are in supported format (PNG, JPG)',
      ]);

    case 'not_initialized':
      return _formatErrorHelp(
          'setup', 'Project not initialized for Udara CLI', [
        'Run "udara_cli setup" to initialize the project',
        'Ensure you\'re running the command from your Flutter project root',
        'Check that pubspec.yaml exists in current directory',
      ]);

    default:
      return _formatErrorHelp('help', 'An error occurred', [
        'Run "udara_cli --help" for available commands',
        'Check the documentation at https://github.com/Deecency/udara_cli',
        'Report issues at https://github.com/Deecency/udara_cli/issues',
      ]);
  }
}

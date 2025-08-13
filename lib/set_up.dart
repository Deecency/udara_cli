import 'package:path/path.dart' as path;
import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/services/config_service.dart';
import 'package:udara_cli/services/slack_service.dart';

class SetupCommand extends UdaraCommand {
  SetupCommand() {
    argParser.addFlag(
      'reset',
      abbr: 'r',
      negatable: false,
      help: 'Reset all configuration settings.',
    );
    argParser.addOption(
      'clients',
      abbr: 'c',
      help:
          'Initialize client directories (comma-separated list, e.g., --clients a,b,c)',
    );
  }

  @override
  final String name = 'setup';

  @override
  final String description =
      'Configure CLI settings and initialize client directories.';

  @override
  Future<void> run() async {
    final reset = argResults!['reset'] as bool;
    final clientsOption = argResults!['clients'] as String?;

    if (reset) {
      await _resetConfiguration();
      return;
    }

    print('🚀 Welcome to Udara CLI Setup!');
    print('Let\'s configure your CLI preferences.\n');

    // Handle client initialization if specified
    if (clientsOption != null) {
      await _initializeClients(clientsOption);
      print(''); // Add spacing
    }

    // Continue with regular Slack configuration
    await _configureSlack();

    print('\n✅ Setup completed successfully!');
    print('💡 You can run "udara_cli config" to view your current settings.');
    print('💡 Run "udara_cli setup --reset" to reset all settings.');
  }

  Future<void> _initializeClients(String clientsInput) async {
    final clientNames = clientsInput
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    if (clientNames.isEmpty) {
      print('❌ No valid client names provided.');
      return;
    }

    print('🏗️  Initializing client directories...\n');

    final projectRoot = Directory.current.path;
    final clientsDir = Directory(path.join(projectRoot, 'clients'));

    // Create clients directory if it doesn't exist
    if (!await clientsDir.exists()) {
      await clientsDir.create();
      print('📁 Created clients directory');
    }

    for (final clientName in clientNames) {
      await _createClientStructure(clientsDir.path, clientName);
    }

    print('✅ Client directories initialized successfully!\n');
    print('📋 Next steps for each client:');
    print('   1. Update the .env and .env_test files with your configuration');
    print(
        '   2. Replace logo_small.png and logo_large.png with your client\'s assets');
    print('   3. Add any custom fonts to the fonts/ directory');
    print('   4. Run "udara_cli list" to see all available clients\n');
  }

  Future<void> _createClientStructure(
      String clientsPath, String clientName) async {
    print('🔧 Setting up client: $clientName');

    // Validate client name
    if (!_isValidClientName(clientName)) {
      print('❌ Invalid client name: $clientName');
      print(
          '   Client names should only contain letters, numbers, underscores, and hyphens.');
      return;
    }

    final clientDir = Directory(path.join(clientsPath, clientName));

    // Check if client already exists
    if (await clientDir.exists()) {
      final overwrite = _promptBool(
          '⚠️  Client "$clientName" already exists. Overwrite?',
          defaultValue: false);
      if (!overwrite) {
        print('   Skipped $clientName');
        return;
      }
    }

    try {
      // Create client directory
      await clientDir.create(recursive: true);

      // Create fonts subdirectory
      final fontsDir = Directory(path.join(clientDir.path, 'fonts'));
      await fontsDir.create();

      // Create .env file for production
      final envProdFile = File(path.join(clientDir.path, '.env'));
      await envProdFile
          .writeAsString(_generateEnvTemplate(clientName, isProduction: true));

      // Create .env_test file for development
      final envTestFile = File(path.join(clientDir.path, '.env_test'));
      await envTestFile
          .writeAsString(_generateEnvTemplate(clientName, isProduction: false));

      // Create placeholder logo files
      await _createPlaceholderLogo(
          clientDir.path, 'logo_small.png', 'Small Logo Placeholder');
      await _createPlaceholderLogo(
          clientDir.path, 'logo_large.png', 'Large Logo Placeholder');

      // Create a README file with instructions
      final readmeFile = File(path.join(clientDir.path, 'README.md'));
      await readmeFile.writeAsString(_generateClientReadme(clientName));

      print('   ✅ Created $clientName directory structure');
    } catch (e) {
      print('   ❌ Failed to create $clientName: $e');
    }
  }

  bool _isValidClientName(String name) {
    // Allow letters, numbers, underscores, and hyphens
    final regex = RegExp(r'^[a-zA-Z0-9_-]+$');
    return regex.hasMatch(name) && name.isNotEmpty;
  }

  String _generateEnvTemplate(String clientName, {required bool isProduction}) {
    final suffix = isProduction ? '' : '_test';
    final appNameSuffix = isProduction ? '' : ' (Test)';

    return '''# Environment configuration for $clientName${isProduction ? ' (Production)' : ' (Development)'}
# Generated by Udara CLI - Update these values according to your client's requirements

# Bundle ID for the app (must be unique)
BUNDLE_ID=com.yourcompany.$clientName$suffix

# App name as it appears to users
APP_NAME_PROD=$clientName App$appNameSuffix

# Path to app icon (relative to client directory)
APP_ICON_PATH=logo_small.png

# Path to assets directory (relative to client directory)
ASSETS_PATH=.

# Optional: Slack notification channel for this client
# SLACK_CHANNEL=#$clientName-builds

# Add any additional environment variables below
# CUSTOM_API_URL=https://api.$clientName.com
# CUSTOM_THEME_COLOR=#FF5722
''';
  }

  Future<void> _createPlaceholderLogo(
      String clientPath, String fileName, String description) async {
    final logoFile = File(path.join(clientPath, fileName));

    // Create a simple text file as placeholder
    // In a real implementation, you might want to generate actual image files
    final placeholderContent = '''# $description
#
# This is a placeholder file. Replace this with your actual $fileName image.
# Recommended formats: PNG, JPG
# Recommended sizes:
#   - logo_small.png: 192x192px (app icon)
#   - logo_large.png: 512x512px (splash screen, marketing)
#
# Generated by Udara CLI
''';

    await logoFile.writeAsString(placeholderContent);
  }

  String _generateClientReadme(String clientName) {
    return '''# $clientName Client Configuration

This directory contains the configuration and assets for the **$clientName** client.

## Directory Structure

```
$clientName/
├── fonts/              # Custom fonts for this client
├── .env               # Production environment variables
├── .env_test          # Development environment variables
├── logo_small.png     # Small logo (app icon)
├── logo_large.png     # Large logo (splash screen)
└── README.md          # This file
```

## Configuration Files

### .env / .env_test
These files contain environment-specific configuration:
- `BUNDLE_ID`: Unique bundle identifier for the app
- `APP_NAME_PROD`: Display name for the app
- `APP_ICON_PATH`: Path to the app icon
- `ASSETS_PATH`: Path to additional assets

### Assets
- **logo_small.png**: Used as the app icon (recommended: 192x192px)
- **logo_large.png**: Used for splash screens and marketing (recommended: 512x512px)
- **fonts/**: Directory for custom fonts used by this client

## Usage

To build this client:
```bash
udara_cli build $clientName
```

To build for testing:
```bash
udara_cli build $clientName --test
```

---
*Generated by Udara CLI*
''';
  }

  Future<void> _configureSlack() async {
    final currentlyConfigured = await ConfigService.isSlackConfigured();

    if (currentlyConfigured) {
      print('📱 Slack notifications are currently enabled.');
      final reconfigure = _promptBool(
        'Do you want to reconfigure Slack settings?',
        defaultValue: false,
      );

      if (!reconfigure) {
        print('Keeping existing Slack configuration.');
        return;
      }
    }

    final enableSlack = _promptBool(
      '📱 Do you want to enable Slack notifications for build updates?',
      defaultValue: false,
    );

    if (!enableSlack) {
      if (currentlyConfigured) {
        await ConfigService.removeSlackConfig();
        print('✅ Slack notifications disabled.');
      } else {
        print('Slack notifications will remain disabled.');
      }
      return;
    }

    print('\n📋 To set up Slack notifications, you need to:');
    print('1. Create a Slack App at https://api.slack.com/apps');
    print(
        '2. Add these bot token scopes: chat:write, files:write, channels:read');
    print('3. Install the app to your workspace');
    print('4. Copy the Bot User OAuth Token (starts with xoxb-)');
    print('');

    String? botToken;
    while (botToken == null || botToken.isEmpty) {
      stdout.write('🔑 Enter your Slack Bot Token: ');
      botToken = stdin.readLineSync()?.trim();

      if (botToken == null || botToken.isEmpty) {
        print('❌ Bot token cannot be empty. Please try again.');
        continue;
      }

      if (!botToken.startsWith('xoxb-')) {
        print('⚠️ Warning: Bot token should start with "xoxb-"');
        final proceed = _promptBool('Continue anyway?', defaultValue: false);
        if (!proceed) {
          botToken = null;
          continue;
        }
      }

      // Test the token
      print('🧪 Testing Slack connection...');
      final testResult = await _testSlackToken(botToken);
      if (!testResult) {
        print('❌ Failed to connect to Slack. Please check your token.');
        botToken = null;
        continue;
      }
    }

    await ConfigService.setSlackBotToken(botToken);
    print('✅ Slack notifications configured successfully!');
    print(
        '💡 You can specify channels per build using --slack-channel parameter');
  }

  Future<bool> _testSlackToken(String token) async {
    try {
      final slackService = SlackService(
        botToken: token,
        channel: '#general', // Just for testing
      );

      // Try to send a test message to validate the token
      // We'll use the auth.test endpoint instead of sending a message
      final response = await slackService.testConnection();
      return response;
    } catch (e) {
      return false;
    }
  }

  bool _promptBool(String question, {bool defaultValue = false}) {
    final defaultText = defaultValue ? 'Y/n' : 'y/N';

    while (true) {
      stdout.write('$question ($defaultText): ');
      final input = stdin.readLineSync()?.trim().toLowerCase();

      if (input == null || input.isEmpty) {
        return defaultValue;
      }

      if (input == 'y' || input == 'yes') {
        return true;
      } else if (input == 'n' || input == 'no') {
        return false;
      } else {
        print('Please enter y/yes or n/no.');
      }
    }
  }

  Future<void> _resetConfiguration() async {
    print('🔄 Resetting CLI configuration...');

    final confirm = _promptBool(
      '⚠️ This will remove all saved settings. Are you sure?',
      defaultValue: false,
    );

    if (!confirm) {
      print('Reset cancelled.');
      return;
    }

    await ConfigService.removeSlackConfig();
    print('✅ Configuration reset successfully!');
    print('💡 Run "udara_cli setup" to reconfigure your settings.');
  }
}

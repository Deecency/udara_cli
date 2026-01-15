import 'package:path/path.dart' as path;
import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/core/services/config_service.dart';
import 'package:udara_cli/core/services/slack_service.dart';
import 'package:yaml/yaml.dart';

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
    argParser.addFlag(
      'notify',
      abbr: 'n',
      negatable: false,
      help: 'Configure Slack notifications only.',
    );
  }

  @override
  final String name = 'setup';

  @override
  final String description = '''Configure your project for whitelabel builds.

  🎯 USAGE MODES:

    📦 PROJECT SETUP (Default)
      udara_cli setup
      └─ Install dependencies, create config files, clean old settings

    🏢 CLIENT INITIALIZATION
      udara_cli setup --clients <NAMES>
      └─ Create client directories with templates
      └─ Example: udara_cli setup --clients apple,google,microsoft

    📱 NOTIFICATION SETUP
      udara_cli setup --notify
      └─ Configure Slack bot token and notification preferences

    🔄 RESET EVERYTHING
      udara_cli setup --reset
      └─ Remove all stored configurations and start fresh

  📋 EXAMPLES:
    # First-time project setup
    udara_cli setup

    # Add new clients
    udara_cli setup --clients newclient,anotherclient

    # Configure Slack notifications
    udara_cli setup --notify

  🔧 PROJECT SETUP INCLUDES:
    • Installing required dependencies (rename, flutter_launcher_icons, splash_master)
    • Creating flutter_launcher_icons.yaml configuration
    • Adding splash_master configuration to pubspec.yaml
    • Cleaning up old configuration entries

  🏢 CLIENT SETUP INCLUDES:
    • Creating clients/[name] directory structure
    • Generating .env and .env_test templates
    • Creating placeholder logo files
    • Setting up fonts directory
    • Generating client-specific README''';

  @override
  Future<void> run() async {
    final reset = argResults!['reset'] as bool;
    final clientsOption = argResults!['clients'] as String?;
    final notifyOnly = argResults!['notify'] as bool;

    if (reset) {
      await _resetConfiguration();
      return;
    }

    // Handle specific modes
    if (clientsOption != null) {
      await _handleClientsSetup(clientsOption);
      return;
    }

    if (notifyOnly) {
      await _handleNotificationSetup();
      return;
    }

    // Default: Full project configuration setup
    await _handleProjectSetup();
  }

  /// Handle full project configuration setup (dependencies, config files, etc.)
  Future<void> _handleProjectSetup() async {
    print('🚀 Welcome to Udara CLI Setup!');
    print('Setting up project configuration and dependencies...\n');

    await _ensureProjectConfiguration();

    print('\n✅ Project setup completed successfully!');
    print('💡 Next steps:');
    print(
        '   • Run "udara_cli setup --clients a,b,c" to initialize client directories');
    print(
        '   • Run "udara_cli setup --notify" to configure Slack notifications');
    print(
        '   • Update configuration files with your specific paths and settings');
  }

  /// Handle client directories initialization
  Future<void> _handleClientsSetup(String clientsInput) async {
    print('🚀 Initializing Client Directories');
    print('Setting up client structure...\n');

    await _initializeClients(clientsInput);
    await _setupAssetDirectories();

    print('✅ Client setup completed successfully!');
    print('💡 You can run "udara_cli list" to see all available clients');
  }

  /// Handle Slack notifications setup only
  Future<void> _handleNotificationSetup() async {
    print('🚀 Notification Setup');
    print('Configuring Slack notifications...\n');

    await _configureSlack();

    print('\n✅ Notification setup completed successfully!');
    print('💡 You can now use --slack flag with build commands');
  }

  /// Ensure all project dependencies and configuration files are set up
  Future<void> _ensureProjectConfiguration() async {
    print('--- 📦 Phase 1: Dependencies ---');
    await _ensureDependencies();

    print('\n--- ⚙️ Phase 2: Configuration Files ---');
    await _ensureConfigurationFiles();

    print('\n--- 🧹 Phase 3: Cleanup Old Config ---');
    // await _cleanupOldConfigurations();
  }

  /// Ensure all required dependencies are installed
  Future<void> _ensureDependencies() async {
    print('🔍 Checking required dependencies...');

    final pubspecFile = File(path.join(Directory.current.path, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw BuildException('Cannot find pubspec.yaml in current directory');
    }

    var pubspecYaml = loadYaml(await pubspecFile.readAsString());

    final requiredDeps = ['rename', 'flutter_launcher_icons', 'splash_master'];

    for (final dep in requiredDeps) {
      pubspecYaml = await _ensureDependency(dep, pubspecFile, pubspecYaml);
    }

    print('✅ All required dependencies are installed');
  }

  /// Ensure all configuration files exist
  Future<void> _ensureConfigurationFiles() async {
    print('📄 Setting up configuration files...');

    // Generate flutter_launcher_icons.yaml
    final iconsResult = await _ensureFlutterLauncherIconsConfig();
    if (iconsResult.created) {
      print('✅ Created flutter_launcher_icons.yaml');
    } else {
      print('✅ flutter_launcher_icons.yaml already exists');
    }

    // Check/setup splash_master in pubspec.yaml
    await _ensureSplashMasterConfig();
  }

  /// Clean up old configurations from pubspec.yaml
  // Future<void> _cleanupOldConfigurations() async {
  //   print('🧹 Cleaning up old configuration entries...');

  //   final pubspecFile = File(path.join(Directory.current.path, 'pubspec.yaml'));
  //   final lines = await pubspecFile.readAsLines();

  //   final cleanupResult = await _cleanupOldFlutterLauncherIconsConfig(lines);

  //   if (cleanupResult.modified) {
  //     await pubspecFile.writeAsString(cleanupResult.lines.join('\n'));
  //     print(
  //         '✅ Removed old flutter_launcher_icons configuration from pubspec.yaml');
  //   } else {
  //     print('✅ No old configurations found to clean up');
  //   }
  // }

  /// Initialize client directories
  Future<void> _initializeClients(String clientsInput) async {
    final clientNames = clientsInput
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList()
      ..add('default');

    if (clientNames.isEmpty) {
      print('❌ No valid client names provided.');
      return;
    }

    print(
        '🏗️  Initializing ${clientNames.length} client director${clientNames.length == 1 ? 'y' : 'ies'}...\n');

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

    final pubspecFile = File(path.join(Directory.current.path, 'pubspec.yaml'));

    if (!pubspecFile.existsSync()) {
      throw BuildException('Could not find pubspec.yaml');
    }

    final lines = await pubspecFile.readAsLines();

    final assetsIndex = lines.indexWhere((line) => line.trim() == 'assets:');

    if (assetsIndex != -1) {
      // Define the new asset path you want to add
      const newAssetEntry = '    - clients/default/.env #do not remove this';

      // Insert the new line at the position immediately after 'assets:'
      lines.insert(assetsIndex + 1, newAssetEntry);

      print('Added new asset path: `$newAssetEntry`');
    } else {
      throw BuildException('Could not find `assets:` section in pubspec.yaml');
    }

    await pubspecFile.writeAsString(lines.join('\n'));

    print('\n📋 Next steps for each client:');
    print('   1. Update the .env and .env_test files with your configuration');
    print(
        '   2. Replace logo_small.png and logo_large.png with your client\'s assets');
    print('   3. Add any custom fonts to the fonts/ directory');
  }

  Future<void> _setupAssetDirectories() async {
    // Get the path to the project's root directory.
    final projectRoot = Directory.current.path;

    // 1. Check for and create the 'assets' directory.
    final assetsDir = Directory(path.join(projectRoot, 'assets'));
    if (!await assetsDir.exists()) {
      await assetsDir.create();
      print('📁 Created assets directory');
    } else {
      print('✅ assets directory already exists');
    }

    // 2. Check for and create the 'branding' subdirectory inside 'assets'.
    final brandingDir = Directory(path.join(assetsDir.path, 'branding'));
    if (!await brandingDir.exists()) {
      await brandingDir.create();
      print('📁 Created branding directory inside assets');
    } else {
      print('✅ branding directory already exists');
    }
  }

  /// Create directory structure for a single client
  Future<void> _createClientStructure(
      String clientsPath, String clientName) async {
    print('🔧 Setting up client: $clientName');

    // Validate client name
    if (!_isValidClientName(clientName)) {
      print('   ❌ Invalid client name: $clientName');
      print(
          '   Client names should only contain letters, numbers, underscores, and hyphens.');
      return;
    }

    final clientDir = Directory(path.join(clientsPath, clientName));

    // Check if client already exists
    if (await clientDir.exists()) {
      final overwrite = _promptBool(
          '   ⚠️  Client "$clientName" already exists. Overwrite?',
          defaultValue: false);
      if (!overwrite) {
        print('   ⏭️  Skipped $clientName');
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

  /// Configure Slack notifications
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

  // Configuration Management Methods
  Future<ConfigCreationResult> _ensureFlutterLauncherIconsConfig() async {
    final configFile =
        File(path.join(Directory.current.path, 'flutter_launcher_icons.yaml'));

    if (await configFile.exists()) {
      return ConfigCreationResult(false);
    }

    final template = '''# Flutter Launcher Icons Configuration
# Generated by Udara CLI
#
# This file configures app icons for your Flutter project.
# For more options, see: https://pub.dev/packages/flutter_launcher_icons

flutter_launcher_icons:
  # IMPORTANT: Update this path to your base app icon
  image_path: "assets/logo/app_icon.png"

  # Platform-specific settings
  android: true
  ios: true

  # Optional: Custom icon paths for different platforms
  # android_icon_path: "assets/android_icon.png"
  # ios_icon_path: "assets/ios_icon.png"

  # Optional: Adaptive icons for Android (API 26+)
  # adaptive_icon_background: "#FFFFFF"
  # adaptive_icon_foreground: "assets/logo/app_icon_foreground.png"

  # Optional: Custom sizes
  # min_sdk_android: 21

  # Optional: Remove the old launcher icon
  # remove_alpha_ios: true

# Additional configuration options:
# - background_color_ios: Set iOS icon background color
# - theme_color: Set theme color for adaptive icons
# - web: Configure web app icons
# - windows: Configure Windows app icons
# - macos: Configure macOS app icons
# - linux: Configure Linux app icons

# To generate icons after configuration:
# Run: dart run flutter_launcher_icons:generate
''';

    await configFile.writeAsString(template);
    return ConfigCreationResult(true);
  }

  Future<void> _ensureSplashMasterConfig() async {
    final pubspecFile = File(path.join(Directory.current.path, 'pubspec.yaml'));
    final pubspecYaml = loadYaml(await pubspecFile.readAsString());

    // Check if splash_master configuration already exists
    if (pubspecYaml['splash_master'] != null ||
        pubspecYaml['flutter']?['splash_master'] != null) {
      print('✅ splash_master configuration already exists');
      return;
    }

    print('📄 Adding splash_master configuration template...');

    final lines = await pubspecFile.readAsLines();

    // Find the flutter section
    final flutterIndex = lines.indexWhere((l) => l.trim() == 'flutter:');
    if (flutterIndex == -1) {
      throw BuildException(
          'A `flutter:` section could not be found in your pubspec.yaml.');
    }

    // Find insertion point (after uses-material-design or at flutter section)
    var insertIndex =
        lines.indexWhere((l) => l.trim().startsWith('uses-material-design:'));
    if (insertIndex == -1) insertIndex = flutterIndex;

    final template = '''
# ------------------ ADDED BY UDARA_CLI ------------------
# Splash screen configuration
# For more options, see: https://pub.dev/packages/splash_master
splash_master:
  # IMPORTANT: Update this path to your base splash screen image
  image: "assets/logo/splash_icon.png"

  # Background color (hex format)
  color: "#FFFFFF"

  # Platform-specific settings
  ios_content_mode: "center"
  android_gravity: "center"

  # Optional: Additional customization
  # android_fullscreen: true
  # ios_hide_status_bar: true
  # web_image_mode: "center"
# ---------------------------------------------------------''';

    // Insert the template
    final templateLines = template.split('\n');
    lines.insertAll(insertIndex + 1, templateLines);

    await pubspecFile.writeAsString(lines.join('\n'));
    print('✅ Added splash_master configuration to pubspec.yaml');
  }

  Future<YamlMap> _ensureDependency(
      String packageName, File pubspecFile, YamlMap pubspecYaml) async {
    final devDeps = pubspecYaml['dev_dependencies'] as YamlMap?;
    final regularDeps = pubspecYaml['dependencies'] as YamlMap?;

    if (devDeps?[packageName] == null && regularDeps?[packageName] == null) {
      print('📦 Adding $packageName dependency...');
      await runShell('flutter pub add --dev $packageName');

      // Reload the pubspec after adding dependency
      final content = await pubspecFile.readAsString();
      return loadYaml(content) as YamlMap;
    } else {
      print('✅ $packageName dependency found');
    }

    return pubspecYaml;
  }

  bool _isValidClientName(String name) {
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

# Generated Path to app images (relative to client directory)
# used to generate launch icons and splash images

APP_ICON_PATH="assets/branding/$clientName/logo_small.png"
APP_LOGO_PATH="assets/branding/$clientName/logo_large.png"
APP_LOGO_ICON_PATH="assets/branding/$clientName/logo_small.png"

# Path to assets directory (relative to client directory)
ASSETS_PATH="clients/$clientName/"

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

  Future<bool> _testSlackToken(String token) async {
    try {
      final slackService = SlackService(
        botToken: token,
        channel: '#general',
      );

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

// Helper Classes
class ConfigCleanupResult {
  final List<String> lines;
  final bool modified;

  ConfigCleanupResult(this.lines, this.modified);
}

class ConfigCreationResult {
  final bool created;

  ConfigCreationResult(this.created);
}

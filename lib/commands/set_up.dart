import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';
import 'package:yaml/yaml.dart';

class SetupCommand extends UdaraCommand {
  SetupCommand() {
    argParser
      ..addFlag(
        'reset',
        abbr: 'r',
        negatable: false,
        help: 'Reset all configuration settings.',
      )
      ..addOption(
        'clients',
        abbr: 'c',
        help: 'Initialize client directories (comma-separated list).',
      )
      ..addFlag(
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

  USAGE:
  udara_cli setup                       # install deps & config files
  udara_cli setup --clients a,b,c       # scaffold client folders
  udara_cli setup --notify              # store a Slack bot token
  udara_cli setup --reset               # clear stored CLI settings''';

  late ConfigService config;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);

    final reset = argResults!['reset'] as bool;
    final clientsOption = argResults!['clients'] as String?;
    final notifyOnly = argResults!['notify'] as bool;

    try {
      if (reset) {
        await _resetConfiguration();
        return;
      }

      if (clientsOption != null) {
        await _handleClientsSetup(clientsOption);
        return;
      }

      if (notifyOnly) {
        await _handleNotificationSetup();
        return;
      }

      await _handleProjectSetup();
    } on BuildException catch (e, s) {
      Logger.error(e.message,
          cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      rethrow;
    } catch (e, s) {
      Logger.error('An unexpected error occurred during setup.',
          cause: e, stackTrace: s);
      rethrow;
    }
  }

  // --------------------------------------------------------------------------
  // CORE HANDLERS
  // --------------------------------------------------------------------------

  Future<void> _handleProjectSetup() async {
    Logger.phase('Udara CLI Project Setup');

    Logger.phase('1: Dependencies');
    await _ensureDependencies();

    Logger.phase('2: Configuration Files');
    await _ensureConfigurationFiles();
    await _ensureGitignore();

    Logger.success('Project setup completed successfully!');
    Logger.info(
        'Next step: Run "udara_cli setup --clients <name1,name2>" to initialize clients.');
  }

  Future<void> _handleClientsSetup(String clientsInput) async {
    Logger.phase('🚀 Initializing Client Directories');

    final clientNames = clientsInput
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();

    final invalid = clientNames
        .where((n) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(n))
        .toList();
    if (invalid.isNotEmpty) {
      throw BuildException(
        'Invalid client name(s): ${invalid.join(', ')}',
        fix: 'Use only letters, digits, "_" and "-" in client names.',
      );
    }

    if (!clientNames.contains(WhiteLabelService.defaultClientName)) {
      Logger.info(
          'Adding the "default" client, which acts as the runtime fallback.');
      clientNames.add(WhiteLabelService.defaultClientName);
    }

    try {
      if (!await clientsDir.exists()) await clientsDir.create();
    } catch (e, s) {
      throw BuildException(
        'Failed to create "clients" directory at "${clientsDir.path}"',
        fix: 'Check directory permissions.',
        originalStackTrace: s,
      );
    }

    for (final clientName in clientNames) {
      await _createClientStructure(clientsDir.path, clientName);
    }

    // Ensure branding directory exists in assets
    try {
      final brandingDir = Directory(p.join(projectDir, 'assets', 'branding'));
      await brandingDir.create(recursive: true);
    } catch (e, s) {
      throw BuildException(
        'Failed to create branding assets directory.',
        fix: 'Check permissions for "assets/branding".',
        originalStackTrace: s,
      );
    }

    // Update pubspec with the default .env entry
    await config.addInitialAssetEntries();
    await _ensureGitignore();

    Logger.success('Client setup completed successfully!');
    Logger.info('Next steps:');
    Logger.info(
        '  1. Replace the placeholder logo_small.png / logo_large.png in each client folder');
    Logger.info('  2. Edit each client\'s .env (app name, bundle id, team id)');
    Logger.info(
        '  3. Run "udara_cli doctor" to validate, then "udara_cli build --client <name>"');
  }

  Future<void> _handleNotificationSetup() async {
    Logger.phase('Notification Setup');
    await _configureSlack();
    Logger.success('Notification setup completed!');
  }

  // --------------------------------------------------------------------------
  // LOGIC IMPLEMENTATIONS
  // --------------------------------------------------------------------------

  Future<void> _ensureDependencies() async {
    final pubspecFile = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found at project root.',
        fix:
            'Ensure you are running setup inside a valid Flutter project directory.',
      );
    }

    const requiredDevDeps = [
      'rename',
      'flutter_launcher_icons',
      'splash_master'
    ];
    const requiredDeps = ['flutter_dotenv'];

    try {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content);
      final devDeps = yaml['dev_dependencies'] as YamlMap?;
      final deps = yaml['dependencies'] as YamlMap?;

      for (final dep in requiredDevDeps) {
        if (devDeps?[dep] == null) {
          Logger.info('Adding dev dependency: $dep...');
          await runShell('flutter pub add --dev $dep');
        } else {
          Logger.info('Dependency already installed: $dep');
        }
      }

      for (final dep in requiredDeps) {
        if (deps?[dep] == null) {
          Logger.info(
              'Adding dependency: $dep (loads client env at runtime)...');
          await runShell('flutter pub add $dep');
        } else {
          Logger.info('Dependency already installed: $dep');
        }
      }
    } catch (e, s) {
      if (e is BuildException) rethrow;
      throw BuildException(
        'Failed to verify or install required dependencies.',
        fix: 'Ensure "pubspec.yaml" is valid and Flutter CLI is accessible.',
        originalStackTrace: s,
      );
    }
  }

  Future<void> _ensureConfigurationFiles() async {
    try {
      final iconsFile = File(p.join(projectDir, 'flutter_launcher_icons.yaml'));
      if (!iconsFile.existsSync()) {
        await iconsFile.writeAsString('''flutter_launcher_icons:
  # Overwritten per client from APP_ICON_PATH during udara_cli builds.
  image_path: "assets/branding/default/logo_small.png"
  android: true
  ios: true
''');
        Logger.success('Created flutter_launcher_icons.yaml');
      } else {
        Logger.info('flutter_launcher_icons.yaml already exists');
      }

      // 2. splash_master in pubspec.yaml
      final pubspecFile = File(p.join(projectDir, 'pubspec.yaml'));
      final yaml = loadYaml(await pubspecFile.readAsString());
      if (yaml['splash_master'] == null) {
        await config.updateYamlValue(pubspecFile, [
          'splash_master'
        ], {
          'image': 'assets/branding/default/logo_large.png',
          'color': '#FFFFFF',
          'ios_content_mode': 'center',
          'android_gravity': 'center',
        });
        Logger.success('Added splash_master template to pubspec.yaml');
      } else {
        Logger.info('splash_master configuration already present');
      }
    } catch (e, s) {
      throw BuildException(
        'Failed to create baseline configuration files.',
        fix: 'Check project directory write permissions.',
        originalStackTrace: s,
      );
    }
  }

  Future<void> _ensureGitignore() => config.ensureGitignoreEntries([
        '.udara/',
        ConfigService.historyFileName,
        '/.env',
      ]);

  Future<void> _createClientStructure(
    String clientsPath,
    String clientName,
  ) async {
    final clientDir = Directory(p.join(clientsPath, clientName));

    final alreadyExists = await clientDir.exists();

    if (!alreadyExists) {
      Logger.info('Creating structure for client: $clientName');
    } else {
      Logger.info('Updating existing client: $clientName');
    }

    try {
      await clientDir.create(recursive: true);
      await Directory(p.join(clientDir.path, 'fonts')).create(recursive: true);

      await _createFileIfMissing(
        p.join(clientDir.path, '.env'),
        _envTemplate(clientName, isProd: true),
      );

      await _createFileIfMissing(
        p.join(clientDir.path, '.env_test'),
        _envTemplate(clientName, isProd: false),
      );

      await _createFileIfMissing(
        p.join(clientDir.path, 'logo_small.png'),
        buildPlaceholderPng(size: 512),
      );

      await _createFileIfMissing(
        p.join(clientDir.path, 'logo_large.png'),
        buildPlaceholderPng(size: 1024),
      );

      await _createFileIfMissing(
        p.join(clientDir.path, 'README.md'),
        _clientReadme(clientName),
      );
    } catch (e, s) {
      throw BuildException(
        'Failed to create client directory structure for "$clientName".',
        fix: 'Ensure write permissions for "${clientDir.path}".',
        originalStackTrace: s,
      );
    }
  }

  Future<void> _createFileIfMissing(String path, Object content) async {
    final file = File(path);

    if (await file.exists()) {
      Logger.info('Skipping existing file: ${p.basename(path)}');
      return;
    }

    if (content is List<int>) {
      await file.writeAsBytes(content);
    } else {
      await file.writeAsString(content.toString());
    }
    Logger.success('Created: ${p.basename(path)}');
  }

  // --------------------------------------------------------------------------
  // HELPERS & TEMPLATES
  // --------------------------------------------------------------------------

  String _envTemplate(String client, {required bool isProd}) {
    final suffix = isProd ? '' : '.test';
    final nameSuffix = isProd ? '' : ' Test';
    return '''# Environment for "$client" (${isProd ? 'PRODUCTION' : 'TEST'})
# Required by udara_cli:
APP_NAME_PROD="$client App$nameSuffix"
BUNDLE_ID="com.udara.$client$suffix"
ASSETS_PATH="clients/$client/"
APP_ICON_PATH="assets/branding/$client/logo_small.png"
APP_LOGO_PATH="assets/branding/$client/logo_large.png"

# iOS signing (10-character Apple Developer Team ID). Remove to leave
# the Xcode project's signing untouched.
# DEVELOPMENT_TEAM="ABCDE12345"

# Anything else here is available in the app via dotenv.env['KEY']:
# PRIMARY_COLOR="0xFF4285F4"
# FONT_FAMILY="Roboto"
''';
  }

  String _clientReadme(String client) => '''# Client: $client

| File | Purpose |
| --- | --- |
| `.env` | Production configuration used by `udara_cli build --client $client` |
| `.env_test` | Test configuration used with the `--test` flag |
| `logo_small.png` | App icon source (replace the placeholder, 1024x1024 recommended) |
| `logo_large.png` | Splash screen image source (replace the placeholder) |
| `fonts/` | Optional custom fonts plus a `fonts.yaml` describing the families |

Everything in this folder except env files, secrets and patterns listed in
`.udaraignore` is copied to `assets/branding/$client/` at build time.

Validate with `udara_cli doctor --client $client`.
''';

  Future<void> _configureSlack() async {
    stdout.write('🔑 Enter Slack Bot Token (xoxb-...): ');
    final token = stdin.readLineSync()?.trim();

    if (token != null && token.startsWith('xoxb-')) {
      await ConfigService.setSlackBotToken(token);
      Logger.success('Slack Bot Token saved successfully.');
      Logger.info(
          'Run "udara_cli slack-test --channel #your-channel" to verify it.');
    } else {
      throw BuildException(
        'Invalid Slack Bot Token provided.',
        fix: 'Slack Bot Tokens must start with "xoxb-".',
      );
    }
  }

  Future<void> _resetConfiguration() async {
    stdout.write('⚠️ Are you sure you want to reset all CLI settings? (y/N): ');
    final response = stdin.readLineSync()?.trim().toLowerCase();

    if (response == 'y' || response == 'yes') {
      await ConfigService.removeSlackConfig();
      Logger.success('CLI configuration successfully reset.');
    } else {
      Logger.info('Reset cancelled.');
    }
  }
}

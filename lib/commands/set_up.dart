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
  final String description = 'Configure your project for whitelabel builds.';

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
        .toList();

    if (!clientNames.contains('default')) clientNames.add('default');

    final clientsDir = Directory(p.join(projectDir, 'clients'));
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

    Logger.success('Client setup completed successfully!');
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

    final requiredDeps = ['rename', 'flutter_launcher_icons', 'splash_master'];

    try {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content);
      final devDeps = yaml['dev_dependencies'] as YamlMap?;

      for (final dep in requiredDeps) {
        if (devDeps?[dep] == null) {
          Logger.info('Adding dev dependency: $dep...');
          await runShell('flutter pub add --dev $dep');
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
  image_path: "assets/logo/app_icon.png"
  android: true
  ios: true
''');
        Logger.success('Created flutter_launcher_icons.yaml');
      }

      // 2. splash_master in pubspec.yaml
      final pubspecFile = File(p.join(projectDir, 'pubspec.yaml'));
      final yaml = loadYaml(await pubspecFile.readAsString());
      if (yaml['splash_master'] == null) {
        await config.updateYamlValue(pubspecFile, [
          'splash_master'
        ], {
          'image': 'assets/logo/splash_icon.png',
          'color': '#FFFFFF',
          'ios_content_mode': 'center',
          'android_gravity': 'center',
        });
        Logger.success('Added splash_master template to pubspec.yaml');
      }
    } catch (e, s) {
      throw BuildException(
        'Failed to create baseline configuration files.',
        fix: 'Check project directory write permissions.',
        originalStackTrace: s,
      );
    }
  }

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
      // Ensure base directory exists
      await clientDir.create(recursive: true);

      // Ensure folders exist
      await Directory(
        p.join(clientDir.path, 'fonts'),
      ).create(recursive: true);

      // Create files only if missing
      await _createFileIfMissing(
        p.join(clientDir.path, '.env'),
        _envTemplate(clientName, true),
      );

      await _createFileIfMissing(
        p.join(clientDir.path, '.env_test'),
        _envTemplate(clientName, false),
      );

      await _createFileIfMissing(
        p.join(clientDir.path, 'logo_small.png'),
        '# Placeholder',
      );

      await _createFileIfMissing(
        p.join(clientDir.path, 'logo_large.png'),
        '# Placeholder',
      );
    } catch (e, s) {
      throw BuildException(
        'Failed to create client directory structure for "$clientName".',
        fix: 'Ensure write permissions for "${clientDir.path}".',
        originalStackTrace: s,
      );
    }
  }

  Future<void> _createFileIfMissing(
    String path,
    String content,
  ) async {
    final file = File(path);

    if (await file.exists()) {
      Logger.info('Skipping existing file: ${p.basename(path)}');
      return;
    }

    await file.writeAsString(content);
    Logger.success('Created: ${p.basename(path)}');
  }

  // --------------------------------------------------------------------------
  // HELPERS & TEMPLATES
  // --------------------------------------------------------------------------

  String _envTemplate(String client, bool isProd) {
    return '''# Environment for $client (${isProd ? 'PROD' : 'TEST'})
BUNDLE_ID=com.udara.$client${isProd ? '' : '.test'}
DEVELOPMENT_TEAM="ABCD1234" #IOS Development teamId
APP_NAME_PROD=$client App${isProd ? '' : ' Test'}
APP_ICON_PATH="assets/branding/$client/logo_small.png"
APP_LOGO_PATH="assets/branding/$client/logo_large.png"
ASSETS_PATH="clients/$client/"
''';
  }

  Future<void> _configureSlack() async {
    stdout.write('🔑 Enter Slack Bot Token (xoxb-...): ');
    final token = stdin.readLineSync()?.trim();

    if (token != null && token.startsWith('xoxb-')) {
      await ConfigService.setSlackBotToken(token);
      Logger.success('Slack Bot Token saved successfully.');
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

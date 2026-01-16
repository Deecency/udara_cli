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

    // Default: Full project configuration setup
    await _handleProjectSetup();
  }

  // --------------------------------------------------------------------------
  // CORE HANDLERS
  // --------------------------------------------------------------------------

  Future<void> _handleProjectSetup() async {
    print('🚀 Welcome to Udara CLI Setup!');

    print('\n--- 📦 Phase 1: Dependencies ---');
    await _ensureDependencies();

    print('\n--- ⚙️ Phase 2: Configuration Files ---');
    await _ensureConfigurationFiles();

    print('\n✅ Project setup completed successfully!');
    print('💡 Next: Run "udara_cli setup --clients name" to add clients.');
  }

  Future<void> _handleClientsSetup(String clientsInput) async {
    print('🚀 Initializing Client Directories...\n');

    final clientNames = clientsInput
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    if (!clientNames.contains('default')) clientNames.add('default');

    final clientsDir = Directory(p.join(projectDir, 'clients'));
    if (!await clientsDir.exists()) await clientsDir.create();

    for (final clientName in clientNames) {
      await _createClientStructure(clientsDir.path, clientName);
    }

    // Ensure branding directory exists in assets
    final brandingDir = Directory(p.join(projectDir, 'assets', 'branding'));
    await brandingDir.create(recursive: true);

    // Update pubspec with the default .env entry
    await config.addInitialAssetEntries();

    print('\n✅ Client setup completed successfully!');
  }

  Future<void> _handleNotificationSetup() async {
    print('🚀 Notification Setup...');
    await _configureSlack();
    print('\n✅ Notification setup completed!');
  }

  // --------------------------------------------------------------------------
  // LOGIC IMPLEMENTATIONS
  // --------------------------------------------------------------------------

  Future<void> _ensureDependencies() async {
    final pubspecFile = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync())
      throw BuildException('pubspec.yaml not found.');

    final requiredDeps = ['rename', 'flutter_launcher_icons', 'splash_master'];

    for (final dep in requiredDeps) {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content);
      final devDeps = yaml['dev_dependencies'] as YamlMap?;

      if (devDeps?[dep] == null) {
        print('📦 Adding $dep...');
        await runShell('flutter pub add --dev $dep');
      } else {
        print('✅ $dep is already installed.');
      }
    }
  }

  Future<void> _ensureConfigurationFiles() async {
    // 1. flutter_launcher_icons.yaml
    final iconsFile = File(p.join(projectDir, 'flutter_launcher_icons.yaml'));
    if (!iconsFile.existsSync()) {
      await iconsFile.writeAsString('''flutter_launcher_icons:
  image_path: "assets/logo/app_icon.png"
  android: true
  ios: true
''');
      print('📄 Created flutter_launcher_icons.yaml');
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
      print('📄 Added splash_master template to pubspec.yaml');
    }
  }

  Future<void> _createClientStructure(
      String clientsPath, String clientName) async {
    final clientDir = Directory(p.join(clientsPath, clientName));
    if (await clientDir.exists()) return;

    print('🔧 Creating structure for: $clientName');
    await clientDir.create(recursive: true);
    await Directory(p.join(clientDir.path, 'fonts')).create();

    // Create .env templates
    await File(p.join(clientDir.path, '.env'))
        .writeAsString(_envTemplate(clientName, true));
    await File(p.join(clientDir.path, '.env_test'))
        .writeAsString(_envTemplate(clientName, false));

    // Create placeholder logos
    await File(p.join(clientDir.path, 'logo_small.png'))
        .writeAsString('# Placeholder');
    await File(p.join(clientDir.path, 'logo_large.png'))
        .writeAsString('# Placeholder');
  }

  // --------------------------------------------------------------------------
  // HELPERS & TEMPLATES
  // --------------------------------------------------------------------------

  String _envTemplate(String client, bool isProd) {
    return '''# Environment for $client (${isProd ? 'PROD' : 'TEST'})
BUNDLE_ID=com.udara.$client${isProd ? '' : '.test'}
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
      print('✅ Token saved.');
    } else {
      print('❌ Invalid token.');
    }
  }

  Future<void> _resetConfiguration() async {
    stdout.write('⚠️ Reset all settings? (y/N): ');
    if (stdin.readLineSync()?.toLowerCase() == 'y') {
      await ConfigService.removeSlackConfig();
      print('✅ Reset complete.');
    }
  }
}

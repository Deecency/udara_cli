import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';
import 'package:yaml/yaml.dart';

/// Validates a project's Udara CLI setup without touching any files.
///
/// Runs the same checks a `build` would rely on (pubspec deps, client
/// directories, required `.env` keys, referenced asset paths, font config)
/// and reports pass/warn/fail per item so problems can be caught before a
/// build fails halfway through.
class DoctorCommand extends UdaraCommand {
  DoctorCommand() {
    argParser.addOption(
      'client',
      abbr: 'c',
      help: 'Only run checks for a specific client.',
    );
  }

  @override
  final String name = 'doctor';

  @override
  final String description = '''Validate your project's whitelabel setup.

  USAGE:
  udara_cli doctor [OPTIONS]

  EXAMPLES:
  # Check the whole project (all clients)
  udara_cli doctor

  # Check a single client
  udara_cli doctor --client apple

 CHECKS:
  • Required project files (pubspec.yaml, flutter_launcher_icons.yaml)
  • Required dev dependencies (rename, flutter_launcher_icons, splash_master)
  • flutter_dotenv dependency (needed at runtime)
  • Each client's .env / .env_test presence and required keys
  • Referenced asset paths (icons, logos) actually exist on disk
  • Client font configuration (fonts.yaml), if present''';

  late ConfigService config;

  int _passed = 0;
  int _warned = 0;
  int _failed = 0;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);

    Logger.phase('Udara CLI Doctor');
    Logger.info('Scanning project at "$projectDir"\n');

    await _checkProjectStructure();
    await _checkPubspecDependencies();
    await _checkClients(argResults?['client'] as String?);

    _printSummary();

    if (_failed > 0) exit(1);
  }

  // --------------------------------------------------------------------------
  // CHECK GROUPS
  // --------------------------------------------------------------------------

  Future<void> _checkProjectStructure() async {
    Logger.phase('Project Structure');

    final pubspec = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      _fail(
        'pubspec.yaml not found at project root.',
        fix: 'Run "udara_cli doctor" from the root of your Flutter project.',
      );
      // Nothing else can be meaningfully checked without a pubspec.
      return;
    }
    _pass('pubspec.yaml found.');

    final iconsFile = File(p.join(projectDir, 'flutter_launcher_icons.yaml'));
    if (iconsFile.existsSync()) {
      _pass('flutter_launcher_icons.yaml found.');
    } else {
      _fail(
        'flutter_launcher_icons.yaml is missing.',
        fix: 'Run "udara_cli setup" to generate it.',
      );
    }

    final clientsDir = Directory(p.join(projectDir, 'clients'));
    if (clientsDir.existsSync()) {
      _pass('"clients" directory found.');
    } else {
      _fail(
        '"clients" directory is missing.',
        fix: 'Run "udara_cli setup --clients default" to create it.',
      );
    }
  }

  Future<void> _checkPubspecDependencies() async {
    Logger.phase('Pubspec Dependencies');

    final pubspecFile = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      _fail('Skipped: pubspec.yaml not found.');
      return;
    }

    late final YamlMap yaml;
    try {
      yaml = loadYaml(await pubspecFile.readAsString()) as YamlMap;
    } catch (e) {
      _fail(
        'pubspec.yaml could not be parsed: $e',
        fix: 'Check pubspec.yaml for YAML syntax errors.',
      );
      return;
    }

    final devDeps = yaml['dev_dependencies'] as YamlMap?;
    for (final dep in ['rename', 'flutter_launcher_icons', 'splash_master']) {
      if (devDeps?[dep] != null) {
        _pass('Dev dependency "$dep" is installed.');
      } else {
        _fail(
          'Missing dev dependency: "$dep".',
          fix: 'Run "udara_cli setup" to install required dependencies.',
        );
      }
    }

    final deps = yaml['dependencies'] as YamlMap?;
    if (deps?['flutter_dotenv'] != null) {
      _pass('"flutter_dotenv" dependency is present.');
    } else {
      _fail(
        '"flutter_dotenv" is not in dependencies.',
        fix: 'Add "flutter_dotenv: ^5.1.0" (or latest) to pubspec.yaml. '
            'The build relies on it to load client env vars at runtime.',
      );
    }

    if (yaml['splash_master'] != null) {
      _pass('"splash_master" configuration found in pubspec.yaml.');
    } else {
      _warn(
        'No "splash_master" configuration in pubspec.yaml. '
        'Run "udara_cli setup" if this is unexpected.',
      );
    }
  }

  Future<void> _checkClients(String? clientFilter) async {
    Logger.phase('Client Configuration');

    final clientsDir = Directory(p.join(projectDir, 'clients'));
    if (!clientsDir.existsSync()) {
      _fail('Skipped: "clients" directory not found.');
      return;
    }

    final clientNames = <String>[];
    await for (final entity in clientsDir.list()) {
      if (entity is Directory) clientNames.add(p.basename(entity.path));
    }
    clientNames.sort();

    if (clientFilter != null) {
      if (!clientNames.contains(clientFilter)) {
        _fail(
          'Client "$clientFilter" not found in "clients" directory.',
          fix: 'Run "udara_cli list-clients" to see available clients.',
        );
        return;
      }
      await _checkClient(clientFilter);
      return;
    }

    if (clientNames.isEmpty) {
      _warn('No client directories found under "clients".');
      return;
    }

    if (!clientNames.contains('default')) {
      _warn(
        'No "default" client found. A default client is recommended as a '
        'fallback configuration.',
      );
    }

    for (final client in clientNames) {
      await _checkClient(client);
    }
  }

  Future<void> _checkClient(String client) async {
    Logger.info('── $client ──────────────────────────');
    final clientDir = Directory(p.join(projectDir, 'clients', client));

    final envFile = File(p.join(clientDir.path, '.env'));
    if (!envFile.existsSync()) {
      _fail(
        '[$client] .env is missing.',
        fix: 'Run "udara_cli setup --clients $client" to create it.',
      );
    } else {
      _pass('[$client] .env found.');
      await _checkEnvContents(client, envFile);
    }

    final envTestFile = File(p.join(clientDir.path, '.env_test'));
    if (envTestFile.existsSync()) {
      _pass('[$client] .env_test found.');
    } else {
      _warn(
        '[$client] .env_test is missing. '
        '"udara_cli build --client $client --test" will fail without it.',
      );
    }

    final fontsDir = Directory(p.join(clientDir.path, 'fonts'));
    if (fontsDir.existsSync()) {
      await _checkFonts(client, fontsDir);
    }
  }

  Future<void> _checkEnvContents(String client, File envFile) async {
    final envVars = await config.parseEnvFile(envFile);

    const requiredKeys = [
      'APP_NAME_PROD',
      'BUNDLE_ID',
      'ASSETS_PATH',
      'APP_ICON_PATH',
    ];

    final missing =
        requiredKeys.where((k) => (envVars[k] ?? '').trim().isEmpty).toList();

    if (missing.isEmpty) {
      _pass(
          '[$client] Required env keys present (${requiredKeys.join(', ')}).');
    } else {
      _fail(
        '[$client] Missing required env keys: ${missing.join(', ')}.',
        fix: 'Add ${missing.join(', ')} to clients/$client/.env',
      );
    }

    /// This is not accurate, as the assets are stored in the clients folder
    /// so looking for them in their predefined state for asset
    /// configureation is wrong.

    /*for (final key in ['APP_ICON_PATH', 'APP_LOGO_PATH']) {
      final path = envVars[key];
      if (path == null || path.trim().isEmpty) continue;

      final assetFile = File(p.join(projectDir, path));
      if (assetFile.existsSync()) {
        _pass('[$client] $key points to an existing file.');
      } else {
        _fail(
          '[$client] $key ("$path") does not exist on disk.',
          fix: 'Verify the path is correct and the file has been added.',
        );
      }
    } */

    final teamId = envVars['DEVELOPMENT_TEAM'];
    if (teamId != null && teamId.trim().isNotEmpty) {
      if (RegExp(r'^[A-Za-z0-9]{10}$').hasMatch(teamId.trim())) {
        _pass('[$client] DEVELOPMENT_TEAM looks like a valid Team ID.');
      } else {
        _warn(
          '[$client] DEVELOPMENT_TEAM ("$teamId") does not look like a '
          'valid 10-character Apple Developer Team ID.',
        );
      }
    }
  }

  Future<void> _checkFonts(String client, Directory fontsDir) async {
    final fontFiles = fontsDir
        .listSync()
        .whereType<File>()
        .where((f) => !p.basename(f.path).startsWith('.'))
        .toList();

    if (fontFiles.isEmpty) {
      _warn('[$client] "fonts" directory exists but is empty.');
      return;
    }

    final fontsYaml = File(p.join(fontsDir.path, 'fonts.yaml'));
    if (!fontsYaml.existsSync()) {
      _fail(
        '[$client] "fonts" directory has files but no "fonts.yaml".',
        fix: 'Add a fonts.yaml describing the font families (see README).',
      );
      return;
    }

    try {
      final parsed = loadYaml(await fontsYaml.readAsString());
      if (parsed is YamlList || parsed is List) {
        _pass('[$client] fonts.yaml is a valid font family list.');
      } else if (parsed is YamlMap && parsed.containsKey('fonts')) {
        _fail(
          '[$client] fonts.yaml has a top-level "fonts:" key.',
          fix: 'Remove the top-level "fonts:" key; start directly with '
              'the list of font families.',
        );
      } else {
        _fail(
          '[$client] fonts.yaml is not a list of font families.',
          fix: 'Match Flutter\'s expected structure (a list starting with '
              '"- family: ...").',
        );
      }
    } catch (e) {
      _fail(
        '[$client] fonts.yaml could not be parsed: $e',
        fix: 'Check fonts.yaml for YAML syntax errors.',
      );
    }
  }

  // --------------------------------------------------------------------------
  // REPORTING
  // --------------------------------------------------------------------------

  void _pass(String message) {
    Logger.success(message);
    _passed++;
  }

  void _warn(String message) {
    Logger.warning(message);
    _warned++;
  }

  void _fail(String message, {String? fix}) {
    Logger.error(message, cause: fix);
    _failed++;
  }

  void _printSummary() {
    Logger.phase('Summary');
    Logger.info('$_passed passed  $_warned warnings  $_failed failed');

    if (_failed > 0) {
      Logger.error(
          'Fix the items above, then re-run "udara_cli doctor" before building.');
    } else if (_warned > 0) {
      Logger.warning('No blocking issues — review the warnings when you can.');
    } else {
      Logger.success('Everything looks good. Ready to build!');
    }
  }
}

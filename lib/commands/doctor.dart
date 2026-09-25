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
  • flutter_dotenv dependency and the default client env asset
  • Each client's .env / .env_test presence and required keys
  • Referenced icon/logo files exist in the client folder and are not placeholders
  • Client font configuration (fonts.yaml) and the font files it references
  • Hooks in udara.yaml: valid hook names, scripts exist and are executable''';

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
    await _checkClients(argResults!['client'] as String?);
    _checkHooks();

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

    if (clientsDir.existsSync()) {
      _pass('"clients" directory found.');
    } else {
      _fail(
        '"clients" directory is missing.',
        fix: 'Run "udara_cli setup --clients default" to create it.',
      );
    }

    final leftoverBackups = Directory(p.join(projectDir, '.udara'));
    if (leftoverBackups.existsSync()) {
      _warn(
        'Leftover ".udara" state from an interrupted build was found.',
        fix: 'Run "udara_cli clean" to restore the project.',
      );
    }

    final gitignore = File(p.join(projectDir, '.gitignore'));
    if (gitignore.existsSync()) {
      final lines = (await gitignore.readAsLines()).map((l) => l.trim());
      if (!lines.contains(ConfigService.historyFileName)) {
        _warn(
          '${ConfigService.historyFileName} is not in .gitignore.',
          fix: 'Run "udara_cli setup" to add local state files to .gitignore.',
        );
      }
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
        fix: 'Run "udara_cli setup" or add "flutter_dotenv" to pubspec.yaml. '
            'The app relies on it to load client env vars at runtime.',
      );
    }

    if (yaml['splash_master'] != null) {
      _pass('"splash_master" configuration found in pubspec.yaml.');
    } else {
      _warn(
        'No "splash_master" configuration in pubspec.yaml.',
        fix: 'Run "udara_cli setup" if this is unexpected.',
      );
    }

    final flutter = yaml['flutter'] as YamlMap?;
    final assets = (flutter?['assets'] as YamlList?)?.map((a) => a.toString());
    if (assets != null &&
        assets.contains(ConfigService.defaultClientEnvAsset)) {
      _pass(
          'Default env "${ConfigService.defaultClientEnvAsset}" is registered as an asset.');
    } else {
      _warn(
        '"${ConfigService.defaultClientEnvAsset}" is not listed under flutter.assets, '
        'so plain "flutter run" cannot load the fallback env.',
        fix: 'Run "udara_cli setup --clients default" to register it.',
      );
    }
  }

  Future<void> _checkClients(String? clientFilter) async {
    Logger.phase('Client Configuration');

    if (!clientsDir.existsSync()) {
      _fail('Skipped: "clients" directory not found.');
      return;
    }

    final clientNames = await listClientNames();

    if (clientFilter != null) {
      if (!clientNames.contains(clientFilter)) {
        _fail(
          'Client "$clientFilter" not found in "clients" directory.',
          fix: clientNames.isEmpty
              ? 'Run "udara_cli setup --clients $clientFilter" to create it.'
              : 'Available clients: ${clientNames.join(', ')}.',
        );
        return;
      }
      await _checkClient(clientFilter);
      return;
    }

    if (clientNames.isEmpty) {
      _warn('No client directories found under "clients".',
          fix: 'Run "udara_cli setup --clients <name>".');
      return;
    }

    if (!clientNames.contains(WhiteLabelService.defaultClientName)) {
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
    final clientDir = Directory(p.join(clientsDir.path, client));

    Map<String, String> envVars = {};
    final envFile = File(p.join(clientDir.path, '.env'));
    if (!envFile.existsSync()) {
      _fail(
        '[$client] .env is missing.',
        fix: 'Run "udara_cli setup --clients $client" to create it.',
      );
    } else {
      _pass('[$client] .env found.');
      envVars = await _checkEnvContents(client, envFile, '.env');
    }

    final envTestFile = File(p.join(clientDir.path, '.env_test'));
    if (envTestFile.existsSync()) {
      _pass('[$client] .env_test found.');
      await _checkEnvContents(client, envTestFile, '.env_test');
    } else {
      _warn(
        '[$client] .env_test is missing. '
        '"udara_cli build --client $client --test" will fail without it.',
      );
    }

    final assetsPath = envVars['ASSETS_PATH'];
    final fontsDir = WhiteLabelService(projectDir: projectDir, config: config)
        .findClientFontsDir(client, assetsPath ?? p.join('clients', client));
    if (fontsDir != null) {
      await _checkFonts(client, fontsDir);
    }
  }

  /// Image paths already validated for the current client, so `.env_test`
  /// does not repeat `.env`'s findings when they point at the same file.
  final _checkedImages = <String>{};

  Future<Map<String, String>> _checkEnvContents(
      String client, File envFile, String label) async {
    final envVars = await config.parseEnvFile(envFile);

    final missing = requiredEnvKeys
        .where((k) => (envVars[k] ?? '').trim().isEmpty)
        .toList();

    if (missing.isEmpty) {
      _pass(
          '[$client] $label has all required keys (${requiredEnvKeys.join(', ')}).');
    } else {
      _fail(
        '[$client] $label is missing required keys: ${missing.join(', ')}.',
        fix: 'Add ${missing.join(', ')} to clients/$client/$label',
      );
    }

    final assetsPath = envVars['ASSETS_PATH'];
    if (assetsPath != null && assetsPath.trim().isNotEmpty) {
      final assetsDir = Directory(p.join(projectDir, assetsPath));
      final clientRoot = Directory(p.join(clientsDir.path, client));
      final rel =
          p.relative(assetsDir.absolute.path, from: clientRoot.absolute.path);
      if (!assetsDir.existsSync()) {
        _fail('[$client] $label ASSETS_PATH ("$assetsPath") does not exist.');
      } else if (rel == '..' || rel.startsWith('../') || p.isAbsolute(rel)) {
        _fail(
          '[$client] $label ASSETS_PATH ("$assetsPath") is outside clients/$client/.',
          fix: 'Point ASSETS_PATH at a folder inside clients/$client/.',
        );
      } else {
        _pass('[$client] $label ASSETS_PATH exists.');
        for (final key in ['APP_ICON_PATH', 'APP_LOGO_PATH']) {
          _checkImagePath(client, label, key, envVars[key], assetsPath);
        }
      }
    }

    final bundleId = envVars['BUNDLE_ID'];
    if (bundleId != null &&
        bundleId.isNotEmpty &&
        !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
            .hasMatch(bundleId)) {
      _warn(
        '[$client] $label BUNDLE_ID ("$bundleId") is not a valid reverse-domain identifier.',
        fix:
            'Use letters, digits and underscores separated by dots, e.g. com.company.app.',
      );
    }

    final teamId = envVars['DEVELOPMENT_TEAM'];
    if (teamId != null && teamId.trim().isNotEmpty) {
      if (RegExp(r'^[A-Za-z0-9]{10}$').hasMatch(teamId.trim())) {
        _pass('[$client] $label DEVELOPMENT_TEAM looks like a valid Team ID.');
      } else {
        _warn(
          '[$client] $label DEVELOPMENT_TEAM ("$teamId") does not look like a '
          'valid 10-character Apple Developer Team ID.',
        );
      }
    }
    return envVars;
  }

  /// Icon/logo paths point at the synced location
  /// (`assets/branding/<client>/...`), which only exists during a build, so
  /// they are resolved back to the client's ASSETS_PATH for validation.
  void _checkImagePath(String client, String label, String key, String? value,
      String assetsPath) {
    if (value == null || value.trim().isEmpty) {
      if (key == 'APP_LOGO_PATH') {
        _warn(
            '[$client] $label has no $key; the app icon will be used for the splash screen.');
      }
      return;
    }

    final brandingPrefix = 'assets/branding/$client/';
    final File resolved;
    if (value.startsWith(brandingPrefix)) {
      resolved = File(p.join(
          projectDir, assetsPath, value.substring(brandingPrefix.length)));
    } else if (value.startsWith('assets/branding/')) {
      _fail(
        '[$client] $label $key ("$value") points at another client\'s branding folder.',
        fix: 'Use "$brandingPrefix<file>" for this client.',
      );
      return;
    } else {
      resolved = File(p.join(projectDir, value));
    }

    if (!_checkedImages.add('$client:$key:${resolved.path}')) return;

    if (!resolved.existsSync()) {
      _fail(
        '[$client] $label $key ("$value") resolves to "${p.relative(resolved.path, from: projectDir)}", which does not exist.',
        fix: 'Add the image to clients/$client/ or fix the path.',
      );
    } else if (isPlaceholderPng(resolved)) {
      _warn(
        '[$client] $label $key is still the generated placeholder image.',
        fix:
            'Replace ${p.relative(resolved.path, from: projectDir)} with real artwork.',
      );
    } else {
      _pass('[$client] $label $key points to an existing file.');
    }
  }

  Future<void> _checkFonts(String client, Directory fontsDir) async {
    final fontFiles = fontsDir
        .listSync()
        .whereType<File>()
        .where((f) => !p.basename(f.path).startsWith('.'))
        .toList();

    if (fontFiles.isEmpty) {
      // `setup` creates an empty fonts/ folder; nothing to validate.
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

    final dynamic parsed;
    try {
      parsed = loadYaml(await fontsYaml.readAsString());
    } catch (e) {
      _fail(
        '[$client] fonts.yaml could not be parsed: $e',
        fix: 'Check fonts.yaml for YAML syntax errors.',
      );
      return;
    }

    if (parsed is YamlMap && parsed.containsKey('fonts')) {
      _fail(
        '[$client] fonts.yaml has a top-level "fonts:" key.',
        fix: 'Remove the top-level "fonts:" key; start directly with '
            'the list of font families.',
      );
      return;
    }
    if (parsed is! YamlList) {
      _fail(
        '[$client] fonts.yaml is not a list of font families.',
        fix: 'Match Flutter\'s expected structure (a list starting with '
            '"- family: ...").',
      );
      return;
    }
    _pass('[$client] fonts.yaml is a valid font family list.');

    final available = fontFiles.map((f) => p.basename(f.path)).toSet();
    for (final family in parsed) {
      if (family is! YamlMap) continue;
      final fonts = family['fonts'];
      if (fonts is! YamlList) {
        _warn(
            '[$client] fonts.yaml family "${family['family']}" has no "fonts" list.');
        continue;
      }
      for (final font in fonts) {
        final asset = (font is YamlMap ? font['asset'] : null)?.toString();
        if (asset == null) continue;
        if (!asset.startsWith('assets/fonts/')) {
          _warn(
            '[$client] fonts.yaml asset "$asset" should start with "assets/fonts/", '
            'where client fonts are copied at build time.',
          );
        } else if (!available.contains(p.basename(asset))) {
          _fail(
            '[$client] fonts.yaml references "$asset" but "${p.basename(asset)}" is not in ${p.relative(fontsDir.path, from: projectDir)}/.',
          );
        }
      }
    }
  }

  void _checkHooks() {
    final service = HooksService(projectDir);
    if (!service.configFile.existsSync()) return;

    Logger.phase('Hooks (${HooksService.configFileName})');
    final Map<HookPoint, List<String>> hooks;
    try {
      hooks = service.load();
    } on BuildException catch (e) {
      _fail(e.message, fix: e.fix);
      return;
    }
    if (hooks.values.every((c) => c.isEmpty)) {
      _warn('${HooksService.configFileName} declares no hook commands.');
      return;
    }

    for (final MapEntry(key: point, value: commands) in hooks.entries) {
      for (final command in commands) {
        // Only commands that start with a path can be checked on disk;
        // anything else (e.g. `dart run tool/x.dart`) is resolved by the shell.
        final program = command.trim().split(RegExp(r'\s+')).first;
        if (!program.contains('/')) {
          _pass('${point.key}: `$command`');
          continue;
        }
        final file =
            File(p.isAbsolute(program) ? program : p.join(projectDir, program));
        if (!file.existsSync()) {
          _fail(
            '${point.key}: "$program" does not exist.',
            fix:
                'Fix the path in ${HooksService.configFileName} (relative to the project root).',
          );
        } else if (!Platform.isWindows &&
            !file.statSync().modeString().contains('x')) {
          _fail(
            '${point.key}: "$program" is not executable.',
            fix: 'Run: chmod +x $program',
          );
        } else {
          _pass('${point.key}: `$command`');
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // REPORTING
  // --------------------------------------------------------------------------

  void _pass(String message) {
    Logger.success(message);
    _passed++;
  }

  void _warn(String message, {String? fix}) {
    Logger.warning(fix == null ? message : '$message ($fix)');
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

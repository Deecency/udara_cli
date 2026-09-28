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
    _checkAppConfig(argResults!['client'] as String?);
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
    final kept = ConfigService(projectDir).keptClient();
    if (kept != null) {
      _pass(
          'The project is branded as "$kept" (whitelabel --keep / Run Client); '
          'the next run or "udara_cli clean" restores it.');
    } else if (leftoverBackups.existsSync()) {
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
    final generatedConfig = _appConfigSettings()?.isGenerated ?? false;
    if (generatedConfig) {
      // Not needed for generated config; the App Configuration checks
      // report whether it can be removed.
    } else if (deps?['flutter_dotenv'] != null) {
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
    if (generatedConfig) {
      // Env files must NOT be assets in generated mode; checked below.
    } else if (assets != null &&
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

  AppConfigSettings? _appConfigSettings() {
    try {
      return AppConfigSettings.load(projectDir);
    } on BuildException {
      return null; // reported by _checkAppConfig
    }
  }

  void _checkAppConfig(String? clientFilter) {
    Logger.phase('App Configuration');
    final AppConfigSettings settings;
    try {
      settings = AppConfigSettings.load(projectDir);
    } on BuildException catch (e) {
      _fail(e.message, fix: e.fix);
      return;
    }

    final pubspec = File(p.join(projectDir, 'pubspec.yaml'));
    final yaml =
        pubspec.existsSync() ? loadYaml(pubspec.readAsStringSync()) : null;
    final assets = (yaml is YamlMap
                ? ((yaml['flutter'] as YamlMap?)?['assets'] as YamlList?)
                : null)
            ?.map((a) => '$a')
            .toList() ??
        const <String>[];

    if (!settings.isGenerated) {
      _warn(
        'Client .env files are bundled with the app as plain text: anyone can read them by unzipping the APK/IPA.',
        fix:
            'Run "udara_cli migrate-config" to see how to compile them in instead.',
      );
    } else {
      _pass(
          'Client config is generated into ${settings.output} (no .env ships with the app).');

      final output = File(p.join(projectDir, settings.output));
      if (output.existsSync()) {
        _pass('${settings.output} exists.');
      } else {
        _fail(
            '${settings.output} is missing, so the app does not compile until a build creates it.',
            fix:
                'Run "udara_cli clean" or any build to generate it, then commit it.');
      }

      final envAssets = assets.where((a) {
        final name = p.basename(a);
        return name == '.env' ||
            name.startsWith('.env_') ||
            name.startsWith('.env.');
      }).toList();
      if (envAssets.isEmpty) {
        _pass('No .env files are registered as assets.');
      } else {
        _fail(
            '${envAssets.join(', ')} still listed under flutter.assets, so it ships with the app.',
            fix: 'Remove it from pubspec.yaml.');
      }

      var loads = 0;
      var imports = 0;
      final libDir = Directory(p.join(projectDir, 'lib'));
      if (libDir.existsSync()) {
        for (final f in libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
          final src = f.readAsStringSync();
          if (RegExp(r'(?<![\w.$])dotenv\.load\s*\(').hasMatch(src)) {
            loads++;
            _fail(
                '${p.relative(f.path, from: projectDir)} still calls dotenv.load(); it will fail at startup now that no .env is bundled.',
                fix:
                    'Remove the call and read values from ${settings.className} instead.');
          }
          if (src.contains('package:flutter_dotenv/')) imports++;
        }
      }
      if (loads == 0) _pass('No dotenv.load() calls left in lib/.');

      // With an allow-list, a key read by name but not listed is null at
      // runtime (typed fields would fail to compile, map reads would not).
      final include = settings.include;
      if (include != null && libDir.existsSync()) {
        final read = RegExp('(?<![\\w.\$])${RegExp.escape(settings.className)}'
            r'''\.(?:env\s*\[|(?:get|maybeGet|getInt|getDouble|getBool)\s*\()\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1''');
        final missing = <String>{};
        for (final f in libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
          for (final m in read.allMatches(f.readAsStringSync())) {
            if (!include.contains(m.group(2))) missing.add(m.group(2)!);
          }
        }
        if (missing.isEmpty) {
          _pass('Every key the code reads is in app_config.include.');
        } else {
          _warn(
              'The code reads ${missing.join(', ')}, which app_config.include leaves out, so it is null at runtime.',
              fix:
                  'Add ${missing.length == 1 ? 'it' : 'them'} to app_config.include in udara.yaml.');
        }
      }
      // Tests may still use flutter_dotenv (e.g. loadFromString).
      for (final dir in const ['test', 'integration_test', 'test_driver']) {
        final d = Directory(p.join(projectDir, dir));
        if (!d.existsSync()) continue;
        imports += d
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) =>
                f.path.endsWith('.dart') &&
                f.readAsStringSync().contains('package:flutter_dotenv/'))
            .length;
      }
      final deps = yaml is YamlMap ? yaml['dependencies'] as YamlMap? : null;
      if (imports == 0 && deps?['flutter_dotenv'] != null) {
        _warn('flutter_dotenv is no longer imported anywhere.',
            fix: 'flutter pub remove flutter_dotenv');
      }
    }

    // Secrets: flag values that would reach the app, in either mode.
    final clients = clientFilter != null
        ? [clientFilter]
        : (clientsDir.existsSync()
            ? (clientsDir
                .listSync()
                .whereType<Directory>()
                .map((d) => p.basename(d.path))
                .toList()
              ..sort())
            : <String>[]);
    var flagged = 0;
    var secretFiles = 0;
    for (final client in clients) {
      for (final name in const ['.env', '.env_test']) {
        final f = File(p.join(clientsDir.path, client, name));
        if (!f.existsSync()) continue;
        final values = ConfigService.parseEnvContent(f.readAsStringSync());
        for (final e in values.entries) {
          if (settings.isGenerated && settings.exclude.contains(e.key))
            continue;
          final why = SecretDetector.reason(e.key, e.value);
          if (why == null) continue;
          flagged++;
          _warn(
              '[$client] $name: ${e.key} looks like a secret ($why) and would ship inside the app.',
              fix:
                  'If the app does not need it, move it to clients/$client/.secrets.');
        }
      }
      for (final name in const ['.secrets', '.secrets_test']) {
        final f = File(p.join(clientsDir.path, client, name));
        if (!f.existsSync()) continue;
        secretFiles++;
        final ignored = Process.runSync('git', ['check-ignore', '-q', f.path],
            workingDirectory: projectDir);
        final inRepo = Process.runSync(
            'git', ['rev-parse', '--is-inside-work-tree'],
            workingDirectory: projectDir);
        if (inRepo.exitCode == 0 && ignored.exitCode != 0) {
          _fail(
              'clients/$client/$name is not ignored by git and could be committed.',
              fix:
                  'Add "clients/*/.secrets*" to .gitignore (udara_cli setup does this).');
        }
      }
    }
    // Secret-looking files udara_cli won't use (e.g. "acme.secrets"): they
    // are easy to commit by accident because the ignore rule misses them.
    for (final client in clients) {
      final dir = Directory(p.join(clientsDir.path, client));
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (name == '.secrets' || name == '.secrets_test') continue;
        if (!name.toLowerCase().contains('secret')) continue;
        final ignored = Process.runSync('git', ['check-ignore', '-q', f.path],
            workingDirectory: projectDir);
        _warn(
            'clients/$client/$name looks like a secrets file but udara_cli only reads .secrets / .secrets_test'
            '${ignored.exitCode == 0 ? '' : ', and git does not ignore it'}.',
            fix: 'Rename it to clients/$client/.secrets (or delete it).');
      }
    }

    if (flagged == 0)
      _pass('No secret-looking values in the config that ships with the app.');
    if (secretFiles > 0)
      _pass(
          '$secretFiles .secrets file(s) found; they are never shipped with the app.');
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

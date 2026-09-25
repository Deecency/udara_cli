import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';
import '../core.dart';

class ConfigService {
  static const String _configFileName = '.udara_cli_config.json';

  /// The env file the app loads at runtime when nothing is passed via
  /// `--dart-define=CLIENT_ENV`. Registered as an asset by `setup`.
  static const String defaultClientEnvAsset = 'clients/default/.env';

  final String projectDir;

  ConfigService(this.projectDir);

  // --------------------------------------------------------------------------
  // ENVIRONMENT (.env) METHODS
  // --------------------------------------------------------------------------

  /// Parses an environment file into a Map.
  ///
  /// Supports `KEY=VALUE`, `export KEY=VALUE`, single or double quoted
  /// values, and inline `# comments` after an unquoted value. Malformed
  /// lines are reported as warnings and skipped.
  Future<Map<String, String>> parseEnvFile(File envFile) async {
    if (!envFile.existsSync()) {
      return {};
    }

    try {
      return parseEnvContent(await envFile.readAsString(),
          sourceName: envFile.path);
    } catch (e, s) {
      throw BuildException(
        'Failed to read environment file at "${envFile.path}"',
        fix:
            'Ensure the file is readable and properly formatted as KEY=VALUE pairs.',
        originalStackTrace: s,
      );
    }
  }

  /// Pure parser behind [parseEnvFile]; exposed for testing.
  static Map<String, String> parseEnvContent(String content,
      {String sourceName = '.env'}) {
    final envVars = <String, String>{};
    final lines = const LineSplitter().convert(content);

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('export ')) {
        line = line.substring('export '.length).trim();
      }

      final eq = line.indexOf('=');
      if (eq <= 0) {
        Logger.warning(
            '$sourceName:${i + 1}: ignoring malformed line (expected KEY=VALUE).');
        continue;
      }

      final key = line.substring(0, eq).trim();
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
        Logger.warning('$sourceName:${i + 1}: ignoring invalid key "$key".');
        continue;
      }

      envVars[key] = _parseEnvValue(line.substring(eq + 1).trim());
    }
    return envVars;
  }

  static String _parseEnvValue(String raw) {
    if (raw.isEmpty) return '';

    final quote = raw[0];
    if (quote == '"' || quote == "'") {
      final closing = raw.indexOf(quote, 1);
      if (closing > 0) {
        // Anything after the closing quote (e.g. a trailing comment) is
        // ignored, which is what dotenv implementations do.
        return raw.substring(1, closing);
      }
      // Unterminated quote: strip the opening quote and keep the rest.
      return raw.substring(1);
    }

    final hash = raw.indexOf(' #');
    final value = hash >= 0 ? raw.substring(0, hash) : raw;
    return value.trim();
  }

  /// Copies a client env file to the root `.env` for the Flutter build.
  ///
  /// When [trackForCleanup] is true, an existing root `.env` is backed up so
  /// cleanup can restore it, and a marker is recorded when no root `.env`
  /// existed so cleanup removes the copy again.
  Future<File> copyToRootEnv(File sourceEnv,
      {bool trackForCleanup = true}) async {
    if (!sourceEnv.existsSync()) {
      throw BuildException(
        'Source environment file missing at "${sourceEnv.path}"',
        fix:
            'Verify the client directory contains the expected environment file.',
      );
    }

    final target = File(p.join(projectDir, '.env'));
    try {
      if (trackForCleanup) {
        if (target.existsSync()) {
          await createBackup(target);
        } else {
          await markCreated(target);
        }
      }
      return await sourceEnv.copy(target.path);
    } catch (e, s) {
      if (e is BuildException) rethrow;
      throw BuildException(
        'Failed to copy environment file to root directory.',
        fix: 'Check write permissions for "${target.path}".',
        originalStackTrace: s,
      );
    }
  }

  // --------------------------------------------------------------------------
  // YAML MANIPULATION (pubspec.yaml, etc.)
  // --------------------------------------------------------------------------

  /// Safely updates a value in a YAML file using YamlEditor.
  /// Preserves comments and formatting.
  Future<void> updateYamlValue(
      File yamlFile, List<Object> path, Object newValue) async {
    if (!yamlFile.existsSync()) {
      Logger.warning(
          'Cannot update YAML: File not found at "${yamlFile.path}"');
      return;
    }

    try {
      final content = await yamlFile.readAsString();
      final editor = YamlEditor(content);
      editor.update(path, newValue);
      await yamlFile.writeAsString(editor.toString());
    } catch (e) {
      Logger.warning(
        'Could not update YAML path "${path.join('.')}" in "${yamlFile.path}": $e',
      );
    }
  }

  /// Rewrites the `flutter.assets` list in pubspec.yaml so that exactly one
  /// branding folder (the active client's) and the runtime env file are
  /// registered. The default client's fallback env entry is preserved.
  Future<void> updatePubspecAssets({
    required String clientAssetPath,
    required List<String> requiredExtraAssets,
  }) async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found at project root.',
        fix:
            'Ensure you are running the command from a valid Flutter project root.',
      );
    }

    try {
      final content = await file.readAsString();
      final editor = YamlEditor(content);

      final yaml = loadYaml(content);
      final currentAssets =
          (yaml['flutter']?['assets'] as YamlList?)?.toList() ?? [];

      final newAssets = currentAssets
          .map((a) => a.toString())
          .where((asset) => !_isManagedAsset(asset))
          .toList();

      final branding = 'assets/branding/$clientAssetPath/';
      if (!newAssets.contains(branding)) newAssets.add(branding);
      for (final asset in requiredExtraAssets) {
        if (!newAssets.contains(asset)) newAssets.add(asset);
      }

      editor.update(['flutter', 'assets'], newAssets);
      await file.writeAsString(editor.toString());
    } catch (e, s) {
      throw BuildException(
        'Failed to update assets in pubspec.yaml',
        fix:
            'Check if pubspec.yaml has valid syntax and a "flutter:" key defined.',
        originalStackTrace: s,
      );
    }
  }

  /// Asset entries the CLI owns and may replace: branding folders and env
  /// files, except the default client's fallback env.
  static bool _isManagedAsset(String asset) {
    if (asset == defaultClientEnvAsset) return false;
    if (asset.startsWith('assets/branding/')) return true;
    final name = p.basename(asset);
    return name == '.env' ||
        name.startsWith('.env_') ||
        name.startsWith('.env.');
  }

  Future<void> updatePubspecFonts(List<dynamic> fontList) async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found when trying to update fonts.',
        fix: 'Verify the Flutter project contains pubspec.yaml.',
      );
    }

    try {
      final content = await file.readAsString();
      final editor = YamlEditor(content);
      editor.update(['flutter', 'fonts'], fontList);
      await file.writeAsString(editor.toString());
    } catch (e, s) {
      throw BuildException(
        'Failed to write font configuration to pubspec.yaml',
        fix: 'Verify the "flutter:" entry exists in pubspec.yaml.',
        originalStackTrace: s,
      );
    }
  }

  /// Registers the default client's env file as a Flutter asset so the app
  /// can load it when no `CLIENT_ENV` is passed.
  Future<void> addInitialAssetEntries() async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    if (!file.existsSync()) return;

    try {
      final content = await file.readAsString();
      final editor = YamlEditor(content);
      final yaml = loadYaml(content);

      final flutter = yaml['flutter'] as YamlMap?;
      final currentAssets = (flutter?['assets'] as YamlList?)?.toList() ?? [];

      if (!currentAssets.contains(defaultClientEnvAsset)) {
        currentAssets.add(defaultClientEnvAsset);
        editor.update(['flutter', 'assets'], currentAssets);
        await file.writeAsString(editor.toString());
        Logger.success('Added $defaultClientEnvAsset to pubspec assets.');
      }
    } catch (e) {
      Logger.warning('Failed to add initial asset entries to pubspec.yaml: $e');
    }
  }

  /// Appends [entries] to the project's .gitignore when they are not already
  /// present. Creates the file if needed.
  Future<void> ensureGitignoreEntries(List<String> entries) async {
    final file = File(p.join(projectDir, '.gitignore'));
    try {
      final existing =
          file.existsSync() ? await file.readAsLines() : const <String>[];
      final present = existing.map((l) => l.trim()).toSet();
      final missing = entries.where((e) => !present.contains(e)).toList();
      if (missing.isEmpty) return;

      final buffer = StringBuffer();
      if (existing.isNotEmpty && existing.last.trim().isNotEmpty) {
        buffer.writeln();
      }
      buffer.writeln('# Udara CLI local state');
      for (final entry in missing) {
        buffer.writeln(entry);
      }
      await file.writeAsString(buffer.toString(), mode: FileMode.append);
      Logger.success('Added ${missing.join(', ')} to .gitignore');
    } catch (e) {
      Logger.warning('Could not update .gitignore: $e');
    }
  }

  // --------------------------------------------------------------------------
  // BACKUP & RESTORE
  // --------------------------------------------------------------------------

  Directory get _udaraDir => Directory(p.join(projectDir, '.udara'));
  Directory get _backupRoot => Directory(p.join(_udaraDir.path, 'backups'));
  Directory get _createdRoot => Directory(p.join(_udaraDir.path, 'created'));

  /// Creates a backup of a file under `.udara/backups`. Returns the backup.
  Future<File> createBackup(File file) async {
    if (!file.existsSync()) {
      throw BuildException(
        'File not found for backup: "${file.path}"',
        fix:
            'Ensure mandatory project files (like pubspec.yaml) exist before running build.',
      );
    }

    try {
      final relativePath = p.relative(file.path, from: projectDir);
      final backupFile = File(p.join(_backupRoot.path, relativePath));

      await backupFile.parent.create(recursive: true);

      return await file.copy(backupFile.path);
    } catch (e, s) {
      throw BuildException(
        'Failed to create backup file for "${file.path}"',
        fix: 'Check directory permissions for backup directory.',
        originalStackTrace: s,
      );
    }
  }

  /// Whether a backup exists for [file].
  bool hasBackup(File file) {
    final relativePath = p.relative(file.path, from: projectDir);
    return File(p.join(_backupRoot.path, relativePath)).existsSync();
  }

  /// Restores a file from its backup and deletes the backup. No-op when no
  /// backup exists.
  Future<void> restoreBackup(File originalFile) async {
    final relativePath = p.relative(originalFile.path, from: projectDir);

    final backup = File(p.join(_backupRoot.path, relativePath));

    if (!await backup.exists()) {
      return;
    }

    try {
      await originalFile.parent.create(recursive: true);
      await backup.copy(originalFile.path);
      await backup.delete();
    } catch (e, s) {
      throw BuildException(
        'Failed to restore backup for "${originalFile.path}"',
        fix:
            'Check file permissions and ensure the backup directory is accessible.',
        originalStackTrace: s,
      );
    }
  }

  /// Records that the CLI created [file] from scratch, so cleanup can remove
  /// it instead of restoring a backup.
  Future<void> markCreated(File file) async {
    final relativePath = p.relative(file.path, from: projectDir);
    final marker = File(p.join(_createdRoot.path, relativePath));
    await marker.parent.create(recursive: true);
    await marker.writeAsString('created=true');
  }

  /// Removes every file recorded via [markCreated] and clears the markers.
  Future<void> removeCreatedFiles() async {
    if (!await _createdRoot.exists()) return;

    await for (final entity in _createdRoot.list(recursive: true)) {
      if (entity is! File) continue;
      final relativePath = p.relative(entity.path, from: _createdRoot.path);
      final created = File(p.join(projectDir, relativePath));
      if (await created.exists()) {
        Logger.info('Removing generated file: $relativePath');
        await created.delete();
      }
    }
    await _createdRoot.delete(recursive: true);
  }

  Future<void> clearBackups() async {
    if (await _udaraDir.exists()) {
      await _udaraDir.delete(recursive: true);
    }
  }

  // --------------------------------------------------------------------------
  // PROJECT UTILS
  // --------------------------------------------------------------------------

  Future<String> getPubspecVersion() async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw BuildException(
        'pubspec.yaml not found at "${file.path}"',
        fix: 'Verify you are in the root directory of a Flutter project.',
      );
    }

    try {
      final yaml = loadYaml(await file.readAsString());
      return yaml['version']?.toString() ?? '1.0.0';
    } catch (e, s) {
      throw BuildException(
        'Failed to parse version from pubspec.yaml',
        fix:
            'Ensure pubspec.yaml has a valid "version:" entry (e.g., 1.0.0+1).',
        originalStackTrace: s,
      );
    }
  }

  File get pbxprojFile =>
      File(p.join(projectDir, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));

  /// Rewrites every `DEVELOPMENT_TEAM` entry in the iOS project file.
  void updateDevelopmentTeam({required String teamId}) {
    final file = pbxprojFile;

    if (!file.existsSync()) {
      throw BuildException(
        'project.pbxproj not found at "${file.path}"',
        fix: 'Ensure the iOS project directory is intact.',
      );
    }

    try {
      final contents = file.readAsStringSync();
      final pattern = RegExp(r'DEVELOPMENT_TEAM = [^;]+;');

      if (!pattern.hasMatch(contents)) {
        Logger.warning(
            'DEVELOPMENT_TEAM key not found in project.pbxproj; leaving signing untouched.');
        return;
      }

      final updated = contents.replaceAll(
        pattern,
        'DEVELOPMENT_TEAM = $teamId;',
      );

      file.writeAsStringSync(updated);
      Logger.info('Set iOS DEVELOPMENT_TEAM to $teamId');
    } catch (e, s) {
      throw BuildException(
        'Failed to update iOS DEVELOPMENT_TEAM in project.pbxproj',
        fix: 'Check file permissions for "${file.path}".',
        originalStackTrace: s,
      );
    }
  }

  // --------------------------------------------------------------------------
  // BUILD HISTORY (PROJECT-SCOPED)
  // --------------------------------------------------------------------------

  static const String historyFileName = '.udara_build_history.json';
  static const int _maxHistoryEntries = 50;

  String get _historyFilePath => p.join(projectDir, historyFileName);

  /// Appends a build record to the project-local history file, keeping only
  /// the most recent [_maxHistoryEntries]. Newest entries are stored first.
  Future<void> appendBuildHistory({
    required String client,
    required String platform,
    required String type,
    required String? version,
    required bool success,
    required Duration duration,
    String? errorMessage,
    String? artifactPath,
  }) async {
    final entry = {
      'timestamp': DateTime.now().toIso8601String(),
      'client': client,
      'platform': platform,
      'type': type,
      'version': version,
      'success': success,
      'durationSeconds': duration.inSeconds,
      if (errorMessage != null) 'error': errorMessage,
      if (artifactPath != null) 'artifact': artifactPath,
    };

    try {
      final history = await loadBuildHistory();
      history.insert(0, entry);

      if (history.length > _maxHistoryEntries) {
        history.removeRange(_maxHistoryEntries, history.length);
      }

      await File(_historyFilePath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(history),
      );
    } catch (e) {
      // Never let history recording break a build.
      Logger.warning('Failed to record build history: $e');
    }
  }

  /// Loads recorded build history, newest first. Returns an empty list if
  /// no history file exists yet.
  Future<List<Map<String, dynamic>>> loadBuildHistory() async {
    final file = File(_historyFilePath);
    if (!file.existsSync()) return [];

    try {
      final content = await file.readAsString();
      final decoded = jsonDecode(content) as List<dynamic>;
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      Logger.warning('Failed to read build history: $e');
      return [];
    }
  }

  /// Deletes the build history file. Returns true if a file was removed.
  Future<bool> clearBuildHistory() async {
    final file = File(_historyFilePath);
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
  }

  // --------------------------------------------------------------------------
  // CLI GLOBAL CONFIGURATION (USER HOME DIR)
  // --------------------------------------------------------------------------

  /// Get the config file path in user's home directory
  static String get _configFilePath {
    final homeDir = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(homeDir, _configFileName);
  }

  /// Load configuration from file
  static Future<Map<String, dynamic>> loadConfig() async {
    final configFile = File(_configFilePath);

    if (!configFile.existsSync()) {
      return {};
    }

    try {
      final content = await configFile.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      Logger.warning('Failed to load CLI configuration file: $e');
      return {};
    }
  }

  /// Save configuration to file
  static Future<void> saveConfig(Map<String, dynamic> config) async {
    final configFile = File(_configFilePath);

    try {
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config),
      );
    } catch (e) {
      Logger.warning('Failed to save CLI configuration file: $e');
    }
  }

  /// Get a specific config value
  static Future<T?> getConfigValue<T>(String key) async {
    final config = await loadConfig();
    return config[key] as T?;
  }

  /// Set a specific config value
  static Future<void> setConfigValue(String key, dynamic value) async {
    final config = await loadConfig();
    config[key] = value;
    await saveConfig(config);
  }

  /// Check if Slack is configured
  static Future<bool> isSlackConfigured() async {
    final token = await getConfigValue<String>('slack_bot_token');
    return token != null && token.isNotEmpty;
  }

  /// Get Slack bot token
  static Future<String?> getSlackBotToken() async {
    return await getConfigValue<String>('slack_bot_token');
  }

  /// Set Slack bot token
  static Future<void> setSlackBotToken(String token) async {
    await setConfigValue('slack_bot_token', token);
  }

  /// Remove Slack configuration
  static Future<void> removeSlackConfig() async {
    final config = await loadConfig();
    config.remove('slack_bot_token');
    await saveConfig(config);
  }

  /// Show current configuration (without sensitive data)
  static Future<void> showConfig() async {
    final slackEnabled = await ConfigService.isSlackConfigured();

    Logger.phase('📋 Current CLI Configuration');
    Logger.info(
        'Slack Notifications: ${slackEnabled ? '✅ Enabled' : '❌ Disabled'}');

    if (slackEnabled) {
      final token = await getSlackBotToken();
      final maskedToken = (token != null && token.length > 12)
          ? '${token.substring(0, 12)}...'
          : '***';
      Logger.info('Slack Bot Token: $maskedToken');
    }

    Logger.info('Config File Location: $_configFilePath');
  }
}

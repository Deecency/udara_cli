import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';
import '../core.dart';

class ConfigService {
  static const String _configFileName = '.udara_cli_config.json';

  final String projectDir;

  ConfigService(this.projectDir);

  // --------------------------------------------------------------------------
  // ENVIRONMENT (.env) METHODS
  // --------------------------------------------------------------------------

  /// Parses an environment file into a Map.
  Future<Map<String, String>> parseEnvFile(File envFile) async {
    if (!envFile.existsSync()) {
      return {};
    }

    try {
      final envVars = <String, String>{};
      final lines = await envFile.readAsLines();

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

        final parts = trimmed.split('=');
        if (parts.length >= 2) {
          final key = parts[0].trim();
          final value = parts.sublist(1).join('=').trim();
          // Remove surrounding quotes
          envVars[key] = value.replaceAll(RegExp(r'^"|"$'), '');
        }
      }
      return envVars;
    } catch (e, s) {
      throw BuildException(
        'Failed to read environment file at "${envFile.path}"',
        fix:
            'Ensure the file is readable and properly formatted as KEY=VALUE pairs.',
        originalStackTrace: s,
      );
    }
  }

  /// Copies a client env file to the root .env for the Flutter build.
  Future<File> copyToRootEnv(File sourceEnv, {bool isTest = false}) async {
    if (!sourceEnv.existsSync()) {
      throw BuildException(
        'Source environment file missing at "${sourceEnv.path}"',
        fix:
            'Verify the client directory contains the expected environment file.',
      );
    }

    final targetPath = p.join(projectDir, '.env');
    try {
      return await sourceEnv.copy(targetPath);
    } catch (e, s) {
      throw BuildException(
        'Failed to copy environment file to root directory.',
        fix: 'Check write permissions for "$targetPath".',
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

  /// Specifically handles the complex 'assets' list in pubspec.yaml
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

      // Filter out old branding paths and specific env paths
      final newAssets = currentAssets.where((a) {
        final s = a.toString();
        return !s.contains('assets/branding/') && !s.contains('.env');
      }).toList();

      // Add new entries
      newAssets.add('assets/branding/$clientAssetPath/');
      for (var asset in requiredExtraAssets) {
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

  Future<void> addInitialAssetEntries() async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    if (!file.existsSync()) return;

    try {
      final content = await file.readAsString();
      final editor = YamlEditor(content);
      final yaml = loadYaml(content);

      final flutter = yaml['flutter'] as YamlMap?;
      final currentAssets = (flutter?['assets'] as YamlList?)?.toList() ?? [];

      const defaultEnv = 'clients/default/.env';

      if (!currentAssets.contains(defaultEnv)) {
        currentAssets.add(defaultEnv);
        editor.update(['flutter', 'assets'], currentAssets);
        await file.writeAsString(editor.toString());
        Logger.success('Added default .env to pubspec assets.');
      }
    } catch (e) {
      Logger.warning('Failed to add initial asset entries to pubspec.yaml: $e');
    }
  }

  // --------------------------------------------------------------------------
  // BACKUP & RESTORE
  // --------------------------------------------------------------------------

  /// Creates a backup of a file (.bak extension). Returns the backup file.
  Future<File> createBackup(File file) async {
    if (!file.existsSync()) {
      throw BuildException(
        'File not found for backup: "${file.path}"',
        fix:
            'Ensure mandatory project files (like pubspec.yaml) exist before running build.',
      );
    }

    try {
      return await file.copy('${file.path}.bak');
    } catch (e, s) {
      throw BuildException(
        'Failed to create backup file for "${file.path}"',
        fix: 'Check directory permissions for "${file.parent.path}".',
        originalStackTrace: s,
      );
    }
  }

  /// Restores a file from its .bak version and deletes the backup.
  Future<void> restoreBackup(File originalFile) async {
    final backup = File('${originalFile.path}.bak');
    if (backup.existsSync()) {
      try {
        await backup.rename(originalFile.path);
      } catch (e) {
        Logger.warning(
            'Could not restore backup for "${originalFile.path}": $e');
      }
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

  void updateDevelopmentTeam(String projectRoot, {String? teamId}) {
    if (teamId == null) return;
    final pbxprojFile = File(
      '$projectRoot/ios/Runner.xcodeproj/project.pbxproj',
    );

    if (!pbxprojFile.existsSync()) {
      throw BuildException(
        'project.pbxproj not found at "${pbxprojFile.path}"',
        fix: 'Ensure the iOS project directory is intact.',
      );
    }

    try {
      final contents = pbxprojFile.readAsStringSync();
      final pattern = RegExp(r'DEVELOPMENT_TEAM = [^;]+;');

      if (!pattern.hasMatch(contents)) {
        Logger.warning('DEVELOPMENT_TEAM key not found in project.pbxproj');
        return;
      }

      final updated = contents.replaceAll(
        pattern,
        'DEVELOPMENT_TEAM = $teamId;',
      );

      pbxprojFile.writeAsStringSync(updated);
    } catch (e, s) {
      throw BuildException(
        'Failed to update iOS DEVELOPMENT_TEAM in project.pbxproj',
        fix: 'Check file permissions for "${pbxprojFile.path}".',
        originalStackTrace: s,
      );
    }
  }

  // --------------------------------------------------------------------------
  // BUILD HISTORY (PROJECT-SCOPED)
  // --------------------------------------------------------------------------

  static const String _historyFileName = '.udara_build_history.json';
  static const int _maxHistoryEntries = 50;

  String get _historyFilePath => p.join(projectDir, _historyFileName);

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

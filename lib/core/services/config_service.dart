import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

class ConfigService {
  static const String _configFileName = '.udara_cli_config.json';

  final String projectDir;

  ConfigService(this.projectDir);

  // --------------------------------------------------------------------------
  // ENVIRONMENT (.env) METHODS
  // --------------------------------------------------------------------------

  /// Parses an environment file into a Map.
  Future<Map<String, String>> parseEnvFile(File envFile) async {
    if (!envFile.existsSync()) return {};

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
  }

  /// Copies a client env file to the root .env for the Flutter build.
  Future<File> copyToRootEnv(File sourceEnv, {bool isTest = false}) async {
    final targetPath = p.join(projectDir, '.env');
    return await sourceEnv.copy(targetPath);
  }

  // --------------------------------------------------------------------------
  // YAML MANIPULATION (pubspec.yaml, etc.)
  // --------------------------------------------------------------------------

  /// Safely updates a value in a YAML file using YamlEditor.
  /// This preserves comments and formatting.
  Future<void> updateYamlValue(
      File yamlFile, List<Object> path, Object newValue) async {
    if (!yamlFile.existsSync()) return;

    final content = await yamlFile.readAsString();
    final editor = YamlEditor(content);

    try {
      editor.update(path, newValue);
      await yamlFile.writeAsString(editor.toString());
    } catch (e) {
      // If path doesn't exist, we might need to use 'set' logic depending on requirements
      print('Could not update YAML path ${path.join('.')}: $e');
    }
  }

  /// Specifically handles the complex 'assets' list in pubspec.yaml
  Future<void> updatePubspecAssets({
    required String clientAssetPath,
    required List<String> requiredExtraAssets,
  }) async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    final content = await file.readAsString();
    final editor = YamlEditor(content);

    // Get current assets or empty list
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
  }

  // --------------------------------------------------------------------------
  // BACKUP & RESTORE
  // --------------------------------------------------------------------------

  /// Creates a backup of a file. Returns the backup file.
  Future<File> createBackup(File file) async {
    if (!file.existsSync()) {
      throw FileSystemException('File not found for backup', file.path);
    }
    return await file.copy('${file.path}.bak');
  }

  /// Restores a file from its .bak version and deletes the backup.
  Future<void> restoreBackup(File originalFile) async {
    final backup = File('${originalFile.path}.bak');
    if (backup.existsSync()) {
      await backup.rename(originalFile.path);
    }
  }

  // --------------------------------------------------------------------------
  // PROJECT UTILS
  // --------------------------------------------------------------------------

  Future<String> getPubspecVersion() async {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    final yaml = loadYaml(await file.readAsString());
    return yaml['version']?.toString() ?? '1.0.0';
  }

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
      print('Warning: Failed to load config file: $e');
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
      print('Warning: Failed to save config file: $e');
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
    final isSlackConfigured = await ConfigService.isSlackConfigured();

    print('\n📋 Current CLI Configuration:');
    print('─' * 40);
    print(
        'Slack Notifications: ${isSlackConfigured ? '✅ Enabled' : '❌ Disabled'}');

    if (isSlackConfigured) {
      final token = await getSlackBotToken();
      final maskedToken =
          token!.length > 12 ? '${token.substring(0, 12)}...' : '***';
      print('Slack Bot Token: $maskedToken');
    }

    print('Config File: $_configFilePath');
    print('─' * 40);
  }
}

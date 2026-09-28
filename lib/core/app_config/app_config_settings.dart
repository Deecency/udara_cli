import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// How client configuration reaches the app.
enum AppConfigMode {
  /// The client's `.env` is bundled as a Flutter asset and read at runtime
  /// with flutter_dotenv. Readable by anyone who unzips the app. Default for
  /// existing projects so nothing changes until they migrate.
  dotenv,

  /// A Dart class with the client's values is generated before each build.
  /// No config file ships in the app, only keys meant for the app are
  /// included, and `.secrets` never reaches it.
  generated,
}

/// The `app_config:` section of `udara.yaml`:
///
/// ```yaml
/// app_config:
///   mode: generated                 # or dotenv
///   output: lib/udara_config.g.dart
///   class_name: UdaraConfig
///   exclude: [DEVELOPMENT_TEAM, ASSETS_PATH]
///   include: [BANK_NAME, PRIMARY_COLOR]  # optional allow-list
/// ```
class AppConfigSettings {
  const AppConfigSettings({
    required this.mode,
    this.output = defaultOutput,
    this.className = defaultClassName,
    this.exclude = defaultExclude,
    this.include,
    this.declared = false,
  });

  static const configFileName = 'udara.yaml';
  static const defaultOutput = 'lib/udara_config.g.dart';
  static const defaultClassName = 'UdaraConfig';

  /// Keys only the CLI needs; they never go into the app by default.
  static const defaultExclude = ['DEVELOPMENT_TEAM', 'ASSETS_PATH'];

  final AppConfigMode mode;

  /// Path of the generated Dart file, relative to the project, under lib/.
  final String output;
  final String className;

  /// `.env` keys that are not compiled into the app.
  final List<String> exclude;

  /// When set, only these `.env` keys are compiled into the app (minus
  /// [exclude]). `migrate-config` fills it with the keys the code reads, so
  /// build-only values (signing passwords, connection strings) stay out.
  final List<String>? include;

  /// Whether [key] is compiled into the app.
  bool shipsKey(String key) =>
      !exclude.contains(key) && (include == null || include!.contains(key));

  /// Whether udara.yaml has an `app_config:` section at all.
  final bool declared;

  bool get isGenerated => mode == AppConfigMode.generated;

  /// Reads udara.yaml. Without an `app_config:` section the project keeps
  /// the dotenv behaviour it has always had.
  static AppConfigSettings load(String projectDir) {
    final file = File(p.join(projectDir, configFileName));
    if (!file.existsSync())
      return const AppConfigSettings(mode: AppConfigMode.dotenv);

    final Object? yaml;
    try {
      yaml = loadYaml(file.readAsStringSync());
    } catch (e) {
      throw BuildException('$configFileName could not be parsed: $e',
          fix: 'Check $configFileName for YAML syntax errors.');
    }
    if (yaml is! YamlMap || yaml['app_config'] == null) {
      return const AppConfigSettings(mode: AppConfigMode.dotenv);
    }
    final section = yaml['app_config'];
    if (section is! YamlMap) {
      throw BuildException('"app_config" in $configFileName must be a map.',
          fix: 'For example:\n  app_config:\n    mode: generated');
    }

    const known = {'mode', 'output', 'class_name', 'exclude', 'include'};
    final unknown =
        section.keys.map((k) => '$k').where((k) => !known.contains(k));
    if (unknown.isNotEmpty) {
      throw BuildException(
          'Unknown app_config option(s) in $configFileName: ${unknown.join(', ')}.',
          fix: 'Supported: ${known.join(', ')}.');
    }

    final modeName = '${section['mode'] ?? 'dotenv'}';
    final mode =
        AppConfigMode.values.where((m) => m.name == modeName).firstOrNull;
    if (mode == null) {
      throw BuildException(
          'app_config.mode must be "generated" or "dotenv" (got "$modeName").');
    }

    final output = '${section['output'] ?? defaultOutput}';
    final normalized = p.posix.normalize(output.replaceAll('\\', '/'));
    if (!normalized.startsWith('lib/') || !normalized.endsWith('.dart')) {
      throw BuildException(
          'app_config.output must be a .dart file under lib/ (got "$output").',
          fix: 'For example: output: lib/udara_config.g.dart');
    }

    final className = '${section['class_name'] ?? defaultClassName}';
    if (!RegExp(r'^[A-Z][A-Za-z0-9_]*$').hasMatch(className)) {
      throw BuildException(
          'app_config.class_name must be a Dart class name like UdaraConfig (got "$className").');
    }

    final rawExclude = section['exclude'];
    final List<String> exclude;
    if (rawExclude == null) {
      exclude = defaultExclude;
    } else if (rawExclude is YamlList) {
      exclude = rawExclude.map((e) => '$e').toList();
    } else {
      throw BuildException('app_config.exclude must be a list of .env keys.',
          fix: 'For example: exclude: [DEVELOPMENT_TEAM, ASSETS_PATH]');
    }

    final rawInclude = section['include'];
    List<String>? include;
    if (rawInclude is YamlList) {
      include = rawInclude.map((e) => '$e').toList();
    } else if (rawInclude != null) {
      throw BuildException('app_config.include must be a list of .env keys.',
          fix: 'For example: include: [BANK_NAME, PRIMARY_COLOR]');
    }

    return AppConfigSettings(
      mode: mode,
      output: normalized,
      className: className,
      exclude: exclude,
      include: include,
      declared: true,
    );
  }
}

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../core.dart';

/// Points in the pipeline where user commands from `udara.yaml` run.
enum HookPoint {
  /// After the client's native branding (bundle id, app name, icons, splash,
  /// iOS team) is applied, before `flutter build`. Runs in `build` and
  /// `whitelabel`, so editor "Run Client" flows get it too.
  afterBranding('after_branding'),

  /// After a successful build, with `UDARA_ARTIFACT` set. `build` only.
  afterBuild('after_build');

  const HookPoint(this.key);

  final String key;

  static HookPoint? fromKey(String key) {
    for (final point in values) {
      if (point.key == key) return point;
    }
    return null;
  }
}

/// What a hook is told about the current run, exposed as `UDARA_*`
/// environment variables.
class HookContext {
  HookContext({
    required this.command,
    required this.projectDir,
    required this.client,
    required this.envFile,
    required this.isTest,
    this.platform,
    this.buildType,
    this.version,
    this.bundleId,
    this.appName,
    this.artifact,
  });

  final String command;
  final String projectDir;
  final String client;
  final File envFile;
  final bool isTest;
  final String? platform;
  final String? buildType;
  final String? version;
  final String? bundleId;
  final String? appName;
  final String? artifact;

  HookContext withArtifact(String? path) => HookContext(
        command: command,
        projectDir: projectDir,
        client: client,
        envFile: envFile,
        isTest: isTest,
        platform: platform,
        buildType: buildType,
        version: version,
        bundleId: bundleId,
        appName: appName,
        artifact: path,
      );

  Map<String, String> toEnvironment(HookPoint point) => {
        'UDARA_HOOK': point.key,
        'UDARA_COMMAND': command,
        'UDARA_PROJECT_DIR': projectDir,
        'UDARA_CLIENT': client,
        'UDARA_CLIENT_DIR': p.join(projectDir, 'clients', client),
        'UDARA_ENV': isTest ? 'test' : 'prod',
        'UDARA_ENV_FILE': envFile.absolute.path,
        'UDARA_PLATFORM': platform ?? '',
        'UDARA_BUILD_TYPE': buildType ?? '',
        'UDARA_VERSION': version ?? '',
        'UDARA_BUNDLE_ID': bundleId ?? '',
        'UDARA_APP_NAME': appName ?? '',
        if (artifact != null) 'UDARA_ARTIFACT': artifact!,
      };
}

/// Loads and runs project hooks declared in `udara.yaml`:
///
/// ```yaml
/// hooks:
///   after_branding:
///     - ./scripts/firebase_configure.sh
///   after_build: ./scripts/upload.sh
/// ```
///
/// Each command runs through the system shell in the project root, with
/// output streamed live. A non-zero exit stops the run (cleanup still runs).
class HooksService {
  HooksService(this.projectDir);

  static const configFileName = 'udara.yaml';

  final String projectDir;

  File get configFile => File(p.join(projectDir, configFileName));

  /// Parses `udara.yaml`. Returns an empty map when the file is absent and
  /// throws a [BuildException] for malformed content or unknown hook names,
  /// so a typo fails fast instead of being silently ignored.
  Map<HookPoint, List<String>> load() {
    final file = configFile;
    if (!file.existsSync()) return const {};

    final Object? yaml;
    try {
      yaml = loadYaml(file.readAsStringSync());
    } catch (e) {
      throw BuildException(
        '$configFileName could not be parsed: $e',
        fix: 'Check $configFileName for YAML syntax errors.',
      );
    }
    if (yaml == null) return const {};
    if (yaml is! YamlMap) {
      throw BuildException(
        '$configFileName must be a YAML map with a "hooks:" key.',
        fix: _exampleFix,
      );
    }

    final hooks = yaml['hooks'];
    if (hooks == null) return const {};
    if (hooks is! YamlMap) {
      throw BuildException('"hooks" in $configFileName must be a map.',
          fix: _exampleFix);
    }

    final result = <HookPoint, List<String>>{};
    for (final entry in hooks.entries) {
      final key = entry.key.toString();
      final point = HookPoint.fromKey(key);
      if (point == null) {
        throw BuildException(
          'Unknown hook "$key" in $configFileName.',
          fix: 'Supported hooks: '
              '${HookPoint.values.map((h) => h.key).join(', ')}.',
        );
      }
      final value = entry.value;
      final commands = switch (value) {
        null => <String>[],
        String s => [s],
        YamlList l => l.map((c) => c.toString()).toList(),
        _ => throw BuildException(
            'Hook "$key" must be a command string or a list of commands.',
            fix: _exampleFix,
          ),
      };
      result[point] = commands.where((c) => c.trim().isNotEmpty).toList();
    }
    return result;
  }

  /// Runs every command registered for [point], in order.
  Future<void> run(HookPoint point, HookContext context) async {
    final commands = load()[point] ?? const [];
    if (commands.isEmpty) return;

    final environment = context.toEnvironment(point);
    for (final command in commands) {
      Logger.info('Running ${point.key} hook: `$command`');
      final int exitCode;
      try {
        final process = await Process.start(
          _shell,
          [_shellFlag, command],
          workingDirectory: projectDir,
          environment: environment,
          mode: ProcessStartMode.inheritStdio,
        );
        exitCode = await process.exitCode;
      } catch (e, s) {
        throw BuildException(
          'Could not start ${point.key} hook `$command`: $e',
          fix: 'Check the command in $configFileName.',
          originalStackTrace: s,
        );
      }
      if (exitCode != 0) {
        throw BuildException(
          '${point.key} hook failed with exit code $exitCode: `$command`',
          fix: 'Fix the hook (see its output above) or remove it from '
              '$configFileName. Hooks receive UDARA_CLIENT, UDARA_CLIENT_DIR, '
              'UDARA_BUNDLE_ID and other UDARA_* variables.',
        );
      }
    }
  }

  static String get _shell => Platform.isWindows ? 'cmd' : 'bash';
  static String get _shellFlag => Platform.isWindows ? '/c' : '-c';

  static const _exampleFix = 'Expected format:\n'
      '  hooks:\n'
      '    after_branding:\n'
      '      - ./scripts/firebase_configure.sh';
}

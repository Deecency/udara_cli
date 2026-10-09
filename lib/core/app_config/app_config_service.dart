import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';
import '../services/config_service.dart';
import 'app_config_generator.dart';
import 'app_config_settings.dart';

/// Writes the generated config class (`generated` mode) for a client.
class AppConfigService {
  AppConfigService(this.projectDir, this.config)
      : settings = AppConfigSettings.load(projectDir);

  final String projectDir;
  final ConfigService config;
  final AppConfigSettings settings;

  File get outputFile => File(p.join(projectDir, settings.output));

  /// Every client's `.env` and `.env_test`: the class must have the same
  /// fields no matter which client or environment it was generated for.
  List<File> allEnvFiles() {
    final clients = Directory(p.join(projectDir, 'clients'));
    if (!clients.existsSync()) return const [];
    final files = <File>[];
    for (final dir in clients.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path))) {
      for (final name in const ['.env', '.env_test']) {
        final f = File(p.join(dir.path, name));
        if (f.existsSync()) files.add(f);
      }
    }
    return files;
  }

  /// Native build files that read the root `.env` (e.g. a Gradle signing
  /// config), with the keys they read when that can be seen. When there are
  /// none, generated mode never writes a root `.env` at all.
  Map<String, List<String>> nativeEnvReaders() {
    const candidates = [
      'android/app/build.gradle',
      'android/app/build.gradle.kts',
      'android/build.gradle',
      'android/build.gradle.kts',
      'android/settings.gradle',
      'android/settings.gradle.kts',
      'ios/Runner.xcodeproj/project.pbxproj',
    ];
    final readers = <String, List<String>>{};
    for (final rel in candidates) {
      final f = File(p.join(projectDir, rel));
      if (!f.existsSync()) continue;
      final src = f.readAsStringSync();
      if (!RegExp(r'''['"/]\.env['"]''').hasMatch(src)) continue;
      readers[rel] = RegExp(r'''getProperty\(\s*['"]([A-Za-z0-9_]+)['"]''')
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet()
          .toList()
        ..sort();
    }
    return readers;
  }

  /// Whether the root `.env` was written by udara_cli (the staged native
  /// file, or a copy of a client's `.env`), so `clean` may delete it.
  bool isStagedRootEnv() {
    final root = File(p.join(projectDir, '.env'));
    if (!root.existsSync()) return false;
    final content = root.readAsStringSync();
    if (content.startsWith(ConfigService.stagedEnvHeader)) return true;
    return allEnvFiles().any((f) => f.readAsStringSync() == content);
  }

  /// Whether git ignores the generated file, typically through a
  /// `**/*.g.dart` rule meant for build_runner output. Then the class is
  /// never committed and fresh clones don't compile. False outside git.
  bool isOutputGitIgnored() {
    try {
      final r = Process.runSync('git', ['check-ignore', '-q', settings.output],
          workingDirectory: projectDir);
      return r.exitCode == 0;
    } catch (_) {
      return false; // git not installed
    }
  }

  /// When git ignores the generated file, appends `!<output>` to
  /// `.gitignore` so it gets committed. Returns false when it is still
  /// ignored afterwards (e.g. a rule in a nested .gitignore).
  Future<bool> ensureOutputTracked() async {
    if (!isOutputGitIgnored()) return true;
    await config.ensureGitignoreEntries(['!${settings.output}']);
    return !isOutputGitIgnored();
  }

  /// Keys some client's `.env` / `.env_test` defines that don't reach the
  /// app only because `app_config.include` doesn't list them (build-only
  /// `exclude` keys aren't reported). Empty without an include list.
  List<String> keysMissingFromInclude() {
    final include = settings.include;
    if (include == null) return const [];
    final keys = <String>{
      for (final f in allEnvFiles())
        ...ConfigService.parseEnvContent(f.readAsStringSync()).keys,
    };
    return keys
        .where((k) => !settings.exclude.contains(k) && !include.contains(k))
        .toList()
      ..sort();
  }

  /// Keys compiled into the app for [values]: everything except excluded ones.
  Map<String, String> appValues(Map<String, String> values) => {
        for (final e in values.entries)
          if (settings.shipsKey(e.key)) e.key: e.value,
      };

  /// Generates the source for [client] from [envFile].
  String generateSource(
      {required String client, required File envFile, required bool isTest}) {
    final values = appValues(ConfigService.parseEnvContent(
        envFile.readAsStringSync(),
        sourceName: envFile.path));
    final shapes = allEnvFiles()
        .map((f) =>
            appValues(ConfigService.parseEnvContent(f.readAsStringSync()))
                .keys
                .toSet())
        .toList();
    if (shapes.isEmpty) shapes.add(values.keys.toSet());

    final allKeys = shapes.fold<Set<String>>({}, (a, b) => a..addAll(b))
      ..addAll(values.keys);
    final alwaysPresent =
        allKeys.where((k) => shapes.every((s) => s.contains(k))).toSet();

    return AppConfigGenerator.generate(
      className: settings.className,
      client: client,
      isTest: isTest,
      sourceFile: p.relative(envFile.path, from: projectDir),
      values: values,
      allKeys: allKeys,
      alwaysPresent: alwaysPresent,
    );
  }

  /// Writes the class for [client]. With [trackForCleanup] the previous file
  /// (normally the committed default) is backed up, or recorded as created,
  /// so the build's cleanup puts it back.
  Future<File> write({
    required String client,
    required File envFile,
    required bool isTest,
    bool trackForCleanup = true,
  }) async {
    final source =
        generateSource(client: client, envFile: envFile, isTest: isTest);
    final file = outputFile;
    try {
      if (trackForCleanup) {
        if (file.existsSync()) {
          if (!config.hasBackup(file)) await config.createBackup(file);
        } else {
          await config.markCreated(file);
        }
      }
      await file.parent.create(recursive: true);
      await file.writeAsString(source);
      return file;
    } catch (e, s) {
      throw BuildException('Could not write ${settings.output}: $e',
          fix: 'Check write permissions for "${file.path}".',
          originalStackTrace: s);
    }
  }
}

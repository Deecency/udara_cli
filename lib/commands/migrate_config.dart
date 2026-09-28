import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// Moves a project from bundling `.env` files (readable by anyone who unzips
/// the app) to a generated Dart class. Previews by default; `--apply` makes
/// the changes. The client `.env` files themselves are never modified.
class MigrateConfigCommand extends UdaraCommand {
  MigrateConfigCommand() {
    argParser
      ..addFlag('apply',
          negatable: false,
          help: 'Make the changes (without it, only shows what would change).')
      ..addFlag('allow-dirty',
          negatable: false, help: 'Apply even with uncommitted git changes.')
      ..addFlag('include-detected',
          negatable: false,
          help:
              'When code reads keys by computed name, still compile in only the keys detected '
              'from its string literals (check the list in the preview first).')
      ..addFlag('force',
          negatable: false,
          help: 'Apply even when some code needs manual changes first.')
      ..addOption('output',
          defaultsTo: AppConfigSettings.defaultOutput,
          help: 'Generated Dart file, under lib/.')
      ..addOption('class-name',
          defaultsTo: AppConfigSettings.defaultClassName,
          help: 'Name of the generated class.');
  }

  @override
  final String name = 'migrate-config';

  @override
  final String description = '''Stop shipping .env files inside the app.

By default each client's .env is bundled as a Flutter asset, which anyone can
read by unzipping the APK or IPA. After migrating, udara_cli generates a Dart
class (lib/udara_config.g.dart) with the client's values for each build
instead: no config file ships, build-only keys stay out, and secrets live in
clients/<client>/.secrets, which never reaches the app.

What it does (preview first, then --apply):
  • adds "app_config: mode: generated" to udara.yaml
  • generates lib/udara_config.g.dart for the default client
  • rewrites dotenv.env[...], dotenv.get(...) and friends to UdaraConfig,
    and removes "await dotenv.load(...)" calls
  • removes .env entries from pubspec.yaml assets
  • adds clients/*/.secrets* to .gitignore

Your .env files are not changed. Code it can't rewrite safely is listed, not
touched. Commit first: --apply refuses to run on a dirty git tree so that
"git checkout ." always undoes it.

  USAGE:
  udara_cli migrate-config            # preview
  udara_cli migrate-config --apply    # migrate''';

  @override
  Future<void> run() async {
    final apply = argResults!['apply'] as bool;
    final output = p.posix.normalize(argResults!['output'] as String);
    final className = argResults!['class-name'] as String;

    final current = AppConfigSettings.load(projectDir);
    if (current.isGenerated) {
      Logger.success(
          'This project already uses generated app config (${current.output}).');
      return;
    }
    // Validate the requested settings with the same rules udara.yaml uses.
    if (!output.startsWith('lib/') || !output.endsWith('.dart')) {
      throw UsageException('--output must be a .dart file under lib/.', usage);
    }
    if (!RegExp(r'^[A-Z][A-Za-z0-9_]*$').hasMatch(className)) {
      throw UsageException(
          '--class-name must be a Dart class name like UdaraConfig.', usage);
    }

    checkProjectPrerequisites();
    final clients = await listClientNames();
    if (clients.isEmpty) {
      throw BuildException('No clients found.',
          fix: 'Run "udara_cli setup --clients <name>" first.');
    }
    final seedClient = clients.contains(WhiteLabelService.defaultClientName)
        ? WhiteLabelService.defaultClientName
        : clients.first;
    final seedEnv = File(p.join(clientsDir.path, seedClient, '.env'));
    if (!seedEnv.existsSync()) {
      throw BuildException('clients/$seedClient/.env is missing.',
          fix: 'The generated class starts from it; create it first.');
    }

    final pubspec = File(p.join(projectDir, 'pubspec.yaml'));
    final pubspecYaml = loadYaml(pubspec.readAsStringSync()) as YamlMap;
    final packageName = '${pubspecYaml['name']}';
    final importUri = 'package:$packageName/${output.substring('lib/'.length)}';

    // ---- Plan -------------------------------------------------------------
    final fileResults = <String, MigrationResult>{};
    for (final file in _dartFiles(output)) {
      final rel = p.relative(file.path, from: projectDir);
      final source = file.readAsStringSync();
      if (_isGenerated(rel)) {
        if (source.contains('dotenv')) {
          fileResults[rel] = MigrationResult(source, const [], [
            const MigrationNote(1,
                'Generated file mentions dotenv; regenerate it after migrating.')
          ]);
        }
        continue;
      }
      final r = DotenvMigration.migrateSource(source,
          className: className, importUri: importUri);
      if (r.changed || r.notes.isNotEmpty) fileResults[rel] = r;
    }

    final assets =
        ((pubspecYaml['flutter'] as YamlMap?)?['assets'] as YamlList?)
                ?.map((a) => '$a')
                .toList() ??
            <String>[];
    final envAssets = assets.where(_isEnvAsset).toList();

    // The keys the app's code reads become the include allow-list, so only
    // they are compiled in. A computed key (dotenv.env[variable]) makes a
    // complete list impossible; then every non-excluded key is included.
    final usedKeys = <String>{};
    final dynamicReads = <String>[];
    final dynamicLiterals = <String>{};
    for (final f in _dartFiles(output)) {
      final rel = p.relative(f.path, from: projectDir).replaceAll('\\', '/');
      if (!rel.startsWith('lib/') || _isGenerated(rel)) continue;
      final scan = DotenvMigration.scanKeys(f.readAsStringSync());
      usedKeys.addAll(scan.keys);
      if (scan.dynamic) {
        dynamicReads.add(rel);
        dynamicLiterals.addAll(scan.literals);
      }
    }
    final allEnvKeys = <String>{};
    for (final client in clients) {
      for (final name in const ['.env', '.env_test']) {
        final f = File(p.join(clientsDir.path, client, name));
        if (f.existsSync())
          allEnvKeys
              .addAll(ConfigService.parseEnvContent(f.readAsStringSync()).keys);
      }
    }
    // Computed keys are usually spelled as literals nearby; those that name
    // real .env keys are the best guess at what the code reads.
    final detected =
        ({...usedKeys, ...dynamicLiterals.where(allEnvKeys.contains)}.toList()
          ..sort());
    final includeDetected = argResults!['include-detected'] as bool;
    final include = dynamicReads.isEmpty
        ? (usedKeys.toList()..sort())
        : (includeDetected ? detected : null);
    bool ships(String key) =>
        !AppConfigSettings.defaultExclude.contains(key) &&
        (include == null || include.contains(key));
    final leftOut = (allEnvKeys.where((k) => !ships(k)).toList()..sort());
    final nativeReaders = _nativeEnvReaders();

    final secrets = <String>[];
    for (final client in clients) {
      for (final name in const ['.env', '.env_test']) {
        final f = File(p.join(clientsDir.path, client, name));
        if (!f.existsSync()) continue;
        final values = ConfigService.parseEnvContent(f.readAsStringSync());
        for (final e in values.entries) {
          final why = SecretDetector.reason(e.key, e.value);
          if (why == null) continue;
          secrets.add('clients/$client/$name: ${e.key} ($why) → '
              '${!ships(e.key) ? 'not read by the app, so it stays out after migrating' : include == null ? 'no allow-list yet, so it would still be compiled in' : 'the app reads it, so it would still be compiled in'}');
        }
      }
    }

    _printPlan(
      output: output,
      className: className,
      seedClient: seedClient,
      files: fileResults,
      envAssets: envAssets,
      secrets: secrets,
      include: include,
      detected: detected,
      dynamicReads: dynamicReads,
      leftOut: leftOut,
      nativeReaders: nativeReaders,
    );

    final blocked = fileResults.entries.where((e) => e.value.blocked).toList();
    if (!apply) {
      Logger.phase('Dry Run');
      Logger.info(
          'Nothing was changed. Review the plan, commit your work, then run:');
      Logger.info('  udara_cli migrate-config ${[
        ..._planFlags(),
        '--apply',
      ].join(' ')}');
      return;
    }

    // ---- Apply ------------------------------------------------------------
    if (!(argResults!['allow-dirty'] as bool)) _requireCleanGit();
    if (blocked.isNotEmpty && !(argResults!['force'] as bool)) {
      throw BuildException(
        '${blocked.length} file(s) need manual changes first (marked ✗ above).',
        fix:
            'Fix them by hand and re-run, or pass --force to migrate the rest anyway.',
      );
    }

    Logger.phase('Migrating');
    _writeSettings(output, className, include);
    Logger.success('udara.yaml: app_config mode set to generated');

    final config = ConfigService(projectDir);
    final appConfig = AppConfigService(projectDir, config);
    await appConfig.write(
        client: seedClient,
        envFile: seedEnv,
        isTest: false,
        trackForCleanup: false);
    Logger.success('Generated $output from clients/$seedClient/.env');

    var rewritten = 0;
    for (final entry in fileResults.entries) {
      if (!entry.value.changed) continue;
      File(p.join(projectDir, entry.key)).writeAsStringSync(entry.value.source);
      rewritten++;
    }
    if (rewritten > 0) Logger.success('Rewrote $rewritten Dart file(s)');

    if (envAssets.isNotEmpty) {
      final editor = YamlEditor(pubspec.readAsStringSync());
      final remaining = assets.where((a) => !_isEnvAsset(a)).toList();
      if (remaining.isEmpty) {
        editor.remove(['flutter', 'assets']);
      } else {
        editor.update(['flutter', 'assets'], remaining);
      }
      pubspec.writeAsStringSync(editor.toString());
      Logger.success(
          'pubspec.yaml: removed ${envAssets.join(', ')} from assets');
    }

    await config.ensureGitignoreEntries(
        const ['clients/*/.secrets*', 'clients/*/*.secrets']);

    final stillUsesDotenv = _dartFiles(output).any((f) {
      final src = f.readAsStringSync();
      return src.contains('package:flutter_dotenv/');
    });

    Logger.phase('Next Steps');
    Logger.info(
        '1. flutter analyze          (check the rewritten code compiles)');
    Logger.info('2. udara_cli doctor         (checks the new setup)');
    Logger.info('3. udara_cli build --client $seedClient');
    if (!stillUsesDotenv) {
      Logger.info(
          '4. flutter pub remove flutter_dotenv   (nothing imports it any more)');
    }
    if (secrets.isNotEmpty) {
      Logger.info(
          'Move real secrets out of .env into clients/<client>/.secrets (see above).');
    }
    Logger.info(
        'To undo: git checkout . && git clean -fd lib   (or set app_config mode: dotenv).');
  }

  void _printPlan({
    required String output,
    required String className,
    required String seedClient,
    required Map<String, MigrationResult> files,
    required List<String> envAssets,
    required List<String> secrets,
    required List<String>? include,
    required List<String> detected,
    required List<String> dynamicReads,
    required List<String> leftOut,
    required Map<String, List<String>> nativeReaders,
  }) {
    Logger.phase('Migrate App Config: .env assets → $className');
    Logger.info(
        '1. udara.yaml: add app_config (mode: generated, output: $output)');
    Logger.info(
        '2. Generate $output from clients/$seedClient/.env; builds regenerate it per client');
    if (include != null && dynamicReads.isEmpty) {
      Logger.info(
          '   Only the ${include.length} keys your code reads are compiled in '
          '(saved as app_config.include): ${include.join(', ')}');
    } else if (include != null) {
      Logger.info(
          '   Only these ${include.length} keys are compiled in (saved as app_config.include). '
          'Keys read by computed name in ${dynamicReads.join(', ')} were matched from its string literals: '
          '${include.join(', ')}');
    } else {
      Logger.info(
          '   Every key except ${AppConfigSettings.defaultExclude.join(', ')} is compiled in: '
          "${dynamicReads.join(', ')} reads keys by computed name, so the full list can't be proven.");
      Logger.info(
          '   From its string literals, the app appears to read these ${detected.length} keys: '
          '${detected.join(', ')}');
      Logger.info(
          '   If that is all of them, re-run with --include-detected to compile in only those.');
    }
    if (leftOut.isNotEmpty) {
      Logger.info('   Stay out of the app: ${leftOut.join(', ')}');
    }

    final changed = files.entries.where((e) => e.value.changed).toList();
    Logger.info(
        '3. Rewrite ${changed.length} Dart file(s)${changed.isEmpty ? ' (no dotenv usages found)' : ':'}');
    for (final e in changed) {
      Logger.info('   ${e.key}: ${e.value.changes.join('; ')}');
    }
    Logger.info(envAssets.isEmpty
        ? '4. pubspec.yaml: no .env assets to remove'
        : '4. pubspec.yaml: remove ${envAssets.join(', ')} from flutter.assets');
    Logger.info('5. .gitignore: add clients/*/.secrets*');
    for (final e in nativeReaders.entries) {
      Logger.info(
          '6. ${e.key} reads the root .env${e.value.isEmpty ? '' : ' (${e.value.join(', ')})'}: '
          'builds keep staging it for native tools (never shipped), now with the client\'s .secrets added, '
          'so those values can move to .secrets.');
    }
    Logger.info('   Your clients/*/.env files are not modified.');

    final notes = files.entries.where((e) => e.value.notes.isNotEmpty).toList();
    if (notes.isNotEmpty) {
      Logger.phase('Needs Your Attention');
      for (final e in notes) {
        for (final n in e.value.notes) {
          final line = '${e.key}:${n.line}  ${n.message}';
          n.blocking ? Logger.failure(line) : Logger.warning(line);
        }
      }
    }

    if (secrets.isNotEmpty) {
      Logger.phase('Possible Secrets');
      Logger.info(
          'These are in .env, which every build ships inside the app today. Move them to');
      Logger.info(
          'clients/<client>/.secrets: never shipped, still available to hooks (UDARA_SECRETS_FILE)');
      Logger.info('and to native builds through the staged root .env.');
      for (final s in secrets) {
        Logger.warning(s);
      }
    }
  }

  Iterable<File> _dartFiles(String output) sync* {
    for (final dir in const [
      'lib',
      'test',
      'integration_test',
      'test_driver'
    ]) {
      final d = Directory(p.join(projectDir, dir));
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (p.relative(f.path, from: projectDir).replaceAll('\\', '/') ==
            output) continue;
        yield f;
      }
    }
  }

  static bool _isGenerated(String rel) =>
      rel.endsWith('.g.dart') ||
      rel.endsWith('.freezed.dart') ||
      rel.endsWith('.mocks.dart');

  static bool _isEnvAsset(String asset) {
    final name = p.basename(asset);
    return name == '.env' ||
        name.startsWith('.env_') ||
        name.startsWith('.env.');
  }

  void _writeSettings(String output, String className, List<String>? include) {
    final file = File(p.join(projectDir, AppConfigSettings.configFileName));
    final settings = <String, Object>{
      'mode': 'generated',
      'output': output,
      if (className != AppConfigSettings.defaultClassName)
        'class_name': className,
      'exclude': AppConfigSettings.defaultExclude,
      if (include != null) 'include': include,
    };
    if (!file.existsSync() || file.readAsStringSync().trim().isEmpty) {
      file.writeAsStringSync('''
# udara_cli project settings
app_config:
  # "generated": client config is compiled into a Dart class per build.
  # "dotenv": the client's .env is bundled with the app (readable by anyone).
  mode: generated
  output: $output
${className != AppConfigSettings.defaultClassName ? '  class_name: $className\n' : ''}  # .env keys only the CLI needs; never compiled into the app.
  exclude: [${AppConfigSettings.defaultExclude.join(', ')}]
${include == null ? '' : '  # Keys your code reads; only these are compiled into the app. Add new ones here.\n  include: [${include.join(', ')}]\n'}''');
      return;
    }
    final editor = YamlEditor(file.readAsStringSync());
    editor.update(['app_config'], settings);
    file.writeAsStringSync(editor.toString());
  }

  /// Native build files that read the root `.env` (e.g. Gradle signing),
  /// with the keys they read when that can be seen.
  Map<String, List<String>> _nativeEnvReaders() {
    final candidates = [
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
      final keys = RegExp(r'''getProperty\(\s*['"]([A-Za-z0-9_]+)['"]''')
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet()
          .toList()
        ..sort();
      readers[rel] = keys;
    }
    return readers;
  }

  /// Flags that change the plan, so the printed --apply command matches it.
  List<String> _planFlags() => [
        if (argResults!['include-detected'] as bool) '--include-detected',
        if (argResults!.wasParsed('output')) ...[
          '--output',
          argResults!['output'] as String
        ],
        if (argResults!.wasParsed('class-name')) ...[
          '--class-name',
          argResults!['class-name'] as String
        ],
      ];

  void _requireCleanGit() {
    final ProcessResult result;
    try {
      result = Process.runSync('git', ['status', '--porcelain'],
          workingDirectory: projectDir);
    } catch (_) {
      return; // git not installed: nothing to check against
    }
    if (result.exitCode != 0) return; // not a git repository
    // "git checkout ." restores tracked files, so untracked files only matter
    // when the migration writes them (e.g. an uncommitted udara.yaml).
    final written = {
      'udara.yaml',
      'pubspec.yaml',
      '.gitignore',
      argResults!['output'] as String
    };
    final dirty = '${result.stdout}'
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .where((l) =>
            !l.startsWith('??') || written.contains(l.substring(3).trim()))
        .join('\n');
    if (dirty.isEmpty) return;
    throw BuildException(
      'You have uncommitted changes:\n$dirty',
      fix:
          'Commit or stash them first so "git checkout ." can undo the migration, '
          'or pass --allow-dirty.',
    );
  }
}

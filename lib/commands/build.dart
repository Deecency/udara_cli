import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

class BuildCommand extends UdaraCommand {
  BuildCommand() {
    argParser
      ..addMultiOption(
        'client',
        abbr: 'c',
        splitCommas: true,
        help: 'Client(s) to build. Repeat or comma-separate for a batch: '
            '--client apple,google',
      )
      ..addFlag(
        'all-clients',
        negatable: false,
        help: 'Build every client in the clients/ directory.',
      )
      ..addMultiOption(
        'platform',
        abbr: 'p',
        splitCommas: true,
        defaultsTo: ['android'],
        allowed: ['android', 'ios'],
        help: 'Target platform(s): --platform android,ios',
      )
      ..addMultiOption(
        'type',
        abbr: 't',
        splitCommas: true,
        defaultsTo: ['aab'],
        allowed: ['aab', 'apk'],
        help: 'Android build type(s): --type aab,apk '
            '(iOS always builds an IPA).',
      )
      ..addFlag(
        'test',
        negatable: false,
        help: 'Build using the test environment (.env_test).',
      )
      ..addFlag(
        'fail-fast',
        negatable: false,
        help: 'In a batch, stop at the first failed build instead of '
            'continuing with the rest.',
      )
      ..addFlag(
        'slack',
        negatable: false,
        help: 'Send Slack notifications during build process.',
      )
      ..addOption(
        'slack-channel',
        help:
            'Slack channel for notifications (e.g., #builds, @username). Defaults to #builds',
        defaultsTo: '#builds',
      );
  }

  @override
  final String name = 'build';

  @override
  final String description =
      '''Build whitelabeled versions of your Flutter app for one or more clients.

🎯 USAGE:
  udara_cli build --client <CLIENT_NAME> [OPTIONS]

📋 EXAMPLES:
  # Build Android AAB for 'apple' client (production)
  udara_cli build --client apple

  # Build an APK with the test environment and Slack notifications
  udara_cli build --client google --type apk --test --slack --slack-channel #dev-builds

  # Build iOS version
  udara_cli build --client microsoft --platform ios

  # Batch: two clients, AAB + APK + IPA each (6 builds)
  udara_cli build --client apple,google --platform android,ios --type aab,apk

  # Every client, Android App Bundles
  udara_cli build --all-clients

Batches run one client at a time: the client's branding is applied once,
each target is built, then the project is restored before the next client.
A failed build doesn't stop the batch unless --fail-fast is given.

Artifacts are collected in build/udara/<client>/. The project is always
restored afterwards, even when a build fails. Every build is recorded in
.udara_build_history.json.''';

  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;
  SlackService? slackService;

  late bool _isBatch;

  @override
  Future<void> run() async {
    final runStart = DateTime.now();

    config = ConfigService(projectDir);
    whiteLabel = WhiteLabelService(projectDir: projectDir, config: config);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    final isTest = argResults!['test'] as bool;
    final failFast = argResults!['fail-fast'] as bool;

    final plan = BuildPlan(
      clients: BuildPlan.resolveClients(
        argResults!['client'] as List<String>,
        allClients: argResults!['all-clients'] as bool,
        knownClients: await listClientNames(),
      ),
      targets: BuildPlan.resolveTargets(
        argResults!['platform'] as List<String>,
        argResults!['type'] as List<String>,
      ),
    );
    _isBatch = plan.isBatch;

    if (argResults!['slack'] as bool) {
      slackService =
          await initializeSlackService(argResults!['slack-channel'] as String);
    }

    if (_isBatch) {
      Logger.phase('Batch Build: ${plan.size} builds');
      for (final client in plan.clients) {
        Logger.info(
            '• $client: ${plan.targets.map((t) => t.label).join(', ')}');
      }
    }

    final results = <_BuildResult>[];
    for (final client in plan.clients) {
      final stopped = failFast && results.any((r) => r.failed);
      if (stopped) {
        results
            .addAll(plan.targets.map((t) => _BuildResult.skipped(client, t)));
        continue;
      }
      results.addAll(await _buildClient(client, plan.targets,
          isTest: isTest, failFast: failFast));
    }

    final failed = results.where((r) => r.failed).toList();
    if (_isBatch) {
      _printBatchSummary(results, DateTime.now().difference(runStart));
    } else {
      _printSingleSummary(results.single);
    }

    if (failed.isEmpty) return;
    if (!_isBatch) {
      // Keep the original error (and its fix) for single builds.
      final cause = failed.single.cause;
      throw cause is BuildException
          ? cause
          : BuildException(failed.single.error ?? 'Build failed.');
    }
    throw BuildException(
      '${failed.length} of ${results.length} builds failed.',
      fix: 'See the summary above, or run "udara_cli history" for the errors.',
    );
  }

  // ---------------------------------------------------------------------------
  // ONE CLIENT: brand once, build every target, restore
  // ---------------------------------------------------------------------------

  Future<List<_BuildResult>> _buildClient(
    String client,
    List<BuildTarget> targets, {
    required bool isTest,
    required bool failFast,
  }) async {
    final clientStart = DateTime.now();
    final results = <_BuildResult>[];
    final platformLabel = targets.map((t) => t.platform).toSet().join(',');
    String? version;

    try {
      final prepared = await _prepareClient(client, targets, isTest: isTest);
      version = prepared.version;

      for (final target in targets) {
        if (failFast && results.any((r) => r.failed)) {
          results.add(_BuildResult.skipped(client, target));
          continue;
        }
        // The first target carries the branding time, so the durations in
        // history add up to the wall-clock time of the run.
        final start = results.isEmpty ? clientStart : DateTime.now();
        results.add(await _buildTarget(client, target, prepared, start));
      }
    } catch (e, s) {
      final error = _logError(e, s, 'An unexpected error stopped the build.');
      await notifyBuildStep(slackService,
          step: 'Build Process',
          client: client,
          platform: platformLabel,
          status: 'failed',
          errorMessage: error);
      // Branding failed, so none of this client's remaining targets can run.
      final duration = DateTime.now().difference(clientStart);
      for (final target in targets.skip(results.length)) {
        results.add(_BuildResult.failed(
          client,
          target,
          version: version,
          duration: results.isEmpty ? duration : Duration.zero,
          error: error,
          cause: e,
        ));
      }
    } finally {
      _phase(client, 'Cleaning Up Project State');
      try {
        await cleanup.performFullCleanup();
      } catch (e) {
        Logger.warning(
            'Cleanup encountered an issue: $e. Run "udara_cli clean" to finish restoring the project.');
      }
    }

    for (final result in results.where((r) => !r.skipped)) {
      await config.appendBuildHistory(
        client: client,
        platform: result.target.platform,
        type: result.target.type,
        version: result.version,
        success: result.success,
        duration: result.duration,
        errorMessage: result.error,
        artifactPath: result.artifact?.path,
      );
      if (slackService != null && result.version != null) {
        await slackService!.sendBuildSummary(
          client: client,
          platform: result.target.platform,
          type: result.target.type,
          version: result.version!,
          success: result.success,
          buildTime: result.duration,
          errorMessage: result.error,
          artifactFile: result.artifact,
        );
      }
    }
    return results;
  }

  /// Phases 1-3: validate, stage the client's files, apply native branding
  /// and run `after_branding` hooks. Throws on any failure.
  Future<_PreparedClient> _prepareClient(
    String client,
    List<BuildTarget> targets, {
    required bool isTest,
  }) async {
    final platforms = targets.map((t) => t.platform).toSet();
    final platformLabel = platforms.join(',');

    // -------------------------------------------------------------------------
    // PHASE 1: VALIDATION & SETUP
    // -------------------------------------------------------------------------
    _phase(client, '1: Validation & Setup');

    checkProjectPrerequisites();
    await recoverInterruptedRun(cleanup);
    final envFile = await resolveClientEnvFile(client, isTest: isTest);
    final envFileName = p.basename(envFile.path);

    final version = await runStep(
        'Reading pubspec version', () => config.getPubspecVersion());

    await notifyBuildStep(slackService,
        step: 'Build Started',
        client: client,
        platform: platformLabel,
        status: 'started',
        additionalInfo:
            'Version: $version, Targets: ${targets.map((t) => t.label).join(', ')}');

    final envVars = await config.parseEnvFile(envFile);
    validateEnvVariables(client, envFileName, envVars);

    final appName = envVars['APP_NAME_PROD']!;
    final bundleId = envVars['BUNDLE_ID']!;
    final clientAssetsPath = envVars['ASSETS_PATH']!;
    final appIconPath = envVars['APP_ICON_PATH']!;
    final splashImagePath =
        _firstNonEmpty([envVars['APP_LOGO_PATH'], envVars['APP_ICON_PATH']])!;
    final teamId = envVars['DEVELOPMENT_TEAM'];

    // Validate udara.yaml up front so a typo fails before the long work.
    final hooks = HooksService(projectDir);
    hooks.load();
    final hookContext = HookContext(
      command: 'build',
      projectDir: projectDir,
      client: client,
      envFile: envFile,
      isTest: isTest,
      // Comma-separated when one branding pass serves several targets.
      platform: platformLabel,
      buildType: targets.map((t) => t.type).join(','),
      version: version,
      bundleId: bundleId,
      appName: appName,
    );

    Logger.success(
        'Validated "$client" ($envFileName): $appName · $bundleId · v$version');

    // -------------------------------------------------------------------------
    // PHASE 2: PROJECT CONFIGURATION
    // -------------------------------------------------------------------------
    _phase(client, '2: Project Configuration');
    await notifyBuildStep(slackService,
        step: 'Project Configuration',
        client: client,
        platform: platformLabel,
        status: 'started');

    await runStep('Creating backups', () async {
      await config.createBackup(File(p.join(projectDir, 'pubspec.yaml')));
      await config.createBackup(
          File(p.join(projectDir, 'flutter_launcher_icons.yaml')));
      if (config.pbxprojFile.existsSync()) {
        await config.createBackup(config.pbxprojFile);
      }
    });

    await runStep('Staging client environment as root .env',
        () => config.copyToRootEnv(envFile));

    await runStep('Updating launcher icon & splash configs', () async {
      await config.updateYamlValue(
          File(p.join(projectDir, 'flutter_launcher_icons.yaml')),
          ['flutter_launcher_icons', 'image_path'],
          appIconPath);

      await config.updateYamlValue(File(p.join(projectDir, 'pubspec.yaml')),
          ['splash_master', 'image'], splashImagePath);
    });

    await runStep('Syncing client branding assets & fonts', () async {
      await whiteLabel.syncBrandingAssets(client, clientAssetsPath);
      await whiteLabel.applyClientFonts(client, clientAssetsPath);
      await config.updatePubspecAssets(
          clientAssetPath: client, requiredExtraAssets: ['.env']);
    });

    if (platforms.contains('ios') && teamId != null && teamId.isNotEmpty) {
      await runStep('Applying iOS development team',
          () async => config.updateDevelopmentTeam(teamId: teamId));
    }

    Logger.success('Project assets configured successfully');

    // -------------------------------------------------------------------------
    // PHASE 3: RUNNING EXTERNAL TOOLS
    // -------------------------------------------------------------------------
    _phase(client, '3: Running Build Commands');

    await runStep(
        'Resolving dependencies (pub get)', () => runShell('flutter pub get'));

    await runStep(
        'Updating Bundle ID ($bundleId)',
        () => runShell(
            'dart run rename setBundleId --targets ios,android --value "$bundleId"'));

    await runStep(
        'Updating App Name ($appName)',
        () => runShell(
            'dart run rename setAppName --targets ios,android --value "$appName"'));

    await runStep('Generating Launcher Icons',
        () => runShell('dart run flutter_launcher_icons'));

    await runStep('Generating Native Splash Screens',
        () => runShell('dart run splash_master create'));

    await runStep('Applying OS-specific splash & icon patches',
        () => whiteLabel.cleanAndroidIconCache());

    await hooks.run(HookPoint.afterBranding, hookContext);

    return _PreparedClient(
        version: version, hooks: hooks, hookContext: hookContext);
  }

  /// Phase 4 for one target: `flutter build`, collect the artifact, run
  /// `after_build` hooks. Never throws; failures become a failed result.
  Future<_BuildResult> _buildTarget(
    String client,
    BuildTarget target,
    _PreparedClient prepared,
    DateTime start,
  ) async {
    _phase(client,
        _isBatch ? '4: Building ${target.label}' : '4: Building the App');
    try {
      await runStep(
          'Building ${target.platform} (${target.type.toUpperCase()})',
          () => runShell(
              '${target.flutterCommand} --dart-define=CLIENT_ENV=.env'));

      final artifact = await runStep(
          'Collecting ${target.type.toUpperCase()} artifact',
          () => whiteLabel.renameOutput(
              clientName: client,
              version: prepared.version,
              type: target.type));

      await prepared.hooks.run(
        HookPoint.afterBuild,
        prepared.hookContext.copyWith(
          platform: target.platform,
          buildType: target.type,
          artifact: artifact.path,
        ),
      );

      Logger.success('Built ${target.label} for "$client".');
      return _BuildResult.succeeded(
        client: client,
        target: target,
        version: prepared.version,
        duration: DateTime.now().difference(start),
        artifact: artifact,
      );
    } catch (e, s) {
      final error = _logError(e, s, 'An unexpected error stopped the build.');
      await notifyBuildStep(slackService,
          step: 'Build ${target.label}',
          client: client,
          platform: target.platform,
          status: 'failed',
          errorMessage: error);
      return _BuildResult.failed(
        client,
        target,
        version: prepared.version,
        duration: DateTime.now().difference(start),
        error: error,
        cause: e,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // OUTPUT
  // ---------------------------------------------------------------------------

  void _phase(String client, String name) =>
      Logger.phase(_isBatch ? '[$client] $name' : name);

  String _logError(Object e, StackTrace s, String fallback) {
    if (e is BuildException) {
      Logger.error(e.message,
          cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      return e.message;
    }
    Logger.error(fallback, cause: e, stackTrace: s);
    return e.toString();
  }

  void _printSingleSummary(_BuildResult r) {
    Logger.phase('Build Summary');
    Logger.info('Client:    ${r.client}');
    Logger.info(
        'Platform:  ${r.target.platform} (${r.target.type.toUpperCase()})');
    Logger.info('Version:   ${r.version ?? 'unknown'}');
    Logger.info('Duration:  ${_formatDuration(r.duration)}');
    if (r.artifact != null) {
      Logger.info(
          'Artifact:  ${p.relative(r.artifact!.path, from: projectDir)}');
    }
    if (r.success) {
      Logger.success('Build succeeded.');
    } else {
      Logger.warning(
          'Build failed. See the error above or run "udara_cli doctor --client ${r.client}".');
    }
  }

  void _printBatchSummary(List<_BuildResult> results, Duration total) {
    Logger.phase('Batch Summary');
    final clientWidth =
        results.map((r) => r.client.length).reduce((a, b) => a > b ? a : b);
    final targetWidth = results
        .map((r) => r.target.label.length)
        .reduce((a, b) => a > b ? a : b);

    for (final r in results) {
      final head =
          '${r.client.padRight(clientWidth)}  ${r.target.label.padRight(targetWidth)}';
      if (r.skipped) {
        Logger.skipped('$head  (not started: --fail-fast)');
      } else if (r.success) {
        Logger.success('$head  ${_formatDuration(r.duration).padLeft(7)}  '
            '${p.relative(r.artifact!.path, from: projectDir)}');
      } else {
        Logger.failure(
            '$head  ${_formatDuration(r.duration).padLeft(7)}  ${r.error}');
      }
    }

    final succeeded = results.where((r) => r.success).length;
    final failed = results.where((r) => r.failed).length;
    final skipped = results.where((r) => r.skipped).length;
    Logger.info('');
    Logger.info('$succeeded succeeded, $failed failed'
        '${skipped > 0 ? ', $skipped skipped' : ''} '
        'in ${_formatDuration(total)}. Artifacts: build/udara/');
  }

  String _formatDuration(Duration d) =>
      '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';

  String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }
}

class _PreparedClient {
  _PreparedClient({
    required this.version,
    required this.hooks,
    required this.hookContext,
  });

  final String version;
  final HooksService hooks;
  final HookContext hookContext;
}

class _BuildResult {
  _BuildResult.succeeded({
    required this.client,
    required this.target,
    required String this.version,
    required this.duration,
    required File this.artifact,
  })  : success = true,
        skipped = false,
        error = null,
        cause = null;

  _BuildResult.failed(
    this.client,
    this.target, {
    required this.version,
    required this.duration,
    required this.error,
    this.cause,
  })  : success = false,
        skipped = false,
        artifact = null;

  _BuildResult.skipped(this.client, this.target)
      : success = false,
        skipped = true,
        version = null,
        duration = Duration.zero,
        artifact = null,
        error = null,
        cause = null;

  final String client;
  final BuildTarget target;
  final bool success;
  final bool skipped;
  final String? version;
  final Duration duration;
  final File? artifact;
  final String? error;
  final Object? cause;

  bool get failed => !success && !skipped;
}

import 'dart:async';

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
      ..addMultiOption(
        'build-version',
        splitCommas: true,
        valueHelp: '[client=]x.y.z[+n]',
        help: 'Version to build, without editing pubspec.yaml. One value for '
            'every client (1.4.0+12), or per client (acme=1.4.0+12,beta=2.0.0). '
            'Without +n the pubspec build number is kept.',
      )
      ..addOption(
        'parallel',
        abbr: 'j',
        defaultsTo: 'auto',
        valueHelp: 'auto|N',
        help: 'How many builds run at the same time. "auto" picks 1-4 from '
            'your RAM and CPU cores; 1 builds one after another.',
      )
      ..addFlag(
        'test',
        negatable: false,
        help: 'Build using the test environment (.env_test).',
      )
      ..addFlag(
        'fail-fast',
        negatable: false,
        help:
            'Stop at the first failed build instead of continuing with the rest.',
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
      )
      ..addOption(
        'progress-file',
        valueHelp: 'path',
        help: 'Keep a JSON progress snapshot (percent, ETA, per-build state) '
            'in this file while building. Used by the IDE extensions.',
      )
      // Internal: used by parallel builds to run one job in a worker process.
      ..addOption('result-file', hide: true)
      ..addFlag('no-history', negatable: false, hide: true);
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

  # Build iOS version 2.1.0 (build number 45) without touching pubspec.yaml
  udara_cli build --client microsoft --platform ios --build-version 2.1.0+45

  # Batch: two clients, AAB + APK + IPA each, different versions, 2 at a time
  udara_cli build --client apple,google --platform android,ios --type aab,apk \\
      --build-version apple=1.4.0+12,google=3.0.1+7 --parallel 2

  # Every client's App Bundle
  udara_cli build --all-clients

Batches split into jobs of one client on one platform. With --parallel above
1, jobs run at the same time, each in its own copy of the project under
~/.udara_cli/workspaces/, with output in build/udara/logs/. A live progress
view shows percent and ETA, estimated from your build history.

Artifacts are collected in build/udara/<client>/. The project is always
restored afterwards, even when a build fails. Every build is recorded in
.udara_build_history.json.''';

  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;
  SlackService? slackService;

  /// Progress for single-job (in-process) runs.
  ProgressTracker? _tracker;
  String? _progressFile;
  bool _multiTarget = false;
  bool _cancelled = false;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);
    whiteLabel = WhiteLabelService(projectDir: projectDir, config: config);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    final isTest = argResults!['test'] as bool;
    final failFast = argResults!['fail-fast'] as bool;
    _progressFile = argResults!['progress-file'] as String?;

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
    final versions = BuildVersion.resolvePerClient(
        argResults!['build-version'] as List<String>, plan.clients);
    final parallel = _resolveParallel(argResults!['parallel'] as String);

    if (argResults!['slack'] as bool) {
      slackService =
          await initializeSlackService(argResults!['slack-channel'] as String);
    }

    final jobs = plan.jobs;
    final estimator = DurationEstimator(await config.loadBuildHistory());
    final runStart = DateTime.now();

    final List<TargetResult> results;
    if (jobs.length == 1) {
      results = await _runSingleJob(jobs.single, estimator,
          isTest: isTest,
          failFast: failFast,
          version: versions[jobs.single.client]);
    } else {
      results = await _runBatch(plan, jobs, estimator,
          isTest: isTest,
          failFast: failFast,
          versions: versions,
          parallel: parallel);
    }

    final resultFile = argResults!['result-file'] as String?;
    if (resultFile != null) TargetResult.writeAll(File(resultFile), results);

    final failed = results.where((r) => r.failed).toList();
    if (results.length > 1) {
      _printBatchSummary(results, DateTime.now().difference(runStart));
    } else {
      _printSingleSummary(results.single);
    }

    if (_cancelled) {
      Logger.warning(
          'Build cancelled. Finished artifacts are in build/udara/.');
      exit(130);
    }
    if (failed.isEmpty) return;
    if (results.length == 1) {
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

  int _resolveParallel(String value) {
    if (value == 'auto') return BatchRunner.autoParallel();
    final n = int.tryParse(value);
    if (n == null || n < 1) {
      throw UsageException(
          '--parallel must be "auto" or a number of at least 1 (got "$value").',
          usage);
    }
    return n;
  }

  // ---------------------------------------------------------------------------
  // BATCH: several jobs, run by worker processes
  // ---------------------------------------------------------------------------

  Future<List<TargetResult>> _runBatch(
    BuildPlan plan,
    List<BuildJob> jobs,
    DurationEstimator estimator, {
    required bool isTest,
    required bool failFast,
    required Map<String, String> versions,
    required int parallel,
  }) async {
    var slots = parallel.clamp(1, jobs.length);
    final workspaces = WorkspaceManager(projectDir);
    if (slots > 1) {
      final reason = workspaces.unsupportedReason();
      if (reason != null) {
        Logger.warning('Building one at a time: $reason, which isolated '
            'parallel workspaces do not support.');
        slots = 1;
      }
    }
    final useWorkspaces = slots > 1;

    // Parallel jobs run in copies; make sure the project itself is clean.
    await recoverInterruptedRun(cleanup);

    Logger.phase('Batch Build');
    Logger.info('${plan.size} builds in ${jobs.length} jobs '
        '(one client on one platform each), '
        '${slots == 1 ? 'one at a time' : '$slots at a time'}.');
    for (final job in jobs) {
      final version = versions[job.client];
      Logger.info('• ${job.label} (${job.types})'
          '${version != null ? ' · v$version' : ''}');
    }
    if (useWorkspaces) {
      Logger.info('Workspaces: ${workspaces.root.path}');
    }
    Logger.info(
        'Logs: ${p.join('build', 'udara', 'logs')}/<client>-<platform>.log');

    final tracker = ProgressTracker(
      jobs: [for (final job in jobs) JobProgress(job, estimator.job(job))],
      parallel: slots,
    );
    final runner = BatchRunner(
      projectDir: projectDir,
      tracker: tracker,
      view: ProgressView.forStdout(),
      useWorkspaces: useWorkspaces,
      failFast: failFast,
      progressFile: _progressFile,
      workerArgs: (job, resultFile, progressFile) => [
        if (Logger.verbose) '--verbose',
        'build',
        '--client',
        job.client,
        '--platform',
        job.platform,
        if (job.platform == 'android') ...['--type', job.types],
        if (isTest) '--test',
        if (versions[job.client] != null) ...[
          '--build-version',
          versions[job.client]!
        ],
        if (slackService != null) ...[
          '--slack',
          '--slack-channel',
          argResults!['slack-channel'] as String,
        ],
        '--no-history',
        '--result-file',
        resultFile,
        '--progress-file',
        progressFile,
      ],
    );

    final results = await runner.run();
    _cancelled = runner.cancelled;

    // Without workspaces, a cancelled worker may have left the project
    // branded; restore it now rather than on the next run.
    if (!useWorkspaces) await recoverInterruptedRun(cleanup);

    for (final r in results.where((r) => !r.skipped)) {
      await config.appendBuildHistory(
        client: r.client,
        platform: r.target.platform,
        type: r.target.type,
        version: r.version,
        success: r.success,
        duration: r.duration,
        errorMessage: r.error,
        artifactPath: r.artifact,
      );
    }
    return results;
  }

  // ---------------------------------------------------------------------------
  // SINGLE JOB: one client on one platform, in this process
  // ---------------------------------------------------------------------------

  Future<List<TargetResult>> _runSingleJob(
    BuildJob job,
    DurationEstimator estimator, {
    required bool isTest,
    required bool failFast,
    required String? version,
  }) async {
    _multiTarget = job.targets.length > 1;
    final progress = JobProgress(job, estimator.job(job))
      ..state = JobState.running
      ..step = 'Validating';
    final tracker = ProgressTracker(jobs: [progress], parallel: 1);
    progress.startedAt = tracker.startedAt;
    _tracker = tracker;

    // Stop cleanly on Ctrl+C or an IDE stop button: end the flutter/Gradle/
    // Xcode processes this build started and restore the project now.
    var cancelling = false;
    Future<void> onSignal(ProcessSignal signal) async {
      if (cancelling) exit(130);
      cancelling = true;
      Logger.warning(
          'Cancelling: stopping the build and restoring the project…');
      BatchRunner.killTree(pid, includeRoot: false);
      progress
        ..state = JobState.skipped
        ..finishedAt = tracker.now
        ..step = 'Cancelled';
      if (_progressFile != null) tracker.writeFile(_progressFile!);
      try {
        await cleanup.performFullCleanup();
      } catch (_) {}
      exit(130);
    }

    final signals = [
      ProcessSignal.sigint.watch().listen(onSignal),
      if (!Platform.isWindows) ...[
        ProcessSignal.sigterm.watch().listen(onSignal),
        ProcessSignal.sighup.watch().listen(onSignal),
      ],
    ];

    Timer? ticker;
    if (_progressFile != null) {
      tracker.writeFile(_progressFile!);
      ticker = Timer.periodic(
          const Duration(seconds: 1), (_) => tracker.writeFile(_progressFile!));
    }
    try {
      final results = await _buildClient(job.client, job.targets,
          isTest: isTest, failFast: failFast, requestedVersion: version);
      progress
        ..finishedAt = tracker.now
        ..targetsDone = results.where((r) => r.success).length
        ..state =
            results.any((r) => r.failed) ? JobState.failed : JobState.succeeded;
      return results;
    } finally {
      ticker?.cancel();
      for (final s in signals) {
        await s.cancel();
      }
      if (_progressFile != null) tracker.writeFile(_progressFile!);
    }
  }

  void _setStep(String step) {
    final tracker = _tracker;
    if (tracker == null) return;
    tracker.jobs.single.step = step;
    if (_progressFile != null) tracker.writeFile(_progressFile!);
  }

  Future<List<TargetResult>> _buildClient(
    String client,
    List<BuildTarget> targets, {
    required bool isTest,
    required bool failFast,
    required String? requestedVersion,
  }) async {
    final clientStart = DateTime.now();
    final results = <TargetResult>[];
    final platformLabel = targets.map((t) => t.platform).toSet().join(',');
    String? version;

    try {
      final prepared = await _prepareClient(client, targets,
          isTest: isTest, requestedVersion: requestedVersion);
      version = prepared.version.toString();

      for (final target in targets) {
        if (failFast && results.any((r) => r.failed)) {
          results.add(TargetResult.skipped(client, target,
              reason: 'stopped by --fail-fast'));
          continue;
        }
        // The first target carries the branding time, so the durations in
        // history add up to the wall-clock time of the run.
        final start = results.isEmpty ? clientStart : DateTime.now();
        results.add(await _buildTarget(client, target, prepared, start));
        _tracker?.jobs.single.targetsDone =
            results.where((r) => r.success).length;
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
        results.add(TargetResult(
          client: client,
          target: target,
          success: false,
          version: version,
          duration: results.isEmpty ? duration : Duration.zero,
          error: error,
          cause: e,
        ));
      }
    } finally {
      _setStep('Restoring project');
      _phase(client, 'Cleaning Up Project State');
      try {
        await cleanup.performFullCleanup();
      } catch (e) {
        Logger.warning(
            'Cleanup encountered an issue: $e. Run "udara_cli clean" to finish restoring the project.');
      }
    }

    final recordHistory = !(argResults!['no-history'] as bool);
    for (final result in results.where((r) => !r.skipped)) {
      if (recordHistory) {
        await config.appendBuildHistory(
          client: client,
          platform: result.target.platform,
          type: result.target.type,
          version: result.version,
          success: result.success,
          duration: result.duration,
          errorMessage: result.error,
          artifactPath: result.artifact,
        );
      }
      if (slackService != null && result.version != null) {
        await slackService!.sendBuildSummary(
          client: client,
          platform: result.target.platform,
          type: result.target.type,
          version: result.version!,
          success: result.success,
          buildTime: result.duration,
          errorMessage: result.error,
          artifactFile: result.artifact == null ? null : File(result.artifact!),
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
    required String? requestedVersion,
  }) async {
    final platforms = targets.map((t) => t.platform).toSet();
    final platformLabel = platforms.join(',');

    // -------------------------------------------------------------------------
    // PHASE 1: VALIDATION & SETUP
    // -------------------------------------------------------------------------
    _setStep('Validating');
    _phase(client, '1: Validation & Setup');

    checkProjectPrerequisites();
    await recoverInterruptedRun(cleanup);
    final envFile = await resolveClientEnvFile(client, isTest: isTest);
    final envFileName = p.basename(envFile.path);

    final pubspecVersion = await runStep(
        'Reading pubspec version', () => config.getPubspecVersion());
    final version = BuildVersion.effective(requestedVersion, pubspecVersion);

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
    final appConfig = AppConfigService(projectDir, config);
    final hookContext = HookContext(
      secretsFile: resolveSecretsFile(client, isTest: isTest),
      command: 'build',
      projectDir: projectDir,
      client: client,
      envFile: envFile,
      isTest: isTest,
      // Comma-separated when one branding pass serves several targets.
      platform: platformLabel,
      buildType: targets.map((t) => t.type).join(','),
      version: version.toString(),
      bundleId: bundleId,
      appName: appName,
    );

    Logger.success('Validated "$client" ($envFileName): $appName · $bundleId · '
        'v$version${requestedVersion != null ? ' (requested)' : ''}');
    if (!appConfig.settings.isGenerated) {
      Logger.info('App config: .env is bundled with the app as plain text. '
          'Run "udara_cli migrate-config" to compile it in instead.');
    }

    // -------------------------------------------------------------------------
    // PHASE 2: PROJECT CONFIGURATION
    // -------------------------------------------------------------------------
    _setStep('Applying branding');
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

    if (appConfig.settings.isGenerated) {
      await runStep(
          'Generating ${appConfig.settings.output}',
          () => appConfig.write(
              client: client, envFile: envFile, isTest: isTest));
      // Native tooling (Gradle signing, Xcode scripts) may still read the
      // root .env; it is not an app asset in this mode, so it can include
      // the build-time secrets.
      await runStep(
          'Staging root .env for native builds (not shipped)',
          () => config.stageNativeEnv(
              envFile, resolveSecretsFile(client, isTest: isTest)));
    } else {
      await runStep('Staging client environment as root .env',
          () => config.copyToRootEnv(envFile));
    }

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
        clientAssetPath: client,
        requiredExtraAssets:
            appConfig.settings.isGenerated ? const [] : ['.env'],
        keepDefaultEnv: !appConfig.settings.isGenerated,
      );
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

    _setStep('Resolving dependencies');
    await runStep(
        'Resolving dependencies (pub get)', () => runShell('flutter pub get'));

    _setStep('Applying bundle id, name, icons and splash');
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

    _setStep('Running after_branding hooks');
    await hooks.run(HookPoint.afterBranding, hookContext);

    return _PreparedClient(
      version: version,
      passVersion: requestedVersion != null,
      generatedConfig: appConfig.settings.isGenerated,
      hooks: hooks,
      hookContext: hookContext,
    );
  }

  /// Phase 4 for one target: `flutter build`, collect the artifact, run
  /// `after_build` hooks. Never throws; failures become a failed result.
  Future<TargetResult> _buildTarget(
    String client,
    BuildTarget target,
    _PreparedClient prepared,
    DateTime start,
  ) async {
    _setStep('Building ${target.label}');
    _phase(client,
        _multiTarget ? '4: Building ${target.label}' : '4: Building the App');
    try {
      final versionArgs = prepared.passVersion
          ? ' ${prepared.version.flutterArgs.join(' ')}'
          : '';
      await runStep(
          'Building ${target.platform} (${target.type.toUpperCase()})',
          () => runShell(
              // Generated config is compiled in; only dotenv mode needs to
              // tell the app which env file to load.
              '${target.flutterCommand}${prepared.generatedConfig ? '' : ' --dart-define=CLIENT_ENV=.env'}$versionArgs'));

      final artifact = await runStep(
          'Collecting ${target.type.toUpperCase()} artifact',
          () => whiteLabel.renameOutput(
              clientName: client,
              version: prepared.version.toString(),
              type: target.type));

      _setStep('Running after_build hooks');
      await prepared.hooks.run(
        HookPoint.afterBuild,
        prepared.hookContext.copyWith(
          platform: target.platform,
          buildType: target.type,
          artifact: artifact.path,
        ),
      );

      Logger.success('Built ${target.label} for "$client".');
      return TargetResult(
        client: client,
        target: target,
        success: true,
        version: prepared.version.toString(),
        duration: DateTime.now().difference(start),
        artifact: artifact.path,
      );
    } catch (e, s) {
      final error = _logError(e, s, 'An unexpected error stopped the build.');
      await notifyBuildStep(slackService,
          step: 'Build ${target.label}',
          client: client,
          platform: target.platform,
          status: 'failed',
          errorMessage: error);
      return TargetResult(
        client: client,
        target: target,
        success: false,
        version: prepared.version.toString(),
        duration: DateTime.now().difference(start),
        error: error,
        cause: e,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // OUTPUT
  // ---------------------------------------------------------------------------

  /// Phase header, with overall progress and time left for tracked runs.
  void _phase(String client, String name) {
    final tracker = _tracker;
    var title = _multiTarget ? '[$client] $name' : name;
    // Workers have no history to estimate from; the parent shows progress.
    final isWorker = argResults!['result-file'] != null;
    if (tracker != null && !isWorker && !tracker.jobs.single.isFinished) {
      title += ' · ${tracker.percentLabel()}% · '
          '~${formatDuration(tracker.eta())} left';
    }
    Logger.phase(title);
  }

  String _logError(Object e, StackTrace s, String fallback) {
    if (e is BuildException) {
      Logger.error(e.message,
          cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      return e.message;
    }
    Logger.error(fallback, cause: e, stackTrace: s);
    return e.toString();
  }

  void _printSingleSummary(TargetResult r) {
    Logger.phase('Build Summary');
    Logger.info('Client:    ${r.client}');
    Logger.info(
        'Platform:  ${r.target.platform} (${r.target.type.toUpperCase()})');
    Logger.info('Version:   ${r.version ?? 'unknown'}');
    Logger.info('Duration:  ${formatDuration(r.duration)}');
    if (r.artifact != null) {
      Logger.info('Artifact:  ${p.relative(r.artifact!, from: projectDir)}');
    }
    if (r.success) {
      Logger.success('Build succeeded.');
    } else {
      Logger.warning(
          'Build failed. See the error above or run "udara_cli doctor --client ${r.client}".');
    }
  }

  void _printBatchSummary(List<TargetResult> results, Duration total) {
    Logger.phase('Build Summary');
    final clientWidth =
        results.map((r) => r.client.length).reduce((a, b) => a > b ? a : b);
    final targetWidth = results
        .map((r) => r.target.label.length)
        .reduce((a, b) => a > b ? a : b);

    for (final r in results) {
      final head = '${r.client.padRight(clientWidth)}  '
          '${r.target.label.padRight(targetWidth)}  '
          '${(r.version == null ? '' : 'v${r.version}').padRight(12)}';
      if (r.skipped) {
        Logger.skipped('$head  ${r.error ?? 'not started'}');
      } else if (r.success) {
        Logger.success('$head  ${formatDuration(r.duration).padLeft(7)}  '
            '${p.relative(r.artifact!, from: projectDir)}');
      } else {
        Logger.failure(
            '$head  ${formatDuration(r.duration).padLeft(7)}  ${r.error}');
      }
    }

    // Show why each failed job failed, from its worker log.
    final failedLogs = results
        .where((r) => r.failed && r.logPath != null)
        .map((r) => r.logPath!)
        .toSet();
    for (final log in failedLogs) {
      Logger.info('');
      Logger.info('── $log (last lines) ──');
      for (final line in BatchRunner.tail(p.join(projectDir, log))) {
        Logger.info('   $line');
      }
    }

    final succeeded = results.where((r) => r.success).length;
    final failed = results.where((r) => r.failed).length;
    final skipped = results.where((r) => r.skipped).length;
    Logger.info('');
    Logger.info('$succeeded succeeded, $failed failed'
        '${skipped > 0 ? ', $skipped skipped' : ''} '
        'in ${formatDuration(total)}. Artifacts: build/udara/');
  }

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
    required this.passVersion,
    required this.hooks,
    required this.hookContext,
    required this.generatedConfig,
  });

  final BuildVersion version;

  /// Whether to pass --build-name/--build-number to flutter (only when a
  /// version was requested; otherwise Flutter reads pubspec itself).
  final bool passVersion;
  final HooksService hooks;
  final HookContext hookContext;

  /// Whether the app config is a generated class (no .env to point at).
  final bool generatedConfig;
}

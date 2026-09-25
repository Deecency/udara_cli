import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

class BuildCommand extends UdaraCommand {
  BuildCommand() {
    argParser
      ..addOption(
        'client',
        abbr: 'c',
        mandatory: true,
        help: 'The name of the client to build for (e.g., udara).',
      )
      ..addOption(
        'platform',
        abbr: 'p',
        defaultsTo: 'android',
        allowed: ['android', 'ios'],
        help: 'The target platform.',
      )
      ..addOption(
        'type',
        abbr: 't',
        defaultsTo: 'aab',
        allowed: ['aab', 'apk'],
        help:
            'The Android build type (ignored for iOS, which always builds an IPA).',
      )
      ..addFlag(
        'test',
        negatable: false,
        help: 'Build using the test environment (.env_test).',
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
      '''Build a whitelabeled version of your Flutter app for a specific client.

🎯 USAGE:
  udara_cli build --client <CLIENT_NAME> [OPTIONS]

📋 EXAMPLES:
  # Build Android AAB for 'apple' client (production)
  udara_cli build --client apple

  # Build an APK with the test environment and Slack notifications
  udara_cli build --client google --type apk --test --slack --slack-channel #dev-builds

  # Build iOS version
  udara_cli build --client microsoft --platform ios

The project is always restored to its original state afterwards, even when
the build fails. Every run is recorded in .udara_build_history.json.''';

  // Services
  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;
  SlackService? slackService;

  @override
  Future<void> run() async {
    final buildStartTime = DateTime.now();

    config = ConfigService(projectDir);
    whiteLabel = WhiteLabelService(projectDir: projectDir, config: config);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    final client = argResults!['client'] as String;
    final platform = argResults!['platform'] as String;
    final isTest = argResults!['test'] as bool;
    final enableSlack = argResults!['slack'] as bool;
    // iOS always produces an IPA; the --type flag only applies to Android.
    final type = platform == 'ios' ? 'ipa' : argResults!['type'] as String;

    String? version;
    String? errorMessage;
    File? builtFile;
    late HookContext hookContext;
    var buildSuccess = false;

    if (enableSlack) {
      slackService =
          await initializeSlackService(argResults!['slack-channel'] as String);
    }

    try {
      // -----------------------------------------------------------------------
      // PHASE 1: VALIDATION & SETUP
      // -----------------------------------------------------------------------
      Logger.phase('1: Validation & Setup');

      checkProjectPrerequisites();
      await recoverInterruptedRun(cleanup);
      final envFile = await resolveClientEnvFile(client, isTest: isTest);
      final envFileName = p.basename(envFile.path);

      version = await runStep(
          'Reading pubspec version', () => config.getPubspecVersion());

      await notifyBuildStep(slackService,
          step: 'Build Started',
          client: client,
          platform: platform,
          status: 'started',
          additionalInfo: 'Version: $version, Type: $type');

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
      hookContext = HookContext(
        command: 'build',
        projectDir: projectDir,
        client: client,
        envFile: envFile,
        isTest: isTest,
        platform: platform,
        buildType: type,
        version: version,
        bundleId: bundleId,
        appName: appName,
      );

      Logger.success(
          'Validated "$client" ($envFileName): $appName · $bundleId · v$version');

      // -----------------------------------------------------------------------
      // PHASE 2: PROJECT CONFIGURATION
      // -----------------------------------------------------------------------
      Logger.phase('2: Project Configuration');
      await notifyBuildStep(slackService,
          step: 'Project Configuration',
          client: client,
          platform: platform,
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

      if (platform == 'ios' && teamId != null && teamId.isNotEmpty) {
        await runStep('Applying iOS development team',
            () async => config.updateDevelopmentTeam(teamId: teamId));
      }

      Logger.success('Project assets configured successfully');

      // -----------------------------------------------------------------------
      // PHASE 3: RUNNING EXTERNAL TOOLS
      // -----------------------------------------------------------------------
      Logger.phase('3: Running Build Commands');

      await runStep('Resolving dependencies (pub get)',
          () => runShell('flutter pub get'));

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

      // -----------------------------------------------------------------------
      // PHASE 4: THE FINAL BUILD
      // -----------------------------------------------------------------------
      Logger.phase('4: Building the App');

      final buildCommand = switch (type) {
        'apk' => 'flutter build apk --release',
        'aab' => 'flutter build appbundle --release',
        _ => 'flutter build ipa',
      };

      await runStep('Building $platform (${type.toUpperCase()})',
          () => runShell('$buildCommand --dart-define=CLIENT_ENV=.env'));

      builtFile = await runStep(
          'Renaming ${type.toUpperCase()} artifact',
          () => whiteLabel.renameOutput(
              clientName: client, version: version!, type: type));

      await hooks.run(
          HookPoint.afterBuild, hookContext.withArtifact(builtFile!.path));

      buildSuccess = true;
      Logger.success('Build process completed successfully!');
    } catch (e, s) {
      buildSuccess = false;

      if (e is BuildException) {
        errorMessage = e.message;
        Logger.error(e.message,
            cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      } else {
        errorMessage = e.toString();
        Logger.error('An unexpected error stopped the build.',
            cause: e, stackTrace: s);
      }

      await notifyBuildStep(slackService,
          step: 'Build Process',
          client: client,
          platform: platform,
          status: 'failed',
          errorMessage: errorMessage);
      rethrow;
    } finally {
      // -----------------------------------------------------------------------
      // FINAL PHASE: CLEANUP (ALWAYS RUNS)
      // -----------------------------------------------------------------------
      Logger.phase('Cleaning Up Project State');

      try {
        await cleanup.performFullCleanup();
      } catch (e) {
        Logger.warning(
            'Cleanup encountered an issue: $e. Run "udara_cli clean" to finish restoring the project.');
      }

      final buildDuration = DateTime.now().difference(buildStartTime);

      await config.appendBuildHistory(
        client: client,
        platform: platform,
        type: type,
        version: version,
        success: buildSuccess,
        duration: buildDuration,
        errorMessage: errorMessage,
        artifactPath: builtFile?.path,
      );

      if (slackService != null && version != null) {
        await slackService!.sendBuildSummary(
          client: client,
          platform: platform,
          type: type,
          version: version,
          success: buildSuccess,
          buildTime: buildDuration,
          errorMessage: errorMessage,
          artifactFile: builtFile,
        );
      }

      _printSummary(
        client: client,
        platform: platform,
        type: type,
        version: version,
        success: buildSuccess,
        duration: buildDuration,
        artifact: builtFile,
      );
    }
  }

  void _printSummary({
    required String client,
    required String platform,
    required String type,
    required String? version,
    required bool success,
    required Duration duration,
    required File? artifact,
  }) {
    Logger.phase('Build Summary');
    Logger.info('Client:    $client');
    Logger.info('Platform:  $platform (${type.toUpperCase()})');
    Logger.info('Version:   ${version ?? 'unknown'}');
    Logger.info(
        'Duration:  ${duration.inMinutes}m ${duration.inSeconds % 60}s');
    if (artifact != null) {
      Logger.info('Artifact:  ${p.relative(artifact.path, from: projectDir)}');
    }
    if (success) {
      Logger.success('Build succeeded.');
    } else {
      Logger.warning(
          'Build failed. See the error above or run "udara_cli doctor --client $client".');
    }
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }
}

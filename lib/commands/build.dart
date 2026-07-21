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
        help: 'The Android build type.',
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
  # Build Android APK for 'apple' client (production)
  udara_cli build --client apple

  # Build test version with Slack notifications
  udara_cli build --client google --test --slack --slack-channel #dev-builds

  # Build iOS version
  udara_cli build --client microsoft --platform ios''';

  // Services
  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;
  SlackService? slackService;

  // State
  String? appNameForCleanup;
  DateTime? buildStartTime;
  File? builtFile;

  @override
  Future<void> run() async {
    buildStartTime = DateTime.now();

    // 1. Initialize Services
    config = ConfigService(projectDir);
    whiteLabel = WhiteLabelService(projectDir: projectDir, config: config);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    final client = argResults?['client'] as String;
    final platform = argResults?['platform'] as String;
    final type = argResults?['type'] as String;
    final isTest = argResults?['test'] as bool;
    final enableSlack = argResults?['slack'] as bool;

    String? version;
    String? errorMessage;
    bool buildSuccess = false;

    if (enableSlack) {
      slackService =
          await _initializeSlackService(argResults!['slack-channel']);
    }

    try {
      // -----------------------------------------------------------------------
      // PHASE 1: VALIDATION & SETUP
      // -----------------------------------------------------------------------
      Logger.phase('1: Validation & Setup');

      version = await _step('Reading pubspec version', () async {
        return await config.getPubspecVersion();
      });

      await _notifyBuildStep('Build Started', client, platform, 'started',
          additionalInfo: 'Version: $version, Type: $type');

      final envFileName = isTest ? '.env_test' : '.env';
      final envFile = File('$projectDir/clients/$client/$envFileName');

      if (!envFile.existsSync()) {
        throw BuildException(
          'Environment file missing for client "$client": $envFileName',
          fix: 'Create the missing file at "${envFile.path}".',
        );
      }

      final envVars = await config.parseEnvFile(envFile);
      await config.copyToRootEnv(envFile);

      final appName = envVars['APP_NAME_PROD'];
      final bundleId = envVars['BUNDLE_ID'];
      final clientAssetsPath = envVars['ASSETS_PATH'];
      final appIconPath = envVars['APP_ICON_PATH'];
      final teamId = envVars['DEVELOPMENT_TEAM'];

      _validateEnvVariables(client, envFileName, {
        'APP_NAME_PROD': appName,
        'BUNDLE_ID': bundleId,
        'ASSETS_PATH': clientAssetsPath,
        'APP_ICON_PATH': appIconPath,
      });

      appNameForCleanup = appName;
      Logger.success('Validated configuration for "$client" ($version)');

      // -----------------------------------------------------------------------
      // PHASE 2: PROJECT CONFIGURATION
      // -----------------------------------------------------------------------
      Logger.phase('2: Project Configuration');
      await _notifyBuildStep(
          'Project Configuration', client, platform, 'started');

      await _step('Creating backups', () async {
        await config.createBackup(File('$projectDir/pubspec.yaml'));
        await config
            .createBackup(File('$projectDir/flutter_launcher_icons.yaml'));

        final pbxprojFile =
            File('$projectDir/ios/Runner.xcodeproj/project.pbxproj');
        if (pbxprojFile.existsSync()) {
          await config.createBackup(pbxprojFile);
        }
      });

      await _step('Updating asset and launcher configs', () async {
        await config.updateYamlValue(
            File('$projectDir/flutter_launcher_icons.yaml'),
            ['flutter_launcher_icons', 'image_path'],
            appIconPath!);

        await config.updateYamlValue(File('$projectDir/pubspec.yaml'),
            ['splash_master', 'image'], appIconPath);
      });

      await _step('Syncing client branding assets & fonts', () async {
        await whiteLabel.syncBrandingAssets(client, clientAssetsPath!);
        await whiteLabel.applyClientFonts(clientAssetsPath);
        await config.updatePubspecAssets(
            clientAssetPath: client, requiredExtraAssets: ['.env']);
      });

      Logger.success('Project assets configured successfully');

      // -----------------------------------------------------------------------
      // PHASE 3: RUNNING EXTERNAL TOOLS
      // -----------------------------------------------------------------------
      Logger.phase('3: Running Build Commands');

      await _step('Resolving dependencies (pub get)',
          () => runShell('flutter pub get'));

      await _step(
          'Updating Bundle ID ($bundleId)',
          () => runShell(
              'dart run rename setBundleId --targets ios,android --value "$bundleId"'));

      await _step(
          'Updating App Name ($appName)',
          () => runShell(
              'dart run rename setAppName --targets ios,android --value "$appName"'));

      await _step('Generating Launcher Icons',
          () => runShell('dart run flutter_launcher_icons'));

      await _step('Generating Native Splash Screens',
          () => runShell('dart run splash_master create'));

      await _step('Applying OS-specific splash & icon patches', () async {
        //await whiteLabel.patchIosSplash(appName!);
        await whiteLabel.cleanAndroidIconCache();
      });

      // -----------------------------------------------------------------------
      // PHASE 4: THE FINAL BUILD
      // -----------------------------------------------------------------------
      Logger.phase('4: Building the App');

      if (platform == 'android') {
        final buildType = (type == 'aab') ? 'aab' : 'apk --release';
        await _step(
            'Building Android ($buildType)',
            () => runShell(
                'flutter build $buildType --dart-define=CLIENT_ENV=".env"'));

        builtFile = await _step('Renaming Android artifact', () async {
          return await whiteLabel.renameOutput(
              clientName: client, version: version ?? '1.0.0+1', type: type);
        });
      } else {
        if (teamId != null) {
          config.updateDevelopmentTeam(projectDir, teamId: teamId);
        }
        await _step(
            'Building iOS IPA',
            () =>
                runShell('flutter build ipa --dart-define=CLIENT_ENV=".env"'));
      }

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

      await _notifyBuildStep('Build Process', client, platform, 'failed',
          errorMessage: errorMessage);
      rethrow;
    } finally {
      // -----------------------------------------------------------------------
      // FINAL PHASE: CLEANUP (ALWAYS RUNS)
      // -----------------------------------------------------------------------
      Logger.phase('Cleaning Up Project State');

      try {
        await cleanup.performFullCleanup(
            appNameForCleanup: appNameForCleanup, fontsWereChanged: true);
        Logger.info('Project returned to default state.');
      } catch (e) {
        Logger.warning('Cleanup encountered an issue: $e. Run udara_cli clean');
      }

      final buildDuration = buildStartTime != null
          ? DateTime.now().difference(buildStartTime!)
          : Duration.zero;

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
    }
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  Future<T> _step<T>(String description, Future<T> Function() action) async {
    Logger.info('Running: $description...');
    try {
      final result = await action();
      return result;
    } on BuildException {
      rethrow;
    } catch (e, s) {
      throw BuildException(
        'Failed step: "$description"',
        fix: 'Check task logs above or underlying system prerequisites.',
        originalStackTrace: s,
      );
    }
  }

  void _validateEnvVariables(
      String client, String file, Map<String, String?> vars) {
    final missing = vars.entries
        .where((entry) => entry.value == null || entry.value!.trim().isEmpty)
        .map((entry) => entry.key)
        .toList();

    if (missing.isNotEmpty) {
      throw BuildException(
        'Missing required variables in $file for client "$client": ${missing.join(', ')}',
        fix: 'Add ${missing.join(', ')} to clients/$client/$file',
      );
    }
  }

  /// Initialize Slack service from stored configuration
  Future<SlackService?> _initializeSlackService(String channel) async {
    final slackToken = await ConfigService.getSlackBotToken();

    if (slackToken == null) {
      Logger.warning(
          'Slack notifications disabled (not configured). Run "udara_cli setup" to enable.');
      return null;
    }

    Logger.info('Slack notifications enabled for channel: $channel');
    return SlackService(
      botToken: slackToken,
      channel: channel,
      debugMode: Logger.verbose,
    );
  }

  /// Helper method to send build step notifications
  Future<void> _notifyBuildStep(
    String step,
    String client,
    String platform,
    String status, {
    String? additionalInfo,
    String? errorMessage,
  }) async {
    if (slackService == null) return;

    try {
      await slackService!.sendBuildStepNotification(
        step: step,
        client: client,
        platform: platform,
        status: status,
        additionalInfo: additionalInfo,
        errorMessage: errorMessage,
      );
    } catch (e) {
      Logger.warning('Failed to send Slack notification: $e');
    }
  }
}

import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/core/helper.dart';

import 'services/config_service.dart';
import 'services/slack_service.dart';

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
    udara_cli build --client microsoft --platform ios

  🔧 WHAT THIS DOES:
    1. Loads client-specific configuration (.env or .env_test)
    2. Updates app name, bundle ID, and branding
    3. Generates custom icons and splash screens
    4. Builds the app with client-specific assets
    5. Renames output files with client name and version
    6. Sends Slack notifications (if enabled)
    7. Cleans up temporary changes and reverts project to default state

  ⚠️  PREREQUISITES:
    • Project must be set up with "udara_cli setup"
    • Client directory must exist in clients/ folder
    • Client must have valid .env and asset files''';

  File? pubspecBackup;
  File? iconsYamlBackup;
  Directory? copiedAssetsDir;

  File? rootEnvFile;

  Directory? defaultFontsBackupDir;
  bool clientFontsCopied = false;
  bool iconsGenerated = false;
  Directory? renamedSplashAssetsDir;
  String? appNameForCleanup;
  bool templatesWereAdded = false;
  SlackService? slackService;
  DateTime? buildStartTime;
  File? builtApkFile;

  @override
  Future<void> run() async {
    buildStartTime = DateTime.now();

    // Add these to your existing variable declarations
    final enableSlack = argResults!['slack'] as bool;
    final slackChannel = argResults!['slack-channel'] as String;
    final client = argResults!['client'] as String;

    final platform = argResults!['platform'] as String;

    final type = argResults!['type'] as String;

    final isTest = argResults!['test'] as bool;

    final helper = Helper(this);

    String? version;
    String? errorMessage;
    bool buildSuccess = false;

    // Initialize Slack service if enabled
    if (enableSlack) {
      slackService = await _initializeSlackService(slackChannel);
    }

    try {
      // PHASE 1: VALIDATION & SETUP

      version = await helper.getVersionFromPubspec();

      await _notifyBuildStep('Build Started', client, platform, 'started',
          additionalInfo:
              'Version: $version, Type: $type${isTest ? ' (Test)' : ''}');

      print('--- ⚙️ Phase 1: Validation & Setup ---');

      await _notifyBuildStep('Validation & Setup', client, platform, 'started');

      final envVars = await helper.setupEnvironment(client, isTest);

      final appIconPath = envVars['APP_ICON_PATH']!;

      final appName = envVars['APP_NAME_PROD']!;

      final bundleId = envVars['BUNDLE_ID']!;

      this.appNameForCleanup = appName;

      final clientAssetsPath = envVars['ASSETS_PATH']!;

      await _notifyBuildStep(
          'Validation & Setup', client, platform, 'completed');

      print('\n--- ✏️ Phase 2: Project Configuration ---');

      await _notifyBuildStep(
          'Project Configuration', client, platform, 'started');

      //await helper.ensureConfig();

      await helper.backupAndModifyPubspec(clientAssetsPath, appIconPath);

      await helper.handleClientFonts(clientAssetsPath);

      await helper.copyClientAssets(clientAssetsPath);

      await _notifyBuildStep(
          'Project Configuration', client, platform, 'completed');

      print('\n--- 🚀 Phase 3: Running Build Commands ---');

      await runShell('flutter pub get');

      await runShell(
          'dart run rename setBundleId --targets ios,android --value "$bundleId"');

      await runShell(
          'dart run rename setAppName --targets ios,android --value "$appName"');

      await runShell('dart run flutter_launcher_icons');

      await runShell('dart run splash_master create');

      await helper.updateIosSplash(appName);

      iconsGenerated = true;

      await helper.fixAndroidIconBug();

      // PHASE 4: THE FINAL BUILD

      print('\n--- 📦 Phase 4: Building the App using ---');

      await _notifyBuildStep('Building the App', client, platform, 'started');

      if (platform == 'android') {
        final buildType = (type == 'aab') ? 'aab' : 'apk --release';

        await runShell(
          'flutter build $buildType --dart-define=CLIENT_ENV=".env"',
        );

        print('\n--- 📝 Renaming APK file ---');
        final version = await helper.getVersionFromPubspec();
        builtApkFile = await helper.renameApk('${client}_$version', type);
        print('✅ APK renamed to: ${client}_$version.$type');
      } else {
        await runShell(
          'flutter build ipa --dart-define=CLIENT_ENV=".env"',
        );
      }
      buildSuccess = true;
      print('\n✅✅✅ Build process completed successfully! ✅✅✅');
    } catch (e) {
      buildSuccess = false;
      errorMessage = e.toString();
      await _notifyBuildStep('Build Process', client, platform, 'failed',
          errorMessage: errorMessage);
    } finally {
      // FINAL PHASE: CLEANUP (ALWAYS RUNS)

      print('\n--- 🧹 Final Phase: Cleaning Up ---');

      await helper.cleanup();
      if (slackService != null && version != null) {
        final buildDuration = DateTime.now().difference(buildStartTime!);
        await slackService!.sendBuildSummary(
          client: client,
          platform: platform,
          type: type,
          version: version,
          success: buildSuccess,
          buildTime: buildDuration,
          errorMessage: errorMessage,
          artifactFile: builtApkFile,
        );
      }
      buildSuccess = false;
    }
  }

  // Add these new methods to your BuildCommand class:

  /// Initialize Slack service from stored configuration
  Future<SlackService?> _initializeSlackService(String channel) async {
    final slackToken = await ConfigService.getSlackBotToken();

    if (slackToken == null) {
      print(
          '⚠️ Slack not configured. Run "udara_cli setup" to enable Slack notifications.');
      return null;
    }

    print('📱 Slack notifications enabled. Channel: $channel');
    return SlackService(
      botToken: slackToken,
      channel: channel,
      debugMode: true,
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
      print('Failed to send Slack notification: $e');
    }
  }
}

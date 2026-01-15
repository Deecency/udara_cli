import 'package:udara_cli/core/core.dart';

class WhiteLabelCommand extends UdaraCommand {
  WhiteLabelCommand() {
    argParser
      ..addOption(
        'client',
        abbr: 'c',
        mandatory: true,
        help: 'The name of the client to build for (e.g., udara).',
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
  final String name = 'whitelabel';

  @override
  final String description =
      ''' Whitelabel the app with client-specific assets, app name, bundle ID, branding, custom icons and splash screens.

  🎯 USAGE:
    udara_cli whitelabel --client <CLIENT_NAME> [OPTIONS]

  📋 EXAMPLES:
   
    # Whitelable a test version with Slack notifications
    udara_cli whitelabel --client google --test --slack --slack-channel #dev-builds

    
  🔧 WHAT THIS DOES:
    1. Loads client-specific configuration (.env or .env_test)
    2. Whitelabel the app with client-specific assets, app name, bundle ID, branding, custom icons and splash screens.
    3. Sends Slack notifications (if enabled)
    4. Cleans up temporary changes and reverts project to default state

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
  File? builtApkFile;

  // Services
  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;

  // Build State
  DateTime? buildStartTime;
  File? builtFile;

  @override
  Future<void> run() async {
    buildStartTime = DateTime.now();

    // 1. Initialize Services
    config = ConfigService(projectDir);
    whiteLabel = WhiteLabelService(projectDir: projectDir, config: config);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    final client = argResults!['client'] as String;
    final isTest = argResults!['test'] as bool;
    final enableSlack = argResults!['slack'] as bool;

    String? version;
    String? errorMessage;
    bool buildSuccess = false;

    if (enableSlack) {
      slackService =
          await _initializeSlackService(argResults!['slack-channel']);
    }
    try {
      // PHASE 1: VALIDATION & SETUP
      print('--- ⚙️ Phase 1: Validation & Setup ---');
      version = await config.getPubspecVersion();
      await _notifyBuildStep('Whitelabel Started', client, '', 'started',
          additionalInfo: 'Version: $version, Type: ' '');

      final envVars = await config.parseEnvFile(
          File('$projectDir/clients/$client/${isTest ? '.env_test' : '.env'}'));

      await config.copyToRootEnv(
          File('$projectDir/clients/$client/${isTest ? '.env_test' : '.env'}'));

      final appName = envVars['APP_NAME_PROD']!;
      final bundleId = envVars['BUNDLE_ID']!;
      final clientAssetsPath = envVars['ASSETS_PATH']!;
      final appIconPath = envVars['APP_ICON_PATH']!;

      // PHASE 2: PROJECT CONFIGURATION
      print('\n--- ✏️ Phase 2: Project Configuration ---');
      await _notifyBuildStep('Project Configuration', client, '', 'started');

      await config.createBackup(File('$projectDir/pubspec.yaml'));
      await config
          .createBackup(File('$projectDir/flutter_launcher_icons.yaml'));

      await config.updateYamlValue(
          File('$projectDir/flutter_launcher_icons.yaml'),
          ['flutter_launcher_icons', 'image_path'],
          appIconPath);

      print(
          'Updated `flutter_launcher_icons.yaml` image_path to `$appIconPath`');

      await whiteLabel.syncBrandingAssets(client, clientAssetsPath);
      await whiteLabel.applyClientFonts(clientAssetsPath);

      // Update YAMLs via Config Service
      await config.updatePubspecAssets(
          clientAssetPath: client, requiredExtraAssets: ['.env']);

      // PHASE 3: RUNNING EXTERNAL TOOLS
      print('\n--- 🚀 Phase 3: Running Build Commands ---');
      await runShell('flutter pub get');
      await runShell(
          'dart run rename setBundleId --targets ios,android --value "$bundleId"');
      await runShell(
          'dart run rename setAppName --targets ios,android --value "$appName"');
      await runShell('dart run flutter_launcher_icons');
      await runShell('dart run splash_master create');

      await whiteLabel.patchIosSplash(appName);
      await whiteLabel.cleanAndroidIconCache();

      buildSuccess = true;
      print('\n✅✅✅ Whitelabelling process completed successfully! ✅✅✅');
    } catch (e) {
      buildSuccess = false;
      errorMessage = e.toString();
      await _notifyBuildStep('Build Process', client, '', 'failed',
          errorMessage: errorMessage);
      rethrow; // Ensure cleanup runs but user sees the error
    } finally {
      // FINAL PHASE: CLEANUP (ALWAYS RUNS)

      print('\n--- 🧹 Final Phase: Cleaning Up ---');

      await cleanup.performFullCleanup(
        appNameForCleanup: client,
        fontsWereChanged: true,
      );
      if (slackService != null && version != null) {
        final buildDuration = DateTime.now().difference(buildStartTime!);
        await slackService!.sendBuildSummary(
          client: client,
          platform: '',
          type: '',
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

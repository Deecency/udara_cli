import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

/// Applies a client's native branding (app name, bundle id, icons, splash)
/// to the project. By default the project files it touches (pubspec, icon
/// config, root .env, branding assets) are restored afterwards; with
/// `--keep` they stay applied so the app can be run as that client.
class WhiteLabelCommand extends UdaraCommand {
  WhiteLabelCommand() {
    argParser
      ..addOption(
        'client',
        abbr: 'c',
        mandatory: true,
        help: 'The name of the client to whitelabel the project as.',
      )
      ..addFlag(
        'test',
        negatable: false,
        help: 'Use the test environment (.env_test).',
      )
      ..addFlag(
        'keep',
        abbr: 'k',
        negatable: false,
        help: 'Leave the root .env, branding assets and pubspec changes in '
            'place so the app can be run as this client '
            '(flutter run --dart-define=CLIENT_ENV=.env). '
            'Without it they are restored once the native branding is applied.',
      )
      ..addFlag(
        'slack',
        negatable: false,
        help: 'Send Slack notifications during the process.',
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
      '''Whitelabel the app with client-specific assets, app name, bundle ID, branding, custom icons and splash screens.

Native changes (app name, bundle id, launcher icons, splash, iOS team) always
persist. Project files the CLI stages (root .env, assets/branding/<client>,
pubspec.yaml, flutter_launcher_icons.yaml) are restored afterwards unless
--keep is given, in which case the project stays runnable as the client:
  flutter run --dart-define=CLIENT_ENV=.env
Run "udara_cli clean" to restore the project files again.

  USAGE:
  udara_cli whitelabel --client <CLIENT_NAME> [OPTIONS]

  EXAMPLES:
  # Apply google's native branding, restore project files afterwards
  udara_cli whitelabel --client google

  # Brand the project as google (test env) and keep it that way for flutter run
  udara_cli whitelabel --client google --test --keep''';

  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;
  SlackService? slackService;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);
    whiteLabel = WhiteLabelService(projectDir: projectDir, config: config);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    final client = argResults!['client'] as String;
    final isTest = argResults!['test'] as bool;
    final keep = argResults!['keep'] as bool;
    final enableSlack = argResults!['slack'] as bool;

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

      final version = await runStep(
          'Reading pubspec version', () => config.getPubspecVersion());

      await notifyBuildStep(slackService,
          step: 'Whitelabel Started',
          client: client,
          platform: '',
          status: 'started',
          additionalInfo: 'Version: $version');

      final envVars = await config.parseEnvFile(envFile);
      validateEnvVariables(client, envFileName, envVars);

      final appName = envVars['APP_NAME_PROD']!;
      final bundleId = envVars['BUNDLE_ID']!;
      final clientAssetsPath = envVars['ASSETS_PATH']!;
      final appIconPath = envVars['APP_ICON_PATH']!;
      final splashImagePath = (envVars['APP_LOGO_PATH'] ?? '').trim().isEmpty
          ? appIconPath
          : envVars['APP_LOGO_PATH']!;
      final teamId = envVars['DEVELOPMENT_TEAM'];

      // Validate udara.yaml up front so a typo fails before the long work.
      final hooks = HooksService(projectDir);
      hooks.load();

      Logger.success(
          'Validated "$client" ($envFileName): $appName · $bundleId · v$version');

      // -----------------------------------------------------------------------
      // PHASE 2: PROJECT CONFIGURATION
      // -----------------------------------------------------------------------
      Logger.phase('2: Project Configuration');
      await notifyBuildStep(slackService,
          step: 'Project Configuration',
          client: client,
          platform: '',
          status: 'started');

      if (!keep) {
        // The iOS project file is deliberately not backed up: restoring it
        // would undo the bundle id and team changes that must persist.
        await runStep('Creating backups', () async {
          await config.createBackup(File(p.join(projectDir, 'pubspec.yaml')));
          await config.createBackup(
              File(p.join(projectDir, 'flutter_launcher_icons.yaml')));
        });
      }

      await runStep('Staging client environment as root .env',
          () => config.copyToRootEnv(envFile, trackForCleanup: !keep));

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

      if (teamId != null &&
          teamId.isNotEmpty &&
          config.pbxprojFile.existsSync()) {
        await runStep('Applying iOS development team',
            () async => config.updateDevelopmentTeam(teamId: teamId));
      }

      Logger.success('Project dynamic assets configured successfully');

      // -----------------------------------------------------------------------
      // PHASE 3: RUNNING EXTERNAL TOOLS
      // -----------------------------------------------------------------------
      Logger.phase('3: Running Tools & Generating Assets');

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

      await runStep('Cleaning Android icon cache',
          () => whiteLabel.cleanAndroidIconCache());

      await hooks.run(
        HookPoint.afterBranding,
        HookContext(
          command: 'whitelabel',
          projectDir: projectDir,
          client: client,
          envFile: envFile,
          isTest: isTest,
          version: version,
          bundleId: bundleId,
          appName: appName,
        ),
      );

      Logger.success('Whitelabeling process completed successfully!');

      await notifyBuildStep(slackService,
          step: 'Whitelabel Process',
          client: client,
          platform: '',
          status: 'completed');

      Logger.phase('Next Steps');
      if (keep) {
        Logger.info('The project is now branded as "$client". Run it with:');
        Logger.info('  flutter run --dart-define=CLIENT_ENV=.env');
        Logger.info(
            'Run "udara_cli clean" to restore the project files again.');
      } else {
        Logger.info(
            'Native branding for "$client" is applied; staged project files are being restored.');
        Logger.info(
            'Use "udara_cli whitelabel --client $client --keep" to keep the project runnable as this client.');
      }
    } catch (e, s) {
      final String errorMessage;
      if (e is BuildException) {
        errorMessage = e.message;
        Logger.error(e.message,
            cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      } else {
        errorMessage = e.toString();
        Logger.error('An unexpected error occurred during whitelabeling.',
            cause: e, stackTrace: s);
      }

      await notifyBuildStep(slackService,
          step: 'Whitelabel Process',
          client: client,
          platform: '',
          status: 'failed',
          errorMessage: errorMessage);
      rethrow;
    } finally {
      if (!keep) {
        Logger.phase('Cleaning Up Project State');
        try {
          await cleanup.performFullCleanup();
        } catch (e) {
          Logger.warning(
              'Cleanup encountered an issue: $e. Run "udara_cli clean" to finish restoring the project.');
        }
      }
    }
  }
}

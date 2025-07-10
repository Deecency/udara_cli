import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/core/helper.dart';

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
      );
  }

  @override
  final String name = 'build';

  @override
  final String description =
      'Builds a whitelabel of the Flutter project for a specific client. To run example -> `udara_cli build --client clientA --platform android --test`';

  File? pubspecBackup;
  Directory? copiedAssetsDir;

  File? rootEnvFile;

  Directory? defaultFontsBackupDir;
  bool clientFontsCopied = false;
  bool iconsGenerated = false;
  Directory? renamedSplashAssetsDir;
  String? appNameForCleanup;
  bool templatesWereAdded = false;

  @override
  Future<void> run() async {
    final client = argResults!['client'] as String;

    final platform = argResults!['platform'] as String;

    final type = argResults!['type'] as String;

    final isTest = argResults!['test'] as bool;

    final helper = Helper(this);

    try {
      // PHASE 1: VALIDATION & SETUP

      print('--- ⚙️ Phase 1: Validation & Setup ---');

      final envVars = await helper.setupEnvironment(client, isTest);

      final appIconPath = envVars['APP_ICON_PATH']!;

      final appName = envVars['APP_NAME_PROD']!;

      final bundleId = envVars['BUNDLE_ID']!;

      this.appNameForCleanup = appName;

      final clientAssetsPath = envVars['ASSETS_PATH']!;
      print('\n--- ✏️ Phase 2: Project Configuration ---');

      await helper.ensureConfig();

      await helper.backupAndModifyPubspec(clientAssetsPath, appIconPath);

      await helper.handleClientFonts(clientAssetsPath);

      await helper.copyClientAssets(clientAssetsPath);

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

      if (platform == 'android') {
        final buildType = (type == 'aab') ? 'aab' : 'apk --release';

        await runShell(
          'flutter build $buildType --dart-define=CLIENT_ENV=".env"',
        );
      } else {
        await runShell(
          'flutter build ipa --dart-define=CLIENT_ENV=".env"',
        );
      }

      print('\n✅✅✅ Build process completed successfully! ✅✅✅');
    } finally {
      // FINAL PHASE: CLEANUP (ALWAYS RUNS)

      print('\n--- 🧹 Final Phase: Cleaning Up ---');

      await helper.cleanup();
    }
  }
}

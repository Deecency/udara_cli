import '../core/core.dart';

class CleanCommand extends UdaraCommand {
  @override
  final name = 'clean';
  @override
  final description = 'Runs `flutter clean` on the project.';

  late CleanupService cleanup;
  late ConfigService config;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);
    cleanup = CleanupService(projectDir: projectDir, config: config);

    await cleanup.performFullCleanup(fontsWereChanged: true);

    Logger.info('Cleaning project...');
    await runShell('flutter clean');
    Logger.success('Project cleaned successfully.');
  }
}

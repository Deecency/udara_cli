import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

/// Regenerates the committed app config class, e.g. after adding a key to
/// a client's `.env`, without branding or cleaning anything.
class GenerateConfigCommand extends UdaraCommand {
  GenerateConfigCommand() {
    argParser
      ..addOption(
        'client',
        abbr: 'c',
        defaultsTo: WhiteLabelService.defaultClientName,
        help: 'Client whose values the file gets. Commit the default '
            "client's: it is what plain `flutter run` uses.",
      )
      ..addFlag(
        'test',
        negatable: false,
        help: "Use the client's .env_test.",
      );
  }

  @override
  final String name = 'generate-config';

  @override
  final String description =
      '''Regenerate the app config class (lib/udara_config.g.dart) from the client .env files.

Run it after adding, renaming or removing a key in any client's .env or
.env_test, so your code and IDE see the new fields, then commit the file.
Builds and "whitelabel" regenerate it on their own; this only refreshes the
checked-in copy. Needs "app_config: mode: generated" in udara.yaml.''';

  @override
  Future<void> run() async {
    final client = argResults!['client'] as String;
    final isTest = argResults!['test'] as bool;
    final config = ConfigService(projectDir);
    final appConfig = AppConfigService(projectDir, config);

    if (!appConfig.settings.isGenerated) {
      throw BuildException(
        'This project uses dotenv mode; there is no generated config file.',
        fix: 'Run "udara_cli migrate-config" to switch to generated config.',
      );
    }

    // A Run Client (--keep) backed up the file; restore the original project
    // first, or its next restore would bring the stale file back.
    await recoverInterruptedRun(
        CleanupService(projectDir: projectDir, config: config));

    final envFile = await resolveClientEnvFile(client, isTest: isTest);
    final file = appConfig.outputFile;
    final before = file.existsSync() ? file.readAsStringSync() : null;
    await appConfig.write(
        client: client,
        envFile: envFile,
        isTest: isTest,
        trackForCleanup: false);
    final output = appConfig.settings.output;
    final source = p.relative(envFile.path, from: projectDir);

    if (before == file.readAsStringSync()) {
      Logger.success('$output is already up to date ($source).');
    } else {
      Logger.success('Regenerated $output from $source.');
      if (client != WhiteLabelService.defaultClientName || isTest) {
        Logger.info('Commit the default client\'s version: run '
            '"udara_cli generate-config" before committing.');
      } else {
        Logger.info('Commit it so plain "flutter run" and the analyzer see '
            'the same fields.');
      }
    }

    if (!await appConfig.ensureOutputTracked()) {
      Logger.warning('git still ignores $output, so it is never committed and '
          'fresh clones don\'t compile. Check "git check-ignore -v $output".');
    }

    final leftOut = appConfig.keysMissingFromInclude();
    if (leftOut.isNotEmpty) {
      Logger.warning('Not compiled in because app_config.include in '
          'udara.yaml doesn\'t list them: ${leftOut.join(', ')}. Add the '
          'ones the app reads (they are null at runtime until you do).');
    }
  }
}

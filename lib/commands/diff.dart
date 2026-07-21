import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

/// Compares the environment variables of two clients side by side, useful
/// for debugging "why does clientB behave differently from clientA".
class DiffCommand extends UdaraCommand {
  DiffCommand() {
    argParser
      ..addOption(
        'client-a',
        abbr: 'a',
        mandatory: true,
        help: 'First client to compare.',
      )
      ..addOption(
        'client-b',
        abbr: 'b',
        mandatory: true,
        help: 'Second client to compare.',
      )
      ..addFlag(
        'test',
        negatable: false,
        help: 'Compare .env_test files instead of .env.',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Show every key, including ones that match.',
      );
  }

  @override
  final String name = 'diff';

  @override
  final String description =
      '''Compare environment configuration between two clients.

  USAGE:
  udara_cli diff --client-a <NAME> --client-b <NAME> [OPTIONS]

  EXAMPLES:
  # Compare production .env for two clients
  udara_cli diff --client-a apple --client-b google

  # Compare .env_test files instead
  udara_cli diff --client-a apple --client-b google --test

  # Show every key, not just the ones that differ
  udara_cli diff --client-a apple --client-b google --all''';

  late ConfigService config;

  @override
  Future<void> run() async {
    config = ConfigService(projectDir);

    final clientA = argResults!['client-a'] as String;
    final clientB = argResults!['client-b'] as String;
    final isTest = argResults!['test'] as bool;
    final showAll = argResults!['all'] as bool;
    final envFileName = isTest ? '.env_test' : '.env';

    final envFileA = File(p.join(projectDir, 'clients', clientA, envFileName));
    final envFileB = File(p.join(projectDir, 'clients', clientB, envFileName));

    if (!envFileA.existsSync()) {
      throw BuildException(
        '$envFileName not found for client "$clientA"',
        fix: 'Run "udara_cli setup --clients $clientA" to create it.',
      );
    }
    if (!envFileB.existsSync()) {
      throw BuildException(
        '$envFileName not found for client "$clientB"',
        fix: 'Run "udara_cli setup --clients $clientB" to create it.',
      );
    }

    final varsA = await config.parseEnvFile(envFileA);
    final varsB = await config.parseEnvFile(envFileB);

    final allKeys = <String>{...varsA.keys, ...varsB.keys}.toList()..sort();

    Logger.phase('Comparing "$clientA" vs "$clientB" ($envFileName)');

    var differenceCount = 0;

    for (final key in allKeys) {
      final valueA = varsA[key];
      final valueB = varsB[key];
      final differs = valueA != valueB;

      if (differs) differenceCount++;
      if (!differs && !showAll) continue;

      final displayA = valueA ?? '(not set)';
      final displayB = valueB ?? '(not set)';

      if (differs) {
        Logger.warning('$key');
        Logger.info('  $clientA: $displayA');
        Logger.info('  $clientB: $displayB');
      } else {
        Logger.success('$key: $displayA');
      }
    }

    Logger.phase('Summary');
    if (differenceCount == 0) {
      Logger.success('No differences found between "$clientA" and "$clientB".');
    } else {
      Logger.info(
          '$differenceCount key(s) differ between "$clientA" and "$clientB".');
    }
  }
}

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

class ListClientsCommand extends UdaraCommand {
  ListClientsCommand() {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Print clients as JSON (for editor integrations and scripts).',
    );
  }

  @override
  final String name = 'list-clients';

  @override
  final String description =
      'Lists all available clients in the `clients` directory with their app name and bundle id.';

  @override
  Future<void> run() async {
    if (!clientsDir.existsSync()) {
      throw BuildException(
        '`clients` directory not found at "${clientsDir.path}"',
        fix:
            'Run "udara_cli setup --clients default" to initialize client directories.',
      );
    }

    final clients = await listClientNames();
    final asJson = argResults!['json'] as bool;
    Logger.jsonMode = argResults!['json'] as bool;

    if (asJson) {
      await _printJson(clients);
      return;
    }

    if (clients.isEmpty) {
      Logger.warning('No client directories found in "${clientsDir.path}".');
      Logger.info(
          'Run "udara_cli setup --clients <name>" to create your first client.');
      return;
    }

    final config = ConfigService(projectDir);
    Logger.phase('Available Clients (${clients.length})');

    final width = clients.map((c) => c.length).reduce((a, b) => a > b ? a : b);

    for (final client in clients) {
      final envFile = File(p.join(clientsDir.path, client, '.env'));
      final hasTest =
          File(p.join(clientsDir.path, client, '.env_test')).existsSync();

      if (!envFile.existsSync()) {
        Logger.warning('${client.padRight(width)}  (no .env file)');
        continue;
      }

      final env = await config.parseEnvFile(envFile);
      final appName = env['APP_NAME_PROD'] ?? '(no APP_NAME_PROD)';
      final bundleId = env['BUNDLE_ID'] ?? '(no BUNDLE_ID)';
      final testTag = hasTest ? '  [+test]' : '';
      Logger.info('• ${client.padRight(width)}  $appName · $bundleId$testTag');
    }

    Logger.info('');
    Logger.info('Build one with: udara_cli build --client <name>');
  }

  /// Emits one object per client with its env files and parsed variables.
  /// Values are printed as-is, so treat the output as sensitive.
  Future<void> _printJson(List<String> clients) async {
    final config = ConfigService(projectDir);
    final result = <Map<String, dynamic>>[];

    for (final client in clients) {
      final dir = Directory(p.join(clientsDir.path, client));
      final envFile = File(p.join(dir.path, '.env'));
      final envTestFile = File(p.join(dir.path, '.env_test'));
      final env = await config.parseEnvFile(envFile);
      final envTest = await config.parseEnvFile(envTestFile);
      final fontsDir = Directory(p.join(dir.path, 'fonts'));
      final hasFonts = fontsDir.existsSync() &&
          fontsDir.listSync().whereType<File>().isNotEmpty;

      result.add({
        'name': client,
        'path': dir.path,
        'isDefault': client == WhiteLabelService.defaultClientName,
        'appName': env['APP_NAME_PROD'],
        'bundleId': env['BUNDLE_ID'],
        'hasFonts': hasFonts,
        'envFiles': {
          if (envFile.existsSync()) 'env': envFile.path,
          if (envTestFile.existsSync()) 'envTest': envTestFile.path,
        },
        'env': env,
        'envTest': envTest,
      });
    }

    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'projectDir': projectDir,
      'clients': result,
    }));
  }
}

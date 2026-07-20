import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

class ListClientsCommand extends UdaraCommand {
  @override
  final String name = 'list-clients';

  @override
  final String description =
      'Lists all available clients in the `clients` directory.';

  @override
  Future<void> run() async {
    final clientsDir = Directory(p.join(projectDir, 'clients'));

    if (!clientsDir.existsSync()) {
      throw BuildException(
        '`clients` directory not found at "${clientsDir.path}"',
        fix:
            'Run "udara_cli setup --clients default" to initialize client directories.',
      );
    }

    try {
      final clients = <String>[];

      await for (final entity in clientsDir.list()) {
        if (entity is Directory) {
          clients.add(p.basename(entity.path));
        }
      }

      if (clients.isEmpty) {
        Logger.warning('No client directories found in "${clientsDir.path}".');
        Logger.info(
            'Run "udara_cli setup --clients <name>" to create your first client.');
        return;
      }

      clients.sort();

      Logger.phase('Available Clients (${clients.length})');
      for (final client in clients) {
        Logger.info('• $client');
      }
    } catch (e, s) {
      if (e is BuildException) rethrow;
      throw BuildException(
        'Failed to read clients directory at "${clientsDir.path}"',
        fix: 'Check directory permissions and ensure the path is accessible.',
        originalStackTrace: s,
      );
    }
  }
}

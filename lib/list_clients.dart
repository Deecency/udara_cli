import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

class ListClientsCommand extends UdaraCommand {
  @override
  final name = 'list-clients';
  @override
  final description = 'Lists all available clients in the `clients` directory.';

  @override
  Future<void> run() async {
    final clientsDir = Directory('$projectDir/clients');
    if (!clientsDir.existsSync()) {
      print(
          '⚠️ `clients` directory not found. Confirm `$projectDir/clients` exists');
      return;
    }

    print('✅ Available Clients:');
    await for (final entity in clientsDir.list()) {
      if (entity is Directory) {
        print('  - ${p.basename(entity.path)}');
      }
    }
  }
}

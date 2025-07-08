import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

abstract class UdaraCommand extends Command<void> {
  final String projectDir = Directory.current.path;

  Future<void> runShell(String command, {String? workingDir}) async {
    print('🏃 Running: `$command`');
    try {
      await Shell(
        workingDirectory: workingDir ?? projectDir,
      ).run(command);
    } catch (e) {
      throw BuildException(
        'A command failed to execute.',
        fix:
            'Review the command output above to identify the cause of the failure.',
      );
    }
  }

  Future<void> copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list()) {
      final entityName = p.basename(entity.path);

      if (entity is File && entityName.contains('env')) {
        continue;
      }
      if (entity is Directory) {
        final newDirectory =
            Directory(p.join(destination.path, p.basename(entity.path)));
        await newDirectory.create();
        await copyDirectory(entity, newDirectory);
      } else if (entity is File) {
        if (!entity.existsSync()) {
          print(
              'Copying file: ${entity.path} to ${p.join(destination.path, p.basename(entity.path))}');
          print('⚠️ Warning: File does not exist: ${entity.path}');
          continue;
        }
        await entity.copy(p.join(destination.path, p.basename(entity.path)));
      }
    }
  }
}

import 'package:path/path.dart' as p;
import 'package:udara_cli/core/core.dart';

abstract class UdaraCommand extends Command<void> {
  final String projectDir = Directory.current.path;

  /// Runs a shell command in the project directory with structured logging
  /// and exception contextualization.
  Future<void> runShell(String command, {String? workingDir}) async {
    Logger.info('Running shell command: `$command`');
    try {
      await Shell(
        workingDirectory: workingDir ?? projectDir,
      ).run(command);
    } catch (e, s) {
      throw BuildException(
        'Failed to execute command: `$command`',
        fix:
            'Review the terminal logs above to see specific output from Flutter/Dart tools.',
        originalStackTrace: s,
      );
    }
  }

  /// Helper to recursively copy directories while skipping environment files.
  Future<void> copyDirectory(Directory source, Directory destination) async {
    if (!source.existsSync()) {
      Logger.warning('Source directory does not exist: ${source.path}');
      return;
    }

    try {
      await for (final entity in source.list()) {
        final entityName = p.basename(entity.path);

        // Skip environment files during copy
        if (entity is File && entityName.contains('env')) {
          continue;
        }

        if (entity is Directory) {
          final newDirectory = Directory(p.join(destination.path, entityName));
          await newDirectory.create(recursive: true);
          await copyDirectory(entity, newDirectory);
        } else if (entity is File) {
          if (!entity.existsSync()) {
            Logger.warning(
                'Source file does not exist, skipping: ${entity.path}');
            continue;
          }
          await entity.copy(p.join(destination.path, entityName));
        }
      }
    } catch (e, s) {
      throw BuildException(
        'Failed copying directory from "${source.path}" to "${destination.path}"',
        fix: 'Check file permissions and target path existence.',
        originalStackTrace: s,
      );
    }
  }
}

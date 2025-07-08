// tools/udara_cli/bin/udara_cli.dart
import 'dart:io';

import 'package:udara_cli/core/core.dart';
import 'package:udara_cli/scripts.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'udara_cli',
    'A self-contained tool to manage and build Flutter projects for different clients.',
  )
    ..addCommand(BuildCommand())
    ..addCommand(CleanCommand())
    ..addCommand(ListClientsCommand());

  try {
    await runner.run(arguments);
  } on UsageException catch (e) {
    print('❌ Error: ${e.message}');
    print('\n${e.usage}');
    exit(64);
  } on BuildException catch (e) {
    print('\n❌ Build Failed: ${e.message}');
    if (e.fix != null) {
      print('🛠️  Suggestion: ${e.fix}');
    }
    exit(1);
  } catch (e) {
    print('An unexpected error occurred: $e');
    exit(1);
  }
}

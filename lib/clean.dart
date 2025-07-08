import 'package:udara_cli/core/udara_command.dart';

class CleanCommand extends UdaraCommand {
  @override
  final name = 'clean';
  @override
  final description = 'Runs `flutter clean` on the project.';

  @override
  Future<void> run() async {
    print('🧹 Cleaning project...');
    await runShell('flutter clean');
    print('✅ Project cleaned successfully.');
  }
}

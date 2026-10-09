import 'package:test/test.dart';
import 'package:udara_cli/commands.dart';

void main() {
  test('arguments after -- are kept for flutter build', () {
    final results = BuildCommand().argParser.parse([
      '--client', 'acme', '--type', 'apk', //
      '--', '--target-platform', 'android-arm64',
      '--split-debug-info=build/symbols',
    ]);
    expect(results['client'], ['acme']);
    expect(results.rest, [
      '--target-platform',
      'android-arm64',
      '--split-debug-info=build/symbols'
    ]);
  });
}

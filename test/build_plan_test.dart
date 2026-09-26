import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  group('resolveClients', () {
    test('de-duplicates and trims while keeping order', () {
      expect(
        BuildPlan.resolveClients([' b', 'a', 'b', ''],
            allClients: false, knownClients: const ['a', 'b']),
        ['b', 'a'],
      );
    });

    test('--all-clients uses every known client', () {
      expect(
        BuildPlan.resolveClients(const [],
            allClients: true, knownClients: const ['acme', 'beta', 'default']),
        ['acme', 'beta', 'default'],
      );
    });

    test('rejects no client, both options, and an empty clients folder', () {
      expect(
        () => BuildPlan.resolveClients(const [],
            allClients: false, knownClients: const ['a']),
        throwsA(isA<BuildException>()),
      );
      expect(
        () => BuildPlan.resolveClients(const ['a'],
            allClients: true, knownClients: const ['a']),
        throwsA(isA<BuildException>()),
      );
      expect(
        () => BuildPlan.resolveClients(const [],
            allClients: true, knownClients: const []),
        throwsA(isA<BuildException>()),
      );
    });
  });

  group('resolveTargets', () {
    test('single android build keeps the old behaviour', () {
      expect(BuildPlan.resolveTargets(['android'], ['aab']),
          [const BuildTarget('android', 'aab')]);
    });

    test('ios ignores --type and always builds one IPA', () {
      expect(BuildPlan.resolveTargets(['ios'], ['apk', 'aab']),
          [const BuildTarget('ios', 'ipa')]);
    });

    test('expands android types and keeps platform order', () {
      expect(
          BuildPlan.resolveTargets(
              ['ios', 'android', 'ios'], ['aab', 'apk', 'aab']),
          [
            const BuildTarget('ios', 'ipa'),
            const BuildTarget('android', 'aab'),
            const BuildTarget('android', 'apk'),
          ]);
    });

    test('plan size and batch detection', () {
      final plan = BuildPlan(
        clients: const ['a', 'b'],
        targets: BuildPlan.resolveTargets(['android', 'ios'], ['apk']),
      );
      expect(plan.size, 4);
      expect(plan.isBatch, isTrue);
      expect(
        const BuildPlan(
            clients: ['a'], targets: [BuildTarget('android', 'aab')]).isBatch,
        isFalse,
      );
    });

    test('maps each type to its flutter command', () {
      expect(const BuildTarget('android', 'apk').flutterCommand,
          'flutter build apk --release');
      expect(const BuildTarget('android', 'aab').flutterCommand,
          'flutter build appbundle --release');
      expect(
          const BuildTarget('ios', 'ipa').flutterCommand, 'flutter build ipa');
    });
  });
}

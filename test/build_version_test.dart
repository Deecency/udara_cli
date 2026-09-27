import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  group('BuildVersion.effective', () {
    test('keeps the pubspec version when nothing is requested', () {
      expect(BuildVersion.effective(null, '1.3.9+41').toString(), '1.3.9+41');
    });

    test('keeps the pubspec build number when only a name is requested', () {
      expect(
          BuildVersion.effective('1.4.0', '1.3.9+41').toString(), '1.4.0+41');
      expect(BuildVersion.effective('1.4.0', '1.3.9').toString(), '1.4.0');
    });

    test('uses a requested build number', () {
      final v = BuildVersion.effective('1.4.0+50', '1.3.9+41');
      expect(v.toString(), '1.4.0+50');
      expect(v.flutterArgs, ['--build-name=1.4.0', '--build-number=50']);
    });

    test('omits --build-number when there is none', () {
      expect(BuildVersion.effective('2.0.0', '1.0.0').flutterArgs,
          ['--build-name=2.0.0']);
    });
  });

  group('BuildVersion.resolvePerClient', () {
    const clients = ['acme', 'beta', 'gamma'];

    test('no values means every client keeps the pubspec version', () {
      expect(BuildVersion.resolvePerClient([], clients), isEmpty);
    });

    test('a plain value applies to every client', () {
      expect(BuildVersion.resolvePerClient(['1.4.0+12'], clients),
          {'acme': '1.4.0+12', 'beta': '1.4.0+12', 'gamma': '1.4.0+12'});
    });

    test('per-client values override the default', () {
      expect(
        BuildVersion.resolvePerClient(
            ['2.0.0', 'acme=1.4.0+12', 'beta=3.1.0'], clients),
        {'acme': '1.4.0+12', 'beta': '3.1.0', 'gamma': '2.0.0'},
      );
    });

    test('only named clients get a version when there is no default', () {
      expect(BuildVersion.resolvePerClient(['beta=3.1.0'], clients),
          {'beta': '3.1.0'});
    });

    test('rejects bad versions, unknown clients, and duplicates', () {
      for (final bad in [
        ['v1.0'],
        ['acme=1.0'],
        ['ghost=1.0.0'],
        ['acme=1.0.0', 'acme=2.0.0'],
        ['1.0.0', '2.0.0'],
      ]) {
        expect(() => BuildVersion.resolvePerClient(bad, clients),
            throwsA(isA<BuildException>()),
            reason: bad.join(' '));
      }
    });
  });

  test(
      'BuildPlan.jobs splits clients by platform, keeping Android types together',
      () {
    final plan = BuildPlan(
      clients: const ['acme', 'beta'],
      targets: BuildPlan.resolveTargets(['android', 'ios'], ['aab', 'apk']),
    );
    expect(plan.jobs.map((j) => '${j.label} ${j.types}'), [
      'acme · android aab,apk',
      'acme · ios ipa',
      'beta · android aab,apk',
      'beta · ios ipa',
    ]);
    expect(plan.jobs.first.id, 'acme-android');
  });
}

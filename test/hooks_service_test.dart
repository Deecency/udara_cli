import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  late Directory tmp;
  late HooksService hooks;

  HookContext context({String? artifact}) => HookContext(
        command: 'build',
        projectDir: tmp.path,
        client: 'acme',
        envFile: File(p.join(tmp.path, 'clients', 'acme', '.env')),
        isTest: true,
        platform: 'android',
        buildType: 'apk',
        version: '1.2.3+4',
        bundleId: 'com.acme.app',
        appName: 'Acme',
        artifact: artifact,
      );

  void writeConfig(String yaml) =>
      File(p.join(tmp.path, 'udara.yaml')).writeAsStringSync(yaml);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('udara_hooks_');
    hooks = HooksService(tmp.path);
  });

  tearDown(() => tmp.delete(recursive: true));

  group('load', () {
    test('returns nothing when udara.yaml is absent or empty', () {
      expect(hooks.load(), isEmpty);
      writeConfig('');
      expect(hooks.load(), isEmpty);
    });

    test('accepts a single command or a list', () {
      writeConfig('''
hooks:
  after_branding:
    - ./a.sh
    - echo two
  after_build: ./upload.sh
''');
      final loaded = hooks.load();
      expect(loaded[HookPoint.afterBranding], ['./a.sh', 'echo two']);
      expect(loaded[HookPoint.afterBuild], ['./upload.sh']);
    });

    test('rejects unknown hook names so typos fail fast', () {
      writeConfig('hooks:\n  after_brandng: ./a.sh\n');
      expect(
        () => hooks.load(),
        throwsA(isA<BuildException>()
            .having((e) => e.message, 'message', contains('after_brandng'))),
      );
    });

    test('rejects malformed YAML and wrong shapes', () {
      writeConfig('hooks: [');
      expect(() => hooks.load(), throwsA(isA<BuildException>()));
      writeConfig('hooks: ./a.sh\n');
      expect(() => hooks.load(), throwsA(isA<BuildException>()));
      writeConfig('hooks:\n  after_build:\n    nested: map\n');
      expect(() => hooks.load(), throwsA(isA<BuildException>()));
    });
  });

  group('run', () {
    test('passes UDARA_* variables and runs in the project root', () async {
      writeConfig(
          'hooks:\n  after_build: env | grep ^UDARA_ > hook_env.txt; pwd >> hook_env.txt\n');

      await hooks.run(HookPoint.afterBuild, context(artifact: '/out/acme.apk'));

      final out = File(p.join(tmp.path, 'hook_env.txt')).readAsStringSync();
      expect(out, contains('UDARA_HOOK=after_build'));
      expect(out, contains('UDARA_COMMAND=build'));
      expect(out, contains('UDARA_CLIENT=acme'));
      expect(out,
          contains('UDARA_CLIENT_DIR=${p.join(tmp.path, 'clients', 'acme')}'));
      expect(out, contains('UDARA_ENV=test'));
      expect(out, contains('UDARA_PLATFORM=android'));
      expect(out, contains('UDARA_VERSION=1.2.3+4'));
      expect(out, contains('UDARA_BUNDLE_ID=com.acme.app'));
      expect(out, contains('UDARA_ARTIFACT=/out/acme.apk'));
      expect(out.trim().split('\n').last,
          Directory(tmp.path).resolveSymbolicLinksSync());
    });

    test('runs commands in order and only for the requested hook', () async {
      writeConfig('''
hooks:
  after_branding:
    - echo one >> order.txt
    - echo two >> order.txt
  after_build: echo build >> order.txt
''');
      await hooks.run(HookPoint.afterBranding, context());
      expect(File(p.join(tmp.path, 'order.txt')).readAsLinesSync(),
          ['one', 'two']);
    });

    test('a failing command throws and stops later commands', () async {
      writeConfig('''
hooks:
  after_branding:
    - exit 3
    - echo should-not-run > later.txt
''');
      await expectLater(
        hooks.run(HookPoint.afterBranding, context()),
        throwsA(isA<BuildException>()
            .having((e) => e.message, 'message', contains('exit code 3'))),
      );
      expect(File(p.join(tmp.path, 'later.txt')).existsSync(), isFalse);
    });

    test('does nothing without hooks', () async {
      await hooks.run(HookPoint.afterBranding, context());
    });
  });
}

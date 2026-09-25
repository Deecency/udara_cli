import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('parseEnvContent', () {
    test('parses plain, quoted and export-prefixed values', () {
      final env = ConfigService.parseEnvContent('''
# comment
APP_NAME_PROD="My App"
BUNDLE_ID='com.example.app'
export API_URL=https://example.com/v1?x=1
EMPTY=
SHOW_SIGN_UP=true
''');
      expect(env['APP_NAME_PROD'], 'My App');
      expect(env['BUNDLE_ID'], 'com.example.app');
      expect(env['API_URL'], 'https://example.com/v1?x=1');
      expect(env['EMPTY'], '');
      expect(env['SHOW_SIGN_UP'], 'true');
    });

    test('strips inline comments after quoted and unquoted values', () {
      final env = ConfigService.parseEnvContent('''
DEVELOPMENT_TEAM="ABCD123456" #IOS Development teamId
COLOR=0xFF0000 # red
HASHTAG="#builds"
URL=http://host/path#anchor
''');
      expect(env['DEVELOPMENT_TEAM'], 'ABCD123456');
      expect(env['COLOR'], '0xFF0000');
      expect(env['HASHTAG'], '#builds');
      expect(env['URL'], 'http://host/path#anchor');
    });

    test('keeps equals signs inside values', () {
      final env = ConfigService.parseEnvContent('KEY=a=b=c');
      expect(env['KEY'], 'a=b=c');
    });

    test('skips malformed lines instead of failing', () {
      final env = ConfigService.parseEnvContent('''
GOOD=1
this line has no equals
=novalue
1BAD=x
''');
      expect(env, {'GOOD': '1'});
    });
  });

  group('project file operations', () {
    late Directory tmp;
    late ConfigService config;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('udara_cfg_');
      config = ConfigService(tmp.path);
      await File(p.join(tmp.path, 'pubspec.yaml')).writeAsString('''
name: fixture
version: 2.3.4+7

flutter:
  uses-material-design: true
  assets:
    - assets/images/
    - clients/default/.env
    - assets/branding/old_client/
    - clients/old_client/.env
''');
    });

    tearDown(() => tmp.delete(recursive: true));

    test('getPubspecVersion reads the version', () async {
      expect(await config.getPubspecVersion(), '2.3.4+7');
    });

    test(
        'updatePubspecAssets replaces managed entries but keeps the default env',
        () async {
      await config.updatePubspecAssets(
          clientAssetPath: 'acme', requiredExtraAssets: ['.env']);

      final yaml =
          loadYaml(await File(p.join(tmp.path, 'pubspec.yaml')).readAsString());
      final assets = (yaml['flutter']['assets'] as YamlList).cast<String>();

      expect(assets, contains('assets/images/'));
      expect(assets, contains('clients/default/.env'));
      expect(assets, contains('assets/branding/acme/'));
      expect(assets, contains('.env'));
      expect(assets, isNot(contains('assets/branding/old_client/')));
      expect(assets, isNot(contains('clients/old_client/.env')));
    });

    test('copyToRootEnv backs up an existing root .env and restores it',
        () async {
      final root = File(p.join(tmp.path, '.env'))..writeAsStringSync('MINE=1');
      final client = File(p.join(tmp.path, 'client.env'))
        ..writeAsStringSync('THEIRS=1');

      await config.copyToRootEnv(client);
      expect(root.readAsStringSync(), 'THEIRS=1');
      expect(config.hasBackup(root), isTrue);

      final cleanup = CleanupService(projectDir: tmp.path, config: config);
      await cleanup.performFullCleanup();

      expect(root.readAsStringSync(), 'MINE=1');
      expect(Directory(p.join(tmp.path, '.udara')).existsSync(), isFalse);
    });

    test('copyToRootEnv removes the root .env on cleanup when it created it',
        () async {
      final root = File(p.join(tmp.path, '.env'));
      final client = File(p.join(tmp.path, 'client.env'))
        ..writeAsStringSync('THEIRS=1');

      await config.copyToRootEnv(client);
      expect(root.existsSync(), isTrue);

      await CleanupService(projectDir: tmp.path, config: config)
          .performFullCleanup();

      expect(root.existsSync(), isFalse);
    });

    test('untracked copyToRootEnv leaves the file alone on cleanup', () async {
      final client = File(p.join(tmp.path, 'client.env'))
        ..writeAsStringSync('THEIRS=1');
      await config.copyToRootEnv(client, trackForCleanup: false);

      await CleanupService(projectDir: tmp.path, config: config)
          .performFullCleanup();

      expect(File(p.join(tmp.path, '.env')).existsSync(), isTrue);
    });

    test('ensureGitignoreEntries appends only missing lines', () async {
      final gitignore = File(p.join(tmp.path, '.gitignore'))
        ..writeAsStringSync('build/\n.udara/\n');

      await config.ensureGitignoreEntries(['.udara/', '/.env']);

      final lines = gitignore.readAsLinesSync();
      expect(lines.where((l) => l == '.udara/').length, 1);
      expect(lines, contains('/.env'));
    });

    test('updateDevelopmentTeam rewrites every team entry', () async {
      final pbx = config.pbxprojFile..createSync(recursive: true);
      pbx.writeAsStringSync('''
DEVELOPMENT_TEAM = OLD1234567;
CODE_SIGN_STYLE = Automatic;
DEVELOPMENT_TEAM = OLD1234567;
''');
      config.updateDevelopmentTeam(teamId: 'NEW1234567');
      final content = pbx.readAsStringSync();
      expect('NEW1234567'.allMatches(content).length, 2);
      expect(content, isNot(contains('OLD1234567')));
    });

    test('build history is capped and newest-first', () async {
      for (var i = 0; i < 55; i++) {
        await config.appendBuildHistory(
          client: 'c$i',
          platform: 'android',
          type: 'apk',
          version: '1.0.0',
          success: i.isEven,
          duration: const Duration(seconds: 1),
        );
      }
      final history = await config.loadBuildHistory();
      expect(history.length, 50);
      expect(history.first['client'], 'c54');
      expect(await config.clearBuildHistory(), isTrue);
      expect(await config.loadBuildHistory(), isEmpty);
    });
  });
}

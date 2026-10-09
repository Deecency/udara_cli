import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  group('DotenvMigration.scanKeys', () {
    test('finds literal keys in every read form, including interpolation', () {
      const src = r"""
final a = dotenv.env['BANK_NAME'];
final b = dotenv.get("APP_NAME_PROD", fallback: 'x');
final c = dotenv.maybeGet('PRIMARY_COLOR');
final d = dotenv.getBool('SHOW_SIGN_UP', fallback: false);
final headers = {'accky': '${dotenv.env['ACCKY']}'};
""";
      final scan = DotenvMigration.scanKeys(src);
      expect(scan.keys, {
        'BANK_NAME',
        'APP_NAME_PROD',
        'PRIMARY_COLOR',
        'SHOW_SIGN_UP',
        'ACCKY'
      });
      expect(scan.dynamic, isFalse);
    });

    test('computed keys and whole-map use mean no complete allow-list', () {
      expect(DotenvMigration.scanKeys("final v = dotenv.env[key];").dynamic,
          isTrue);
      expect(DotenvMigration.scanKeys("final v = dotenv.get(name);").dynamic,
          isTrue);
      expect(DotenvMigration.scanKeys("final all = dotenv.env.keys;").dynamic,
          isTrue);
      expect(DotenvMigration.scanKeys("dotenv.isEveryDefined(['A']);").dynamic,
          isTrue);
      expect(
          DotenvMigration.scanKeys("final v = other.dotenv.env[key];").dynamic,
          isFalse);
    });
  });

  group('include allow-list', () {
    late Directory tmp;
    late ConfigService config;

    void write(String rel, String content) {
      final f = File(p.join(tmp.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('udara_include_');
      config = ConfigService(tmp.path);
      write('clients/acme/.env',
          'APP_NAME_PROD=Acme\nBANK_CODE=001\nRELEASE_STORE_PASSWORD=hunter2\nCONNECTION_STRING_PROD=https://db\n');
      write('clients/acme/.secrets', 'RELEASE_KEY_PASSWORD=s3cret\n');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('settings parse include and reject non-lists', () {
      write('udara.yaml',
          'app_config:\n  mode: generated\n  include: [APP_NAME_PROD, BANK_CODE]\n');
      final s = AppConfigSettings.load(tmp.path);
      expect(s.include, ['APP_NAME_PROD', 'BANK_CODE']);
      expect(s.shipsKey('BANK_CODE'), isTrue);
      expect(s.shipsKey('RELEASE_STORE_PASSWORD'), isFalse);

      write('udara.yaml',
          'app_config:\n  mode: generated\n  include: APP_NAME_PROD\n');
      expect(() => AppConfigSettings.load(tmp.path),
          throwsA(isA<BuildException>()));
    });

    test('only included keys are compiled in', () {
      write('udara.yaml',
          'app_config:\n  mode: generated\n  include: [APP_NAME_PROD, BANK_CODE]\n');
      final src = AppConfigService(tmp.path, config).generateSource(
          client: 'acme',
          envFile: File(p.join(tmp.path, 'clients/acme/.env')),
          isTest: false);
      expect(src, contains('bankCode'));
      expect(src, isNot(contains('hunter2')));
      expect(src, isNot(contains('RELEASE_STORE_PASSWORD')));
      expect(src, isNot(contains('https://db')));
    });

    test('the native root .env gets env + secrets and is removed on cleanup',
        () async {
      final staged = await config.stageNativeEnv(
          File(p.join(tmp.path, 'clients/acme/.env')),
          File(p.join(tmp.path, 'clients/acme/.secrets')));
      final content = staged.readAsStringSync();
      expect(content, contains('RELEASE_STORE_PASSWORD=hunter2'));
      expect(content, contains('RELEASE_KEY_PASSWORD=s3cret'));

      await CleanupService(projectDir: tmp.path, config: config)
          .performFullCleanup();
      expect(File(p.join(tmp.path, '.env')).existsSync(), isFalse);
    });

    test('detects native build files that read the root .env', () {
      final service = AppConfigService(tmp.path, config);
      expect(service.nativeEnvReaders(), isEmpty);
      write(
          'android/app/build.gradle',
          "def envFile = new File(rootProject.projectDir.parentFile, '.env')\n"
              "storePassword envProperties.getProperty('RELEASE_STORE_PASSWORD')\n");
      expect(service.nativeEnvReaders(), {
        'android/app/build.gradle': ['RELEASE_STORE_PASSWORD'],
      });
    });

    test('recognises a root .env udara_cli wrote, and leaves a user one alone',
        () async {
      final service = AppConfigService(tmp.path, config);
      await config.stageNativeEnv(
          File(p.join(tmp.path, 'clients/acme/.env')), null,
          trackForCleanup: false);
      expect(File(p.join(tmp.path, '.env')).readAsStringSync(),
          startsWith(ConfigService.stagedEnvHeader));
      expect(service.isStagedRootEnv(), isTrue);

      // A plain copy of a client's .env (what dotenv mode used to leave).
      File(p.join(tmp.path, '.env')).writeAsStringSync(
          File(p.join(tmp.path, 'clients/acme/.env')).readAsStringSync());
      expect(service.isStagedRootEnv(), isTrue);

      File(p.join(tmp.path, '.env')).writeAsStringSync('MY_OWN=1\n');
      expect(service.isStagedRootEnv(), isFalse);
    });

    test('an existing root .env is restored after staging', () async {
      write('.env', 'MINE=1\n');
      await config.stageNativeEnv(
          File(p.join(tmp.path, 'clients/acme/.env')), null);
      await CleanupService(projectDir: tmp.path, config: config)
          .performFullCleanup();
      expect(File(p.join(tmp.path, '.env')).readAsStringSync(), 'MINE=1\n');
    });
  });
}

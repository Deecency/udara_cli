import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  late Directory tmp;
  late ConfigService config;

  void write(String rel, String content) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('udara_appcfg_');
    config = ConfigService(tmp.path);
    write('udara.yaml', 'app_config:\n  mode: generated\n');
    write('clients/acme/.env',
        'APP_NAME_PROD=Acme\nBUNDLE_ID=com.acme\nDEVELOPMENT_TEAM=ABCDE12345\nASSETS_PATH=clients/acme/\nPRIMARY_COLOR=0xFF000001\n');
    write('clients/acme/.env_test',
        'APP_NAME_PROD=Acme Test\nBUNDLE_ID=com.acme.test\nPRIMARY_COLOR=0xFF000002\n');
    write('clients/beta/.env',
        'APP_NAME_PROD=Beta\nBUNDLE_ID=com.beta\nEXTRA=only-beta\n');
    write('clients/acme/.secrets',
        'STRIPE_SECRET_KEY=sk_live_abcdefghijklmnop\n');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('excludes build-only keys and never reads .secrets', () {
    final src = AppConfigService(tmp.path, config).generateSource(
        client: 'acme',
        envFile: File(p.join(tmp.path, 'clients/acme/.env')),
        isTest: false);
    expect(src, isNot(contains('DEVELOPMENT_TEAM')));
    expect(src, isNot(contains('ASSETS_PATH')));
    expect(src, isNot(contains('sk_live')));
    expect(src, contains("static const String appNameProd = 'Acme';"));
  });

  test('every client and environment gets the same class shape', () {
    final service = AppConfigService(tmp.path, config);
    String fields(String client, String file, bool test) => service
        .generateSource(
            client: client,
            envFile: File(p.join(tmp.path, 'clients/$client/$file')),
            isTest: test)
        .split('\n')
        .where((l) =>
            l.trimLeft().startsWith('static const String') &&
            !l.contains(' client ='))
        .map((l) => l.replaceAll(RegExp(r'=.*'), ''))
        .join('\n');

    final acme = fields('acme', '.env', false);
    expect(fields('beta', '.env', false), acme);
    expect(fields('acme', '.env_test', true), acme);
    // Defined everywhere -> non-nullable; missing somewhere -> nullable.
    expect(acme, contains('static const String appNameProd'));
    expect(acme, contains('static const String? primaryColor'));
    expect(acme, contains('static const String? extra'));
  });

  test('write backs up the committed file and cleanup restores it', () async {
    write('lib/udara_config.g.dart', '// committed default\n');
    final service = AppConfigService(tmp.path, config);
    await service.write(
        client: 'beta',
        envFile: File(p.join(tmp.path, 'clients/beta/.env')),
        isTest: false);
    expect(service.outputFile.readAsStringSync(), contains("client = 'beta'"));

    await CleanupService(projectDir: tmp.path, config: config)
        .performFullCleanup();
    expect(service.outputFile.readAsStringSync(), '// committed default\n');
  });

  test('a file the build created is removed again by cleanup', () async {
    final service = AppConfigService(tmp.path, config);
    await service.write(
        client: 'acme',
        envFile: File(p.join(tmp.path, 'clients/acme/.env')),
        isTest: false);
    expect(service.outputFile.existsSync(), isTrue);
    await CleanupService(projectDir: tmp.path, config: config)
        .performFullCleanup();
    expect(service.outputFile.existsSync(), isFalse);
  });

  test('untracked writes (whitelabel --keep) stay after cleanup', () async {
    write('lib/udara_config.g.dart', '// committed default\n');
    final service = AppConfigService(tmp.path, config);
    await service.write(
        client: 'acme',
        envFile: File(p.join(tmp.path, 'clients/acme/.env')),
        isTest: false,
        trackForCleanup: false);
    await CleanupService(projectDir: tmp.path, config: config)
        .performFullCleanup();
    expect(service.outputFile.readAsStringSync(), contains("client = 'acme'"));
  });

  test('cleanup restores every backed-up file, not just a fixed list',
      () async {
    write('some/other/file.txt', 'original');
    await config.createBackup(File(p.join(tmp.path, 'some/other/file.txt')));
    write('some/other/file.txt', 'changed');
    await CleanupService(projectDir: tmp.path, config: config)
        .performFullCleanup();
    expect(File(p.join(tmp.path, 'some/other/file.txt')).readAsStringSync(),
        'original');
  });

  test('generated mode removes every env asset, dotenv mode keeps the default',
      () async {
    write('pubspec.yaml',
        'name: app\nflutter:\n  assets:\n    - clients/default/.env\n    - .env\n    - assets/images/\n');
    await config.updatePubspecAssets(
        clientAssetPath: 'acme',
        requiredExtraAssets: const [],
        keepDefaultEnv: false);
    final generated = File(p.join(tmp.path, 'pubspec.yaml')).readAsStringSync();
    expect(generated, isNot(contains('.env')));
    expect(generated, contains('assets/images/'));

    write('pubspec.yaml',
        'name: app\nflutter:\n  assets:\n    - clients/default/.env\n');
    await config.updatePubspecAssets(
        clientAssetPath: 'acme', requiredExtraAssets: ['.env']);
    final dotenv = File(p.join(tmp.path, 'pubspec.yaml')).readAsStringSync();
    expect(dotenv, contains('clients/default/.env'));
    expect(dotenv, contains('- .env'));
  });

  test('.secrets files are never copied into branding assets', () async {
    write('clients/acme/logo.png', 'png');
    await WhiteLabelService(projectDir: tmp.path, config: config)
        .syncBrandingAssets('acme', 'clients/acme/');
    final copied = Directory(p.join(tmp.path, 'assets/branding/acme'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList();
    expect(copied, contains('logo.png'));
    expect(copied, isNot(contains('.secrets')));
  });

  test('a **/*.g.dart ignore rule is overridden for the generated file',
      () async {
    if (Process.runSync('git', ['init', '-q'], workingDirectory: tmp.path)
            .exitCode !=
        0) {
      markTestSkipped('git not available');
      return;
    }
    write('.gitignore', 'build/\n**/*.g.dart\n');
    final service = AppConfigService(tmp.path, config);
    expect(service.isOutputGitIgnored(), isTrue);

    expect(await service.ensureOutputTracked(), isTrue);
    expect(service.isOutputGitIgnored(), isFalse);
    expect(File(p.join(tmp.path, '.gitignore')).readAsStringSync(),
        contains('!lib/udara_config.g.dart'));
    // Other generated files stay ignored.
    expect(
        Process.runSync('git', ['check-ignore', '-q', 'lib/models.g.dart'],
                workingDirectory: tmp.path)
            .exitCode,
        0);
  });

  test('keysMissingFromInclude lists keys the include list leaves out', () {
    expect(AppConfigService(tmp.path, config).keysMissingFromInclude(), isEmpty,
        reason: 'no include list: every key ships');

    write('udara.yaml',
        'app_config:\n  mode: generated\n  include: [APP_NAME_PROD, PRIMARY_COLOR]\n');
    expect(AppConfigService(tmp.path, config).keysMissingFromInclude(),
        ['BUNDLE_ID', 'EXTRA'],
        reason: 'excluded build-only keys and .secrets are not reported');
  });
}

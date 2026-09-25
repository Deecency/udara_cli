import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tmp;
  late ConfigService config;
  late WhiteLabelService service;

  Future<void> writeFile(String relative, String content) async {
    final file = File(p.join(tmp.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('udara_wl_');
    config = ConfigService(tmp.path);
    service = WhiteLabelService(projectDir: tmp.path, config: config);

    await writeFile('pubspec.yaml', '''
name: fixture
version: 1.0.0
flutter:
  assets:
    - clients/default/.env
''');
    await writeFile('clients/acme/.env', 'APP_NAME_PROD=Acme');
    await writeFile('clients/acme/logo_small.png', 'png');
    await writeFile('clients/acme/service_account.json', '{}');
    await writeFile('clients/acme/keys/signing.jks', 'jks');
    await writeFile('clients/acme/README.md', '# acme');
  });

  tearDown(() => tmp.delete(recursive: true));

  group('syncBrandingAssets', () {
    test('copies assets and skips secrets, env files and docs', () async {
      await service.syncBrandingAssets('acme', 'clients/acme/');

      final target = Directory(p.join(tmp.path, 'assets', 'branding', 'acme'));
      final copied = target
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => p.relative(f.path, from: target.path))
          .toSet();

      expect(copied, contains('logo_small.png'));
      expect(copied, contains(WhiteLabelService.managedMarkerFile));
      expect(copied, isNot(contains('.env')));
      expect(copied, isNot(contains('service_account.json')));
      expect(copied, isNot(contains(p.join('keys', 'signing.jks'))));
      expect(copied, isNot(contains('README.md')));
      expect(File(p.join(tmp.path, '.udaraignore')).existsSync(), isTrue);
    });

    test('honours user patterns from .udaraignore', () async {
      await writeFile('.udaraignore', '*.psd\n');
      await writeFile('clients/acme/source.psd', 'psd');

      await service.syncBrandingAssets('acme', 'clients/acme/');

      expect(
          File(p.join(tmp.path, 'assets', 'branding', 'acme', 'source.psd'))
              .existsSync(),
          isFalse);
    });

    test('refuses an ASSETS_PATH outside the client folder', () async {
      await writeFile('clients/other/logo.png', 'png');
      expect(
        () => service.syncBrandingAssets('acme', 'clients/other/'),
        throwsA(isA<BuildException>()),
      );
    });

    test('refuses to overwrite an unmanaged branding folder', () async {
      await writeFile('assets/branding/acme/handmade.png', 'png');
      expect(
        () => service.syncBrandingAssets('acme', 'clients/acme/'),
        throwsA(isA<BuildException>()),
      );
    });

    test('removes other managed folders but keeps default', () async {
      await writeFile('clients/beta/.env', 'x');
      await writeFile('clients/default/.env', 'x');
      await writeFile(
          'assets/branding/beta/${WhiteLabelService.managedMarkerFile}',
          'managed=true');
      await writeFile(
          'assets/branding/default/${WhiteLabelService.managedMarkerFile}',
          'managed=true');

      await service.syncBrandingAssets('acme', 'clients/acme/');

      expect(
          Directory(p.join(tmp.path, 'assets', 'branding', 'beta'))
              .existsSync(),
          isFalse);
      expect(
          Directory(p.join(tmp.path, 'assets', 'branding', 'default'))
              .existsSync(),
          isTrue);
    });
  });

  group('applyClientFonts', () {
    test('returns false when the client has no fonts', () async {
      expect(await service.applyClientFonts('acme', 'clients/acme/'), isFalse);
    });

    test('swaps fonts, applies fonts.yaml, and cleanup restores originals',
        () async {
      await writeFile('assets/fonts/Default.ttf', 'default');
      await writeFile('clients/acme/fonts/Acme.ttf', 'acme');
      await writeFile('clients/acme/fonts/fonts.yaml', '''
- family: Acme
  fonts:
    - asset: assets/fonts/Acme.ttf
''');

      expect(await service.applyClientFonts('acme', 'clients/acme/'), isTrue);

      final fontsDir = Directory(p.join(tmp.path, 'assets', 'fonts'));
      expect(File(p.join(fontsDir.path, 'Acme.ttf')).existsSync(), isTrue);
      expect(File(p.join(fontsDir.path, 'Default.ttf')).existsSync(), isFalse);

      final yaml =
          loadYaml(await File(p.join(tmp.path, 'pubspec.yaml')).readAsString());
      expect(yaml['flutter']['fonts'][0]['family'], 'Acme');

      await CleanupService(projectDir: tmp.path, config: config)
          .performFullCleanup();

      expect(File(p.join(fontsDir.path, 'Default.ttf')).existsSync(), isTrue);
      expect(File(p.join(fontsDir.path, 'Acme.ttf')).existsSync(), isFalse);
      expect(Directory('${fontsDir.path}.bak').existsSync(), isFalse);
    });
  });

  group('renameOutput', () {
    test('renames the apk with client and version', () async {
      await writeFile(
          'build/app/outputs/apk/release/app-release.apk', 'binary');

      final renamed = await service.renameOutput(
          clientName: 'acme', version: '1.2.3+4', type: 'apk');

      expect(p.basename(renamed.path), 'acme_v1.2.3_4.apk');
      expect(renamed.existsSync(), isTrue);
    });

    test('finds the newest ipa', () async {
      await writeFile('build/ios/ipa/fixture.ipa', 'binary');

      final renamed = await service.renameOutput(
          clientName: 'acme', version: '1.0.0', type: 'ipa');

      expect(p.basename(renamed.path), 'acme_v1.0.0.ipa');
    });

    test('throws a BuildException when the artifact is missing', () {
      expect(
        () => service.renameOutput(
            clientName: 'acme', version: '1.0.0', type: 'aab'),
        throwsA(isA<BuildException>()),
      );
    });
  });

  test('placeholder PNGs are valid and detectable', () async {
    final bytes = buildPlaceholderPng(size: 8);
    expect(
        bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    final file = File(p.join(tmp.path, 'placeholder.png'))
      ..writeAsBytesSync(bytes);
    expect(isPlaceholderPng(file), isTrue);

    final real = File(p.join(tmp.path, 'real.png'))
      ..writeAsBytesSync([1, 2, 3]);
    expect(isPlaceholderPng(real), isFalse);
  });
}

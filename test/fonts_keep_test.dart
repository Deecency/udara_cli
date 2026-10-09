import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';
import 'package:yaml/yaml.dart';

/// The font/kept-state sequence behind "Run Client with a font client, then
/// run default": fonts and the pubspec entry must come back exactly.
void main() {
  late Directory tmp;
  late ConfigService config;
  late WhiteLabelService whiteLabel;
  late CleanupService cleanup;

  void write(String rel, String content) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  List<String> fontFiles() {
    final dir = Directory(p.join(tmp.path, 'assets/fonts'));
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.endsWith('.ttf'))
        .toList()
      ..sort();
  }

  List<String> pubspecFamilies() {
    final yaml =
        loadYaml(File(p.join(tmp.path, 'pubspec.yaml')).readAsStringSync());
    final fonts = yaml['flutter']['fonts'] as YamlList?;
    return fonts?.map((f) => '${f['family']}').toList() ?? const [];
  }

  /// What `whitelabel --keep` does with fonts, minus the external tools.
  Future<void> keepRun(String client) async {
    // Every run first restores whatever a previous --keep left.
    if (Directory(p.join(tmp.path, '.udara')).existsSync()) {
      await cleanup.performFullCleanup();
    }
    await config.createBackup(File(p.join(tmp.path, 'pubspec.yaml')));
    await config.snapshotFonts();
    await whiteLabel.applyClientFonts(client, 'clients/$client/');
    await config.markKept(client);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('udara_fonts_');
    config = ConfigService(tmp.path);
    whiteLabel = WhiteLabelService(projectDir: tmp.path, config: config);
    cleanup = CleanupService(projectDir: tmp.path, config: config);

    write('pubspec.yaml', '''
name: app
flutter:
  fonts:
    - family: Manrope
      fonts:
        - asset: assets/fonts/Manrope.ttf
''');
    write('assets/fonts/Manrope.ttf', 'manrope');
    write('clients/acme/fonts/Acme.ttf', 'acme');
    write('clients/acme/fonts/fonts.yaml',
        '- family: Acme\n  fonts:\n    - asset: assets/fonts/Acme.ttf\n');
    write('clients/beta/fonts/Beta.ttf', 'beta');
    write('clients/beta/fonts/fonts.yaml',
        '- family: Beta\n  fonts:\n    - asset: assets/fonts/Beta.ttf\n');
    Directory(p.join(tmp.path, 'clients/default')).createSync(recursive: true);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test(
      'running a client without fonts after a font client restores the originals',
      () async {
    await keepRun('acme');
    expect(fontFiles(), ['Acme.ttf']);
    expect(pubspecFamilies(), ['Acme']);
    expect(config.keptClient(), 'acme');

    await keepRun('default');
    expect(fontFiles(), ['Manrope.ttf']);
    expect(pubspecFamilies(), ['Manrope']);
  });

  test('switching between two font clients never mixes their fonts', () async {
    await keepRun('acme');
    await keepRun('beta');
    expect(fontFiles(), ['Beta.ttf']);
    expect(pubspecFamilies(), ['Beta']);
  });

  test('clean-style cleanup after --keep puts fonts and pubspec back',
      () async {
    await keepRun('acme');
    await cleanup.performFullCleanup();
    expect(fontFiles(), ['Manrope.ttf']);
    expect(pubspecFamilies(), ['Manrope']);
    expect(config.keptClient(), isNull);
    expect(Directory(p.join(tmp.path, '.udara')).existsSync(), isFalse);
  });

  test('a project without a fonts folder gets it removed again', () async {
    Directory(p.join(tmp.path, 'assets/fonts')).deleteSync(recursive: true);
    write(
        'pubspec.yaml', 'name: app\nflutter:\n  uses-material-design: true\n');

    await keepRun('acme');
    expect(fontFiles(), ['Acme.ttf']);
    expect(pubspecFamilies(), ['Acme']);

    await cleanup.performFullCleanup();
    expect(Directory(p.join(tmp.path, 'assets/fonts')).existsSync(), isFalse);
    expect(pubspecFamilies(), isEmpty);
  });

  test('legacy assets/fonts.bak from older versions is still restored',
      () async {
    Directory(p.join(tmp.path, 'assets/fonts'))
        .renameSync(p.join(tmp.path, 'assets/fonts.bak'));
    write('assets/fonts/Acme.ttf', 'acme');
    await cleanup.performFullCleanup();
    expect(fontFiles(), ['Manrope.ttf']);
    expect(
        Directory(p.join(tmp.path, 'assets/fonts.bak')).existsSync(), isFalse);
  });
}

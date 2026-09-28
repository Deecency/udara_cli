import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  group('AppConfigGenerator', () {
    String gen({
      Map<String, String> values = const {
        'APP_NAME_PROD': 'Acme',
        'PRIMARY_COLOR': '0xFF2196F3'
      },
      Set<String>? allKeys,
      Set<String>? alwaysPresent,
    }) =>
        AppConfigGenerator.generate(
          className: 'UdaraConfig',
          client: 'acme',
          isTest: false,
          sourceFile: 'clients/acme/.env',
          values: values,
          allKeys: allKeys ?? values.keys.toSet(),
          alwaysPresent: alwaysPresent ?? values.keys.toSet(),
        );

    test('typed constants plus a dotenv-compatible map', () {
      final src = gen();
      expect(src, contains("static const String appNameProd = 'Acme';"));
      expect(src, contains("static const String primaryColor = '0xFF2196F3';"));
      expect(src, contains("'PRIMARY_COLOR': '0xFF2196F3',"));
      expect(src, contains("static const String client = 'acme';"));
      expect(
          src, contains('static String get(String name, {String? fallback})'));
    });

    test(
        'keys not defined by every client are nullable, so every client compiles',
        () {
      final src = gen(
        values: const {'A': '1'},
        allKeys: {'A', 'B'},
        alwaysPresent: {'A'},
      );
      expect(src, contains("static const String a = '1';"));
      expect(src, contains('static const String? b = null;'));
      expect(src, isNot(contains("'B':")));
    });

    test('escapes quotes, backslashes, dollars and newlines', () {
      final src = gen(values: const {'MSG': "it's \$HOME\\path\nnext"});
      expect(src,
          contains(r"static const String msg = 'it\'s \$HOME\\path\nnext';"));
    });

    test('field names are camelCase, unique and never reserved', () {
      final names = AppConfigGenerator.fieldNames([
        '1ST_COLOR',
        'CLASS',
        'CLIENT',
        'ENV',
        'FOO_BAR',
        'FOO__BAR',
        'GET',
        'SHOW_SIGN_UP'
      ]);
      expect(names['SHOW_SIGN_UP'], 'showSignUp');
      expect(names['1ST_COLOR'], 'k1stColor');
      expect(names['CLASS'], 'classValue');
      expect(names['CLIENT'], 'clientValue');
      expect(names['ENV'], 'envValue');
      expect(names['GET'], 'getValue');
      expect(names['FOO_BAR'], 'fooBar');
      expect(names['FOO__BAR'], 'fooBar2');
    });
  });

  group('AppConfigSettings', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('udara_cfg_'));
    tearDown(() => tmp.deleteSync(recursive: true));
    void yaml(String s) =>
        File(p.join(tmp.path, 'udara.yaml')).writeAsStringSync(s);

    test('existing projects keep dotenv unless they opt in', () {
      expect(AppConfigSettings.load(tmp.path).mode, AppConfigMode.dotenv);
      yaml('hooks:\n  after_build: echo hi\n');
      expect(AppConfigSettings.load(tmp.path).isGenerated, isFalse);
    });

    test('reads generated mode with defaults', () {
      yaml('app_config:\n  mode: generated\n');
      final s = AppConfigSettings.load(tmp.path);
      expect(s.isGenerated, isTrue);
      expect(s.output, 'lib/udara_config.g.dart');
      expect(s.exclude, AppConfigSettings.defaultExclude);
    });

    test('rejects bad values', () {
      for (final bad in [
        'app_config:\n  mode: magic\n',
        'app_config:\n  output: config.dart\n',
        'app_config:\n  class_name: lower\n',
        'app_config:\n  exclude: DEVELOPMENT_TEAM\n',
        'app_config:\n  typo: 1\n',
      ]) {
        yaml(bad);
        expect(() => AppConfigSettings.load(tmp.path),
            throwsA(isA<BuildException>()),
            reason: bad);
      }
    });
  });

  group('SecretDetector', () {
    test('flags secret-looking names and values, not public config', () {
      expect(SecretDetector.reason('STRIPE_SECRET_KEY', 'x'), isNotNull);
      expect(SecretDetector.reason('ADMIN_PASSWORD', 'x'), isNotNull);
      expect(
          SecretDetector.reason('ANY', 'sk_live_abcdefghijklmnop'), isNotNull);
      expect(SecretDetector.reason('ANY', '-----BEGIN RSA PRIVATE KEY-----'),
          isNotNull);
      expect(SecretDetector.reason('PRIMARY_COLOR', '0xFF2196F3'), isNull);
      expect(SecretDetector.reason('API_BASE_URL', 'https://api.acme.com'),
          isNull);
      expect(SecretDetector.reason('ADMIN_PASSWORD', ''), isNull);
    });
  });

  group('DotenvMigration', () {
    MigrationResult migrate(String src) => DotenvMigration.migrateSource(src,
        className: 'UdaraConfig', importUri: 'package:app/udara_config.g.dart');

    test('rewrites the README setup and usages', () {
      const src = '''
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  const envFile = String.fromEnvironment('CLIENT_ENV', defaultValue: 'clients/default/.env');
  await dotenv.load(fileName: envFile);
  final color = dotenv.env['PRIMARY_COLOR'];
  final name = dotenv.get('APP_NAME_PROD', fallback: 'App');
  final signUp = dotenv.getBool("SHOW_SIGN_UP", fallback: true);
  runApp(MyApp(color, name, signUp));
}
''';
      final r = migrate(src);
      expect(r.blocked, isFalse);
      expect(r.source, isNot(contains('dotenv.')));
      expect(r.source, contains("UdaraConfig.env['PRIMARY_COLOR']"));
      expect(r.source,
          contains("UdaraConfig.get('APP_NAME_PROD', fallback: 'App')"));
      expect(r.source,
          contains('UdaraConfig.getBool("SHOW_SIGN_UP", fallback: true)'));
      expect(r.source,
          contains('// UdaraConfig: values are compiled in, nothing to load.'));
      expect(
          r.source,
          contains(
              "import 'package:flutter/material.dart';\nimport 'package:app/udara_config.g.dart';"));
      expect(r.source, isNot(contains('flutter_dotenv')));
      expect(r.source, isNot(contains('CLIENT_ENV')));
      expect(r.changes,
          contains('removed the unused CLIENT_ENV constant "envFile"'));
      expect(r.notes, isEmpty);
    });

    test('keeps a CLIENT_ENV constant that is still used elsewhere', () {
      const src = """
import 'package:flutter_dotenv/flutter_dotenv.dart';
const envFile = String.fromEnvironment('CLIENT_ENV', defaultValue: '.env');
void main() async {
  await dotenv.load(fileName: envFile);
  print(envFile);
}
""";
      final r = migrate(src);
      expect(r.source, contains("String.fromEnvironment('CLIENT_ENV'"));
      expect(r.notes.single.message, contains('still used'));
    });

    test('handles a multi-line load with nested parens and strings', () {
      const src = '''
import 'package:flutter_dotenv/flutter_dotenv.dart';
void main() async {
  await dotenv.load(
    fileName: path.join('a)', 'b'),
    mergeWith: {'X': '1'},
  );
  print(dotenv.env['X']);
}
''';
      final r = migrate(src);
      expect(r.blocked, isFalse);
      expect(r.source, isNot(contains('dotenv.load')));
      expect(r.source, contains("UdaraConfig.env['X']"));
    });

    test('leaves files without dotenv untouched', () {
      const src = "import 'package:flutter/material.dart';\nvoid main() {}\n";
      final r = migrate(src);
      expect(r.changed, isFalse);
      expect(r.source, src);
    });

    test('a load inside an expression blocks instead of guessing', () {
      const src = '''
import 'package:flutter_dotenv/flutter_dotenv.dart';
void main() {
  dotenv.load().then((_) => runApp(App(dotenv.env['A'])));
}
''';
      final r = migrate(src);
      expect(r.blocked, isTrue);
      expect(r.notes.where((n) => n.blocking).single.message,
          contains('larger expression'));
    });

    test('files that write to dotenv.env are not touched', () {
      const src = '''
import 'package:flutter_dotenv/flutter_dotenv.dart';
void setUp() {
  dotenv.env['API'] = 'http://localhost';
  print(dotenv.env['API']);
}
''';
      final r = migrate(src);
      expect(r.blocked, isTrue);
      expect(r.source, src);
    });

    test('prefixed imports are left for a human', () {
      const src =
          "import 'package:flutter_dotenv/flutter_dotenv.dart' as fd;\nvar x = fd.dotenv.env['A'];\n";
      final r = migrate(src);
      expect(r.blocked, isTrue);
      expect(r.source, src);
    });

    test('keeps the flutter_dotenv import while other usages remain', () {
      const src = '''
import 'package:flutter_dotenv/flutter_dotenv.dart';
final custom = DotEnv();
final a = dotenv.env['A'];
''';
      final r = migrate(src);
      expect(r.source, contains("UdaraConfig.env['A']"));
      expect(r.source, contains('flutter_dotenv'));
      expect(r.notes.any((n) => n.message.contains('DotEnv()')), isTrue);
    });

    test('does not touch other objects with a dotenv field', () {
      const src =
          "import 'package:flutter_dotenv/flutter_dotenv.dart';\nvar a = config.dotenv.env['A'];\nvar b = dotenv.env['B'];\n";
      final r = migrate(src);
      expect(r.source, contains("config.dotenv.env['A']"));
      expect(r.source, contains("UdaraConfig.env['B']"));
    });
  });
}

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  late Directory tmp;
  late String project;
  late String home;

  void write(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// A Flutter SDK of [version] at [root].
  String sdk(String root, String version) {
    write(p.join(root, 'bin', 'flutter'), '#!/bin/sh\n');
    write(p.join(root, 'bin', 'cache', 'flutter.version.json'),
        '{"frameworkVersion": "$version", "channel": "stable"}');
    return root;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('udara_sdk_');
    project = p.join(tmp.path, 'app');
    Directory(project).createSync();
    home = p.join(tmp.path, 'home');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  FlutterSdk resolve({String path = '/usr/bin', Map<String, String>? env}) =>
      FlutterSdk.resolve(project,
          home: home, environment: {'PATH': path, ...?env});

  test('without a pin, the PATH is used as is', () {
    final sdk = resolve();
    expect(sdk.pinned, isNull);
    expect(sdk.environment, isEmpty);
    expect(sdk.isMissing, isFalse);
    expect(sdk.description, isNull);
  });

  test("puts FVM's copy of the pinned version first on the PATH", () {
    write(p.join(project, '.fvmrc'), '{"flutter": "3.50.0"}');
    final root = sdk(p.join(home, 'fvm', 'versions', '3.50.0'), '3.50.0');
    sdk(p.join(home, 'fvm', 'versions', '3.44.8'), '3.44.8');

    final found = resolve(path: '/opt/bin:/usr/bin');
    expect(found.pinned, '3.50.0');
    expect(found.pinFile, '.fvmrc');
    expect(found.root, Directory(root).resolveSymbolicLinksSync());
    expect(found.environment['PATH'],
        '${p.join(found.root!, 'bin')}:/opt/bin:/usr/bin');
    expect(found.isMissing, isFalse);
  });

  test("uses FVM_CACHE_PATH and the project's own .fvm links", () {
    write(p.join(project, '.fvmrc'), '{"flutter": "3.50.0"}');
    final cache = p.join(tmp.path, 'cache');
    final root = sdk(p.join(cache, 'versions', '3.50.0'), '3.50.0');
    expect(resolve(env: {'FVM_CACHE_PATH': cache}).root,
        Directory(root).resolveSymbolicLinksSync());

    // "fvm use" links .fvm/versions/<version> to the cache.
    Directory(p.join(project, '.fvm', 'versions')).createSync(recursive: true);
    Link(p.join(project, '.fvm', 'versions', '3.50.0')).createSync(root);
    expect(resolve().root, Directory(root).resolveSymbolicLinksSync());
  });

  test('the flutter on the PATH will do when it is the pinned version', () {
    write(p.join(project, '.fvmrc'), '{"flutter": "3.50.0"}');
    final ci = sdk(p.join(tmp.path, 'ci', 'flutter'), '3.50.0');

    final found = resolve(path: '${p.join(ci, 'bin')}:/usr/bin');
    expect(found.root, isNull);
    expect(found.environment, isEmpty);
    expect(found.isMissing, isFalse);
    expect(found.pathVersion, '3.50.0');
  });

  test('a pinned version that is not installed is reported', () {
    write(p.join(project, '.fvmrc'), '{"flutter": "3.50.0"}');
    final old = sdk(p.join(tmp.path, 'old'), '3.44.8');

    final found = resolve(path: p.join(old, 'bin'));
    expect(found.isMissing, isTrue);
    expect(found.environment, isEmpty);
    expect(found.description, contains('3.50.0'));
    expect(found.description, contains('Flutter 3.44.8 from the PATH'));
    expect(found.installCommand, 'fvm install 3.50.0');
  });

  test('reads FVM 2 pins, and .fvmrc wins over them', () {
    write(p.join(project, '.fvm', 'fvm_config.json'),
        '{"flutterSdkVersion": "3.44.8"}');
    expect(FlutterSdk.readPin(project), ('3.44.8', '.fvm/fvm_config.json'));
    write(p.join(project, '.fvmrc'), '{"flutter": "3.50.0", "flavors": {}}');
    expect(FlutterSdk.readPin(project), ('3.50.0', '.fvmrc'));
    write(p.join(project, '.fvmrc'), 'not json');
    expect(FlutterSdk.readPin(project), ('3.44.8', '.fvm/fvm_config.json'));
  });

  test('pins match versions, channels and version@channel', () {
    expect(FlutterSdk.matches('3.50.0', '3.50.0'), isTrue);
    expect(FlutterSdk.matches('3.50.0', '3.50.1'), isFalse);
    expect(FlutterSdk.matches('3.50.0@beta', '3.50.0'), isTrue);
    expect(FlutterSdk.matches('stable', '3.50.0', channel: 'stable'), isTrue);
    expect(FlutterSdk.matches('beta', '3.50.0', channel: 'stable'), isFalse);
  });
}

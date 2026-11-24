import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

// Flutter links each plugin's Swift package from ios/Flutter/ephemeral into
// the shared pub cache. Restoring or cleaning up through such a link deleted
// Package.swift from the pub cache, so iOS builds fell back to CocoaPods
// (2026-11-24).
void main() {
  late Directory project;
  late Directory pubCache;
  late ConfigService config;
  late File packageSwift;
  late File source;
  const linkRel = 'ios/Flutter/ephemeral/Packages/.packages/plugin-1.0.0';

  String inProject(String rel) => p.join(project.path, rel);
  String inBackups(String rel) => p.join(project.path, '.udara/backups', rel);

  setUp(() async {
    project = await Directory.systemTemp.createTemp('udara_links_');
    pubCache = await Directory.systemTemp.createTemp('udara_pubcache_');
    config = ConfigService(project.path);
    final plugin = Directory(p.join(pubCache.path, 'plugin/ios/plugin'));
    packageSwift = File(p.join(plugin.path, 'Package.swift'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// swift-tools-version: 5.9');
    source = File(p.join(plugin.path, 'Sources/plugin/Plugin.swift'))
      ..createSync(recursive: true)
      ..writeAsStringSync('class Plugin {}');
    File(inProject('pubspec.yaml')).writeAsStringSync('name: app\n');
    Directory(p.dirname(inProject(linkRel))).createSync(recursive: true);
    Link(inProject(linkRel)).createSync(plugin.path);
  });

  tearDown(() async {
    for (final dir in [project, pubCache]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  void expectPluginIntact() {
    expect(packageSwift.readAsStringSync(), '// swift-tools-version: 5.9');
    expect(source.readAsStringSync(), 'class Plugin {}');
  }

  /// What WhiteLabelService's restore does with every backup.
  Future<void> restoreAll() async {
    for (final rel in config.backedUpFiles()) {
      await config.restoreBackup(File(inProject(rel)));
    }
  }

  test('a link in the backups is not listed, restored or followed', () async {
    await config.createBackup(File(inProject('pubspec.yaml')));
    Directory(p.dirname(inBackups(linkRel))).createSync(recursive: true);
    Link(inBackups(linkRel)).createSync(p.dirname(packageSwift.path));

    expect(config.backedUpFiles(), ['pubspec.yaml']);
    await restoreAll();
    await config.restoreBackup(File(inProject('$linkRel/Package.swift')));
    await config.clearBackups();

    expectPluginIntact();
    expect(Link(inProject(linkRel)).existsSync(), isTrue);
    expect(File(inProject('pubspec.yaml')).readAsStringSync(), 'name: app\n');
  });

  test('a backup whose project path leads through a link is dropped', () async {
    File(inBackups('$linkRel/Package.swift'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stale');

    await config.restoreBackup(File(inProject('$linkRel/Package.swift')));

    expectPluginIntact();
    expect(File(inBackups('$linkRel/Package.swift')).existsSync(), isFalse);
  });

  test('Flutter build state in the backups is not restored', () async {
    for (final rel in [
      '.dart_tool/package_config.json',
      'build/.last_build_id',
      'ios/Flutter/ephemeral/flutter_lldbinit',
      'ios/Pods/Manifest.lock',
      '.flutter-plugins-dependencies',
    ]) {
      File(inBackups(rel)).createSync(recursive: true);
    }
    await config.createBackup(File(inProject('pubspec.yaml')));

    expect(config.backedUpFiles(), ['pubspec.yaml']);
    expect(ConfigService.isBuildState('lib/udara_config.g.dart'), isFalse);
  });

  test('a created file behind a link is not removed', () async {
    await config.markCreated(File(inProject('$linkRel/Package.swift')));

    await config.removeCreatedFiles();

    expectPluginIntact();
  });

  test('reachesOutside resolves links, and checks what exists of a path', () {
    bool outside(String rel) =>
        ConfigService.reachesOutside(inProject(rel), project.path);

    expect(outside('$linkRel/Package.swift'), isTrue);
    expect(outside('$linkRel/Sources/new_file.swift'), isTrue);
    expect(outside('pubspec.yaml'), isFalse);
    expect(outside('lib/not_yet/created.dart'), isFalse);
  });
}

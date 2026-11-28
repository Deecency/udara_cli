import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

// VS Code's Flutter extension took `.udara/backups/pubspec.yaml` for a package
// of its own and ran `flutter pub get` there during `whitelabel --keep`. The
// fresh, fully upgraded pubspec.lock (and plugin registrants, local.properties)
// it wrote next to the backups were then restored over the project's
// committed ones (2026-11-24, udara360).
void main() {
  late Directory project;
  late ConfigService config;

  File inProject(String rel) => File(p.join(project.path, rel));
  File inBackups(String rel) =>
      File(p.join(project.path, '.udara', 'backups', rel));
  void write(File f, String content) => f
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  /// What `flutter pub get` writes when run in the backups folder.
  const ideOutputs = {
    'pubspec.lock': 'firebase_core: 4.15.2 # upgraded',
    'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java':
        '// upgraded plugins',
    'android/local.properties': 'flutter.sdk=/elsewhere',
    'ios/Flutter/Generated.xcconfig':
        'FLUTTER_APPLICATION_PATH=/project/.udara/backups',
    'ios/Flutter/flutter_export_environment.sh': 'export FLUTTER_ROOT=/x',
    'ios/Runner/GeneratedPluginRegistrant.m': '// upgraded plugins',
    'ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved':
        '{"firebase": "12.19.3"}',
    '.dart_tool/package_config.json': '{}',
    '.flutter-plugins-dependencies': '{}',
  };

  setUp(() {
    project = Directory.systemTemp.createTempSync('udara_tool_outputs_');
    config = ConfigService(project.path);
    write(inProject('pubspec.yaml'), 'name: app\nversion: 1.0.0+1\n');
    for (final rel in ideOutputs.keys) {
      write(inProject(rel), 'committed $rel');
    }
  });

  tearDown(() => project.deleteSync(recursive: true));

  Future<void> cleanup() =>
      CleanupService(projectDir: project.path, config: config)
          .performFullCleanup();

  void expectCommittedFilesKept() {
    for (final rel in ideOutputs.keys) {
      expect(inProject(rel).readAsStringSync(), 'committed $rel',
          reason: '$rel was overwritten from the backups');
    }
  }

  test('backups are not named like project files', () async {
    await config.createBackup(inProject('pubspec.yaml'));

    final names = Directory(p.join(project.path, '.udara'))
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.basename(f.path));
    expect(names, isNot(contains('pubspec.yaml')));
    expect(names, contains('pubspec.yaml${ConfigService.backupSuffix}'));
    expect(config.hasBackup(inProject('pubspec.yaml')), isTrue);
    expect(config.backedUpFiles(), ['pubspec.yaml']);
  });

  test('what an IDE writes into the backups is never restored', () async {
    await config.createBackup(inProject('pubspec.yaml'));
    write(inProject('pubspec.yaml'), 'name: client_app\nversion: 1.0.0+1\n');
    ideOutputs.forEach((rel, content) => write(inBackups(rel), content));

    expect(config.backedUpFiles(), ['pubspec.yaml']);
    await cleanup();

    expect(inProject('pubspec.yaml').readAsStringSync(),
        'name: app\nversion: 1.0.0+1\n');
    expectCommittedFilesKept();
    expect(Directory(p.join(project.path, '.udara')).existsSync(), isFalse);
  });

  test('backups left by udara_cli 1.3.6 are restored, its IDE files are not',
      () async {
    write(inBackups('pubspec.yaml'), 'name: app\nversion: 1.0.0+1\n');
    write(inBackups('lib/udara_config.g.dart'), '// default config');
    write(inBackups('ios/Runner/Info.plist'), '<string>Default</string>');
    ideOutputs.forEach((rel, content) => write(inBackups(rel), content));
    write(inProject('pubspec.yaml'), 'name: client_app\nversion: 1.0.0+1\n');
    write(inProject('lib/udara_config.g.dart'), '// plug config');
    write(inProject('ios/Runner/Info.plist'), '<string>Plug</string>');

    expect(config.hasBackup(inProject('pubspec.yaml')), isTrue);
    expect(config.backedUpFiles(),
        ['ios/Runner/Info.plist', 'lib/udara_config.g.dart', 'pubspec.yaml']);
    await cleanup();

    expect(inProject('pubspec.yaml').readAsStringSync(),
        'name: app\nversion: 1.0.0+1\n');
    expect(inProject('lib/udara_config.g.dart').readAsStringSync(),
        '// default config');
    expect(inProject('ios/Runner/Info.plist').readAsStringSync(),
        '<string>Default</string>');
    expectCommittedFilesKept();
  });

  test('a new backup replaces one in the old layout', () async {
    write(inBackups('pubspec.yaml'), 'name: old_backup\n');

    await config.createBackup(inProject('pubspec.yaml'));
    write(inProject('pubspec.yaml'), 'name: client_app\n');

    expect(inBackups('pubspec.yaml').existsSync(), isFalse);
    expect(config.backedUpFiles(), ['pubspec.yaml']);
    await config.restoreBackup(inProject('pubspec.yaml'));

    expect(inProject('pubspec.yaml').readAsStringSync(),
        'name: app\nversion: 1.0.0+1\n');
    expect(config.hasBackup(inProject('pubspec.yaml')), isFalse);
  });

  test('tool outputs are recognised by name and path', () {
    for (final rel in ideOutputs.keys) {
      expect(ConfigService.isToolOutput(rel) || ConfigService.isBuildState(rel),
          isTrue,
          reason: rel);
    }
    for (final rel in [
      'pubspec.yaml',
      'flutter_launcher_icons.yaml',
      '.env',
      'lib/udara_config.g.dart',
      'lib/firebase_options.dart',
      'android/app/build.gradle',
      'android/app/google-services.json',
      'ios/Runner/Info.plist',
      'ios/Runner.xcodeproj/project.pbxproj',
      'ios/Runner/GoogleService-Info.plist',
      'firebase.json',
    ]) {
      expect(ConfigService.isToolOutput(rel), isFalse, reason: rel);
    }
  });
}

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  late Directory tmp;
  late ConfigService config;

  File file(String rel) => File(p.join(tmp.path, rel));
  void write(String rel, String content) {
    file(rel).parent.createSync(recursive: true);
    file(rel).writeAsStringSync(content);
  }

  Map<String, String> tree(String rel) {
    final dir = Directory(p.join(tmp.path, rel));
    return {
      for (final f in dir.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: dir.path): f.readAsStringSync(),
    };
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('udara_native_');
    config = ConfigService(tmp.path);
    write('android/app/build.gradle', 'applicationId "com.default.app"\n');
    write('android/app/src/main/AndroidManifest.xml',
        '<application android:label="Default"/>\n');
    write(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 'default-icon');
    write('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
        '<adaptive/>');
    write('android/app/src/main/res/values/styles.xml',
        '<style name="Default"/>');
    write('ios/Runner/Info.plist', '<string>Default</string>');
    write('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon.png',
        'default-ios-icon');
    write('lib/firebase_options.dart', '// default project');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a build that rebrands the project is fully undone by cleanup',
      () async {
    final resBefore = tree('android/app/src/main/res');
    final assetsBefore = tree('ios/Runner/Assets.xcassets');

    await config.snapshotNativeBranding();

    // What rename, flutter_launcher_icons, splash_master, the icon-cache
    // cleanup and a Firebase hook do during a build:
    write('android/app/build.gradle', 'applicationId "com.client.app"\n');
    write('android/app/src/main/AndroidManifest.xml',
        '<application android:label="Client"/>\n');
    write(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 'client-icon');
    Directory(p.join(tmp.path, 'android/app/src/main/res/mipmap-anydpi-v26'))
        .deleteSync(recursive: true);
    write('android/app/src/main/res/drawable-xxhdpi/splash_image.png',
        'client-splash');
    write('ios/Runner/Info.plist', '<string>Client</string>');
    write('ios/Runner/Assets.xcassets/SplashImage.imageset/Splash.png',
        'client-splash');
    write('lib/firebase_options.dart', '// client project');
    write('android/app/google-services.json', '{"project":"client"}');

    await CleanupService(projectDir: tmp.path, config: config)
        .performFullCleanup();

    expect(file('android/app/build.gradle').readAsStringSync(),
        contains('com.default.app'));
    expect(file('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        contains('Default'));
    expect(
        file('ios/Runner/Info.plist').readAsStringSync(), contains('Default'));
    expect(file('lib/firebase_options.dart').readAsStringSync(),
        '// default project');
    expect(file('android/app/google-services.json').existsSync(), isFalse);
    expect(tree('android/app/src/main/res'), resBefore);
    expect(tree('ios/Runner/Assets.xcassets'), assetsBefore);
    expect(Directory(p.join(tmp.path, '.udara')).existsSync(), isFalse);
  });

  test('projects without iOS or Firebase files are handled', () async {
    Directory(p.join(tmp.path, 'ios')).deleteSync(recursive: true);
    file('lib/firebase_options.dart').deleteSync();
    await config.snapshotNativeBranding();
    write(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 'client-icon');
    await CleanupService(projectDir: tmp.path, config: config)
        .performFullCleanup();
    expect(
        file('android/app/src/main/res/mipmap-hdpi/ic_launcher.png')
            .readAsStringSync(),
        'default-icon');
    expect(Directory(p.join(tmp.path, 'ios')).existsSync(), isFalse);
  });
}

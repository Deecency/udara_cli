import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  late Directory tmp;
  late Directory src;
  late Directory dst;

  void write(Directory root, String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String? read(Directory root, String rel) {
    final f = File(p.join(root.path, rel));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('udara_ws_');
    src = Directory(p.join(tmp.path, 'app'))..createSync();
    dst = Directory(p.join(tmp.path, 'ws'))..createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('copies files, deletes stale ones, keeps build caches', () async {
    write(src, 'pubspec.yaml', 'name: app');
    write(src, 'lib/main.dart', 'void main() {}');
    write(src, 'build/app/out.apk', 'not synced');
    write(src, 'ios/Pods/Pod.h', 'not synced');
    write(dst, 'build/cache.bin', 'workspace cache');
    write(dst, 'ios/Pods/Cached.h', 'workspace pods');
    write(dst, 'lib/old.dart', 'stale');

    await WorkspaceManager.sync(src, dst);

    expect(read(dst, 'pubspec.yaml'), 'name: app');
    expect(read(dst, 'lib/main.dart'), 'void main() {}');
    expect(read(dst, 'lib/old.dart'), isNull);
    expect(read(dst, 'build/cache.bin'), 'workspace cache');
    expect(read(dst, 'ios/Pods/Cached.h'), 'workspace pods');
    expect(read(dst, 'build/app/out.apk'), isNull);
    expect(read(dst, 'ios/Pods/Pod.h'), isNull);
  });

  test('re-copies files the build changed in the workspace', () async {
    write(src, 'pubspec.yaml', 'name: app');
    await WorkspaceManager.sync(src, dst);
    write(dst, 'pubspec.yaml', 'name: branded');
    await WorkspaceManager.sync(src, dst);
    expect(read(dst, 'pubspec.yaml'), 'name: app');
  });

  test('makes external relative path dependencies absolute', () async {
    write(src, 'pubspec.yaml', '''
name: app
dependencies:
  shared:
    path: ../shared
  inner:
    path: packages/inner
  http: ^1.0.0
''');
    await WorkspaceManager.sync(src, dst);
    WorkspaceManager(src.path).rewriteExternalPathDependencies(dst.path);
    final out = read(dst, 'pubspec.yaml')!;
    expect(
        out, contains('path: ${p.normalize(p.join(src.path, '../shared'))}'));
    expect(out, contains('path: packages/inner'));
  });

  test('workspaces live outside the project and are stable per project', () {
    final a = WorkspaceManager(src.path).root.path;
    expect(p.isWithin(src.path, a), isFalse);
    expect(WorkspaceManager(src.path).root.path, a);
    expect(WorkspaceManager(dst.path).root.path, isNot(a));
  });

  test('pub workspace members are not supported', () {
    write(src, 'pubspec.yaml', 'name: app\nresolution: workspace\n');
    expect(WorkspaceManager(src.path).unsupportedReason(), isNotNull);
  });
}

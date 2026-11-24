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

  group('clean-up', () {
    late String home;
    late WorkspaceManager manager;
    final now = DateTime.now();

    setUp(() {
      home = p.join(tmp.path, 'home');
      write(src, 'pubspec.yaml', 'name: app');
      manager = WorkspaceManager(src.path, home: home);
    });

    /// A workspace a build used [daysAgo] days ago, and its ref's set.
    Directory used(String rel, int daysAgo, {WorkspaceManager? of}) {
      final root = (of ?? manager).root;
      final dir = Directory(p.join(root.path, rel))
        ..createSync(recursive: true);
      write(dir, 'build/out.bin', 'cache');
      final when = now.subtract(Duration(days: daysAgo));
      for (final d in [dir, if (p.split(rel).length > 1) dir.parent]) {
        final stamp = File(p.join(d.path, '.udara_workspace_used'));
        // A ref's set was used when its most recent workspace was.
        if (stamp.existsSync() && stamp.lastModifiedSync().isAfter(when)) {
          continue;
        }
        WorkspaceManager.markUsed(d);
        stamp.setLastModifiedSync(when);
      }
      return dir;
    }

    bool exists(Directory d) => d.existsSync();

    test('keeps the 3 most recently built refs', () async {
      final stable = used('ref-stable/android-1', 1);
      final dev = used('ref-dev/android-1', 2);
      final tag = used('ref-v2.0.0/ios-1', 3);
      final commit = used('ref-0b53040f/android-1', 4);
      final older = used('ref-14fb4066/android-1', 5);

      final removal = await manager.prune(now: now);

      expect([stable, dev, tag].every(exists), isTrue);
      expect(exists(commit.parent), isFalse);
      expect(exists(older.parent), isFalse);
      expect(removal.removed, hasLength(2));
      expect(removal.bytes, greaterThan(0));
    });

    test('deletes workspaces not used for 14 days', () async {
      final recent = used('android-1', 13);
      final old = used('android-2', 15);
      final refRecent = used('ref-stable/android-1', 1);
      final refOld = used('ref-stable/ios-1', 20);
      final idleRef = used('ref-dev/android-1', 30);

      await manager.prune(now: now);

      expect([recent, refRecent].every(exists), isTrue);
      expect(exists(old), isFalse);
      expect(exists(refOld), isFalse);
      expect(exists(idleRef.parent), isFalse);
    });

    test('never deletes what a running build holds', () async {
      final ws = used('ref-old1/android-1', 30);
      for (final ref in ['a', 'b', 'c']) {
        used('ref-$ref/android-1', 1);
      }
      write(ws, '.udara_workspace.lock', '$pid');
      final dead = used('ref-old2/android-1', 30);
      write(dead, '.udara_workspace.lock', '999999999');

      final removal = await manager.prune(now: now);

      expect(exists(ws), isTrue);
      expect(exists(dead.parent), isFalse);
      expect(removal.inUse, 1);
    });

    test("deletes other projects' idle workspaces and empty folders", () async {
      final other = WorkspaceManager(dst.path, home: home);
      final gone = used('android-1', 20, of: other);
      final otherRecent = used('ref-a/android-1', 1, of: other);
      final abandoned =
          WorkspaceManager(p.join(tmp.path, 'deleted_app'), home: home);
      used('ref-x/android-1', 40, of: abandoned);
      // Other projects keep any number of recent refs.
      for (final ref in ['b', 'c', 'd']) {
        used('ref-$ref/android-1', 2, of: other);
      }

      await manager.prune(now: now);

      expect(exists(gone), isFalse);
      expect(exists(otherRecent), isTrue);
      expect(exists(abandoned.root), isFalse);
      expect(_count(other.root, 'ref-'), 4);
    });

    test('workspaces from before 1.3.4 go by their folder date', () async {
      final ws = Directory(p.join(manager.root.path, 'android-1'))
        ..createSync(recursive: true);
      final pool = Directory(p.join(manager.root.path, 'ref-stable', 'source'))
        ..createSync(recursive: true);
      for (final d in [ws.path, pool.parent.path]) {
        Process.runSync('touch', ['-t', '202001010000', d]);
      }
      await manager.prune(now: now);
      expect(exists(ws), isFalse);
      expect(exists(pool.parent), isFalse);
    });

    test('the sync keeps the record of use', () async {
      WorkspaceManager.markUsed(dst);
      await WorkspaceManager.sync(src, dst);
      expect(
          File(p.join(dst.path, '.udara_workspace_used')).existsSync(), isTrue);
    });

    test('clean --workspaces keeps what a running build holds', () async {
      final busy = used('ref-stable/android-1', 1);
      final idle = used('ref-stable/ios-1', 1);
      Directory(p.join(busy.parent.path, 'source')).createSync();
      used('android-1', 1);
      write(busy, '.udara_workspace.lock', '$pid');
      final other = WorkspaceManager(dst.path, home: home);
      final otherWs = used('android-1', 1, of: other);

      final removal = await manager.removeAll();

      expect(exists(busy), isTrue);
      expect(exists(Directory(p.join(busy.parent.path, 'source'))), isTrue);
      expect(exists(idle), isFalse);
      expect(
          exists(Directory(p.join(manager.root.path, 'android-1'))), isFalse);
      expect(exists(otherWs), isTrue);
      expect(removal.inUse, 1);

      File(p.join(busy.path, '.udara_workspace.lock')).deleteSync();
      await manager.removeAll(allProjects: true);
      expect(manager.allRoots.listSync(), isEmpty);
    });

    test('sizes read as people write them', () {
      expect(WorkspaceRemoval.formatSize(512), '512 bytes');
      expect(WorkspaceRemoval.formatSize(5100000000), '5.1 GB');
      expect(WorkspaceRemoval.formatSize(45000000000), '45 GB');
    });
  });
}

int _count(Directory dir, String prefix) => dir
    .listSync()
    .whereType<Directory>()
    .where((d) => p.basename(d.path).startsWith(prefix))
    .length;

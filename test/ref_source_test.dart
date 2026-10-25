import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  late Directory tmp;

  void write(String dir, String rel, String content) {
    final f = File(p.join(dir, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String? read(String dir, String rel) {
    final f = File(p.join(dir, rel));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  String git(String dir, List<String> args) {
    final r = Process.runSync(
        'git',
        [
          '-c',
          'user.name=Test',
          '-c',
          'user.email=test@example.com',
          '-c',
          'init.defaultBranch=main',
          '-c',
          'commit.gpgsign=false',
          ...args,
        ],
        workingDirectory: dir);
    if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
    return r.stdout.toString().trim();
  }

  /// A repository on `main` with a `stable` branch one commit behind it.
  String makeRepo(String name) {
    final dir = p.join(tmp.path, name);
    Directory(dir).createSync(recursive: true);
    git(dir, ['init', '-q']);
    write(dir, '.gitignore', '''
build/
.dart_tool/
*.jks
clients/*/.env
lib/**/*.g.dart
pubspec.lock
.DS_Store
''');
    write(dir, 'pubspec.yaml', 'name: app\nversion: 1.0.0+1\n');
    write(dir, 'lib/main.dart', '// stable');
    git(dir, ['add', '-A']);
    git(dir, ['commit', '-qm', 'stable']);
    git(dir, ['branch', 'stable']);
    write(dir, 'pubspec.yaml', 'name: app\nversion: 2.0.0+1\n');
    write(dir, 'lib/main.dart', '// dev');
    git(dir, ['commit', '-qam', 'dev']);
    return dir;
  }

  Future<RefSource> prepare(String dir, String ref, {bool fetch = false}) =>
      RefSource.prepare(
        projectDir: dir,
        ref: ref,
        stagingRoot: Directory(p.join(tmp.path, 'staging')),
        fetch: fetch,
      );

  setUp(() => tmp = Directory.systemTemp.createTempSync('udara_ref_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('stages the ref, not the working copy, plus local-only files', () async {
    final dir = makeRepo('app');
    // Uncommitted work on the current branch stays out.
    write(dir, 'lib/main.dart', '// dev, uncommitted');
    write(dir, 'lib/new_feature.dart', '// untracked, not ignored');
    // Local-only files come along...
    write(dir, 'clients/acme/.env', 'APP_NAME_PROD=Acme');
    write(dir, 'release.jks', 'keystore');
    write(dir, 'pubspec.lock', 'packages: {}');
    // ...but not generated code, caches or OS files.
    write(dir, 'lib/models/user.g.dart', '// generated on dev');
    write(dir, 'build/app.apk', 'apk');
    write(dir, '.dart_tool/cache', 'cache');
    write(dir, '.DS_Store', 'finder');

    final source = await prepare(dir, 'stable');
    final tree = source.tree.path;

    expect(source.resolvedRef, 'stable');
    expect(source.commit, git(dir, ['rev-parse', 'stable']));
    expect(read(tree, 'lib/main.dart'), '// stable');
    expect(read(tree, 'pubspec.yaml'), contains('1.0.0+1'));
    expect(read(tree, 'lib/new_feature.dart'), isNull);
    expect(read(tree, 'clients/acme/.env'), 'APP_NAME_PROD=Acme');
    expect(read(tree, 'release.jks'), 'keystore');
    expect(read(tree, 'pubspec.lock'), 'packages: {}');
    expect(read(tree, 'lib/models/user.g.dart'), isNull);
    expect(read(tree, 'build/app.apk'), isNull);
    expect(read(tree, '.dart_tool/cache'), isNull);
    expect(read(tree, '.DS_Store'), isNull);
    // The working copy is untouched.
    expect(git(dir, ['rev-parse', '--abbrev-ref', 'HEAD']), 'main');
    expect(read(dir, 'lib/main.dart'), '// dev, uncommitted');
  });

  test("the ref's own copy of a file wins over the working copy's", () async {
    final dir = makeRepo('app');
    git(dir, ['checkout', '-q', 'stable']);
    write(dir, 'config/keys.txt', 'stable keys');
    git(dir, ['add', '-f', 'config/keys.txt']);
    git(dir, ['commit', '-qm', 'tracked on stable']);
    git(dir, ['checkout', '-q', 'main']);
    write(dir, '.gitignore', '${read(dir, '.gitignore')}config/\n');
    write(dir, 'config/keys.txt', 'dev keys');

    final source = await prepare(dir, 'stable');
    expect(read(source.tree.path, 'config/keys.txt'), 'stable keys');
  });

  test('builds the remote branch when the local one is behind it', () async {
    final remote = p.join(tmp.path, 'remote.git');
    final dir = makeRepo('app');
    git(tmp.path, ['init', '-q', '--bare', remote]);
    git(dir, ['remote', 'add', 'origin', remote]);
    git(dir, ['push', '-q', '-u', 'origin', 'main', 'stable']);
    git(dir, ['branch', '-q', '--set-upstream-to=origin/stable', 'stable']);

    // Someone else pushes a fix to stable.
    final other = p.join(tmp.path, 'other');
    git(tmp.path, ['clone', '-q', '-b', 'stable', remote, other]);
    write(other, 'lib/main.dart', '// stable hotfix');
    git(other, ['commit', '-qam', 'hotfix']);
    git(other, ['push', '-q']);

    final source = await prepare(dir, 'stable', fetch: true);
    expect(source.resolvedRef, 'origin/stable');
    expect(read(source.tree.path, 'lib/main.dart'), '// stable hotfix');
    expect(source.notes.join(), contains('1 commit(s) behind origin/stable'));
    // The local branch itself isn't moved.
    expect(git(dir, ['rev-parse', 'stable']),
        isNot(git(dir, ['rev-parse', 'origin/stable'])));
  });

  test('stops when the local branch and its remote have diverged', () async {
    final remote = p.join(tmp.path, 'remote.git');
    final dir = makeRepo('app');
    git(tmp.path, ['init', '-q', '--bare', remote]);
    git(dir, ['remote', 'add', 'origin', remote]);
    git(dir, ['push', '-q', 'origin', 'stable']);
    git(dir, ['branch', '-q', '--set-upstream-to=origin/stable', 'stable']);

    final other = p.join(tmp.path, 'other');
    git(tmp.path, ['clone', '-q', '-b', 'stable', remote, other]);
    write(other, 'lib/remote.dart', '// remote');
    git(other, ['add', '-A']);
    git(other, ['commit', '-qm', 'remote change']);
    git(other, ['push', '-q']);
    git(dir, ['fetch', '-q']);
    git(dir, ['checkout', '-q', 'stable']);
    write(dir, 'lib/local.dart', '// local');
    git(dir, ['add', '-A']);
    git(dir, ['commit', '-qm', 'local change']);
    git(dir, ['checkout', '-q', 'main']);

    expect(
      () => prepare(dir, 'stable'),
      throwsA(isA<BuildException>()
          .having((e) => e.message, 'message', contains('diverged'))),
    );
  });

  test('builds tags and commits as they are', () async {
    final dir = makeRepo('app');
    git(dir, ['tag', 'v1', 'stable']);
    final byTag = await prepare(dir, 'v1');
    expect(read(byTag.tree.path, 'lib/main.dart'), '// stable');

    final commit = git(dir, ['rev-parse', 'stable']);
    final bySha = await prepare(dir, commit.substring(0, 10));
    expect(bySha.commit, commit);
  });

  test('explains an unknown ref', () {
    final dir = makeRepo('app');
    expect(
      () => prepare(dir, 'no-such-branch'),
      throwsA(isA<BuildException>()
          .having((e) => e.message, 'message', contains('no-such-branch'))),
    );
  });

  test('stages only the project folder of a larger repository', () async {
    final repo = p.join(tmp.path, 'mono');
    final app = p.join(repo, 'apps', 'bank');
    Directory(app).createSync(recursive: true);
    git(repo, ['init', '-q']);
    write(repo, 'README.md', 'monorepo');
    write(app, 'pubspec.yaml', 'name: bank');
    write(repo, '.gitignore', '*.jks\n');
    git(repo, ['add', '-A']);
    git(repo, ['commit', '-qm', 'init']);
    git(repo, ['branch', 'stable']);
    write(app, 'release.jks', 'keystore');

    final source = await prepare(app, 'stable');
    expect(read(source.tree.path, 'pubspec.yaml'), 'name: bank');
    expect(read(source.tree.path, 'README.md'), isNull);
    expect(read(source.tree.path, 'release.jks'), 'keystore');
  });

  test('workspaces keep generated code that the ref leaves out', () async {
    final src = Directory(p.join(tmp.path, 'src'));
    final ws = Directory(p.join(tmp.path, 'ws'));
    write(src.path, 'lib/user.dart', 'part "user.g.dart";');
    write(ws.path, 'lib/user.g.dart', '// from build_runner');
    write(ws.path, 'lib/old.dart', '// deleted on the ref');
    write(ws.path, 'lib/gone/model.freezed.dart', '// generated');
    write(ws.path, 'lib/gone/model.dart', '// deleted on the ref');

    await WorkspaceManager.sync(src, ws, keep: RefSource.isGenerated);

    expect(read(ws.path, 'lib/user.dart'), 'part "user.g.dart";');
    expect(read(ws.path, 'lib/user.g.dart'), '// from build_runner');
    expect(read(ws.path, 'lib/old.dart'), isNull);
    expect(read(ws.path, 'lib/gone/model.freezed.dart'), '// generated');
    expect(read(ws.path, 'lib/gone/model.dart'), isNull);
  });

  test('pool names are safe folder names per ref', () {
    expect(RefSource.poolName('stable'), 'ref-stable');
    expect(RefSource.poolName('origin/release 2'), 'ref-origin_release_2');
  });
}

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';
import 'workspaces.dart';

/// A git branch, tag or commit built instead of the working copy
/// (`build --ref stable`), so a release can be built from another branch
/// without switching the project away from the one being worked on.
///
/// The ref's committed files are staged in a folder of their own, with the
/// project's local-only files added: everything git ignores, such as client
/// `.env`/`.secrets` files, keystores and Firebase configs, which exist only
/// in the working copy. Build outputs and generated code are left out; the
/// build regenerates them for the ref. Workspaces sync from the staged
/// folder instead of the project.
class RefSource {
  RefSource._({
    required this.ref,
    required this.resolvedRef,
    required this.commit,
    required this.tree,
    required this.notes,
  });

  /// As given: `stable`.
  final String ref;

  /// What is built: [ref], or its remote branch (`origin/stable`) when the
  /// local branch is behind it.
  final String resolvedRef;

  /// The full commit hash.
  final String commit;

  String get shortCommit => commit.substring(0, 7);

  /// The staged files the workspaces sync from.
  final Directory tree;

  /// What the user should know about how [ref] was resolved.
  final List<String> notes;

  String get label => '$resolvedRef @ $shortCommit';

  /// Folder name for the workspaces that build this ref, so each ref keeps
  /// its own build caches.
  static String poolName(String ref) =>
      'ref-${ref.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

  /// Generated code: never copied from the working copy (it belongs to the
  /// working copy's branch), and kept in the workspace between builds so
  /// build_runner only regenerates what changed.
  static bool isGenerated(String rel) {
    final name = p.posix.basename(rel);
    return _generatedSuffixes.any(name.endsWith) ||
        _flutterGenerated.contains(rel) ||
        name.startsWith('GeneratedPluginRegistrant.');
  }

  static const _generatedSuffixes = [
    '.g.dart',
    '.freezed.dart',
    '.gr.dart',
    '.gen.dart',
    '.mocks.dart',
    '.chopper.dart',
  ];

  /// Written by `flutter pub get` / `flutter build` for the current SDK.
  static const _flutterGenerated = {
    'android/local.properties',
    'ios/Flutter/Generated.xcconfig',
    'ios/Flutter/flutter_export_environment.sh',
    'ios/Flutter/Flutter.podspec',
    'macos/Flutter/ephemeral',
  };

  /// Local-only files that don't belong in a build: caches, editor and OS
  /// files.
  static bool _isLocalJunk(String rel) {
    final parts = p.posix.split(rel);
    for (var i = 1; i <= parts.length; i++) {
      if (WorkspaceManager.isPreserved(p.posix.joinAll(parts.take(i)))) {
        return true;
      }
    }
    final name = parts.last;
    return _junkNames.contains(name) ||
        _junkNames.contains(parts.first) ||
        name.endsWith('.iml');
  }

  static const _junkNames = {
    '.DS_Store',
    '.claude',
    'coverage',
    'xcuserdata',
  };

  /// Whether a git-ignored file of the working copy goes into the build.
  static bool copiesLocalFile(String rel) =>
      !_isLocalJunk(rel) && !isGenerated(rel);

  /// Resolves [ref] in [projectDir]'s repository and stages its files under
  /// [stagingRoot]. Fetches first (unless [fetch] is false), so a branch is
  /// built as it is on the remote.
  static Future<RefSource> prepare({
    required String projectDir,
    required String ref,
    required Directory stagingRoot,
    bool fetch = true,
  }) async {
    final git = _Git(projectDir);
    final top = await git.output(['rev-parse', '--show-toplevel']);
    if (top == null) {
      throw BuildException(
        '--ref needs the project to be in a git repository.',
        fix: 'Run the build without --ref, or from the repository.',
      );
    }

    if (fetch) {
      final fetched = await git
          .run(['fetch', '--quiet'], timeout: const Duration(seconds: 90));
      if (!fetched) {
        Logger.warning('Could not fetch from the remote (offline?): building '
            '"$ref" as this computer last saw it.');
      }
    }

    final notes = <String>[];
    final resolved = await _resolve(git, ref, notes);
    final commit = await git
        .output(['rev-parse', '--verify', '--quiet', '$resolved^{commit}']);
    if (commit == null) {
      throw BuildException(
        '"$ref" is not a branch, tag or commit in this repository.',
        fix: 'Check the name with "git branch -a" or "git tag".',
      );
    }

    final tree = Directory(p.join(stagingRoot.path, poolName(ref), 'source'));
    if (tree.existsSync()) tree.deleteSync(recursive: true);
    tree.createSync(recursive: true);

    // The project may be a folder inside the repository ("apps/bank/").
    final prefix = await git.output(['rev-parse', '--show-prefix']) ?? '';
    final treeish = prefix.isEmpty
        ? commit
        : '$commit:${prefix.substring(0, prefix.length - 1)}';
    // From the top: run in a subfolder, git archive only exports that
    // subfolder of the tree it is given.
    await _extract(top, treeish, tree);

    if (File(p.join(tree.path, '.gitmodules')).existsSync()) {
      notes.add('This repository has git submodules, which --ref builds '
          "don't include. Build without --ref if the app needs them.");
    }

    final copied = await _addLocalFiles(git, projectDir, tree);
    if (copied > 0) {
      notes.add('Added $copied local-only file(s) from the working copy '
          '(client .env/.secrets, keystores and other git-ignored files).');
    }

    return RefSource._(
      ref: ref,
      resolvedRef: resolved,
      commit: commit,
      tree: tree,
      notes: notes,
    );
  }

  /// A local branch is built as its remote branch when it is only behind
  /// it (it hasn't been pulled), and as itself when it is only ahead
  /// (unpushed commits). Diverged branches stop the build: neither is
  /// clearly the one to release.
  static Future<String> _resolve(
      _Git git, String ref, List<String> notes) async {
    final isBranch =
        await git.run(['show-ref', '--verify', '--quiet', 'refs/heads/$ref']);
    if (!isBranch) {
      // A branch that only exists on the remote.
      final exists = await git
              .output(['rev-parse', '--verify', '--quiet', '$ref^{commit}']) !=
          null;
      if (!exists &&
          await git.output([
                'rev-parse',
                '--verify',
                '--quiet',
                'origin/$ref^{commit}'
              ]) !=
              null) {
        return 'origin/$ref';
      }
      return ref;
    }

    final upstream = await git.output([
      'rev-parse',
      '--abbrev-ref',
      '--symbolic-full-name',
      '$ref@{upstream}'
    ]);
    if (upstream == null) return ref;
    final counts = await git
        .output(['rev-list', '--left-right', '--count', '$ref...$upstream']);
    final parts = (counts ?? '').split(RegExp(r'\s+'));
    if (parts.length != 2) return ref;
    final ahead = int.tryParse(parts[0]) ?? 0;
    final behind = int.tryParse(parts[1]) ?? 0;

    if (ahead > 0 && behind > 0) {
      throw BuildException(
        'Your local "$ref" and $upstream have diverged ($ahead and $behind '
        'commits of their own).',
        fix: 'Pull or rebase "$ref" first, or build what is on the remote '
            'with --ref $upstream.',
      );
    }
    if (behind > 0) {
      notes.add('Your local "$ref" is $behind commit(s) behind $upstream: '
          'building $upstream.');
      return upstream;
    }
    if (ahead > 0) {
      notes.add('Building your local "$ref", including $ahead commit(s) not '
          'pushed to $upstream.');
    }
    return ref;
  }

  /// `git archive <treeish> | tar -x -C <dest>`.
  static Future<void> _extract(
      String repoDir, String treeish, Directory dest) async {
    final archive = await Process.start(
        'git', ['archive', '--format=tar', treeish],
        workingDirectory: repoDir);
    final tar = await Process.start('tar', ['-x', '-f', '-', '-C', dest.path]);
    final archiveErr = archive.stderr.transform(systemEncoding.decoder).join();
    final tarErr = tar.stderr.transform(systemEncoding.decoder).join();
    try {
      await archive.stdout.pipe(tar.stdin);
    } on IOException {
      // tar stopped early; its exit code and error say why.
    }
    final codes = await Future.wait([archive.exitCode, tar.exitCode]);
    if (codes.any((c) => c != 0)) {
      throw BuildException(
        'Could not export $treeish: ${(await archiveErr).trim()} '
                '${(await tarErr).trim()}'
            .trim(),
      );
    }
  }

  /// Copies the working copy's git-ignored files into [tree], except
  /// caches and generated code, and except files the ref itself has.
  /// Returns how many files were copied.
  static Future<int> _addLocalFiles(
      _Git git, String projectDir, Directory tree) async {
    final listing = await git.output([
      'ls-files',
      '-z',
      '--others',
      '--ignored',
      '--exclude-standard',
      '--directory',
      '--no-empty-directory',
    ], trim: false);
    var copied = 0;
    for (final entry in (listing ?? '').split('\x00')) {
      if (entry.isEmpty) continue;
      final rel =
          entry.endsWith('/') ? entry.substring(0, entry.length - 1) : entry;
      if (!copiesLocalFile(rel)) continue;
      copied +=
          _copyLocal(p.join(projectDir, rel), p.join(tree.path, rel), rel);
    }
    return copied;
  }

  static int _copyLocal(String from, String to, String rel) {
    final type = FileSystemEntity.typeSync(from, followLinks: false);
    if (FileSystemEntity.typeSync(to, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return 0; // The ref has its own.
    }
    switch (type) {
      case FileSystemEntityType.link:
        Directory(p.dirname(to)).createSync(recursive: true);
        Link(to).createSync(Link(from).targetSync());
        return 1;
      case FileSystemEntityType.file:
        Directory(p.dirname(to)).createSync(recursive: true);
        File(from).copySync(to);
        File(to).setLastModifiedSync(File(from).lastModifiedSync());
        return 1;
      case FileSystemEntityType.directory:
        var n = 0;
        for (final child in Directory(from).listSync(followLinks: false)) {
          final name = p.basename(child.path);
          final childRel = '$rel/$name';
          if (!copiesLocalFile(childRel)) continue;
          n += _copyLocal(child.path, p.join(to, name), childRel);
        }
        return n;
      default:
        return 0;
    }
  }
}

class _Git {
  _Git(this.dir);
  final String dir;

  /// Whether `git args` succeeded.
  Future<bool> run(List<String> args,
      {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      // Never wait on a credentials prompt.
      final r = await Process.run('git', args,
          workingDirectory: dir,
          environment: const {'GIT_TERMINAL_PROMPT': '0'}).timeout(timeout);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// The output of `git args`, or null if it failed.
  Future<String?> output(List<String> args, {bool trim = true}) async {
    try {
      final r = await Process.run('git', args, workingDirectory: dir)
          .timeout(const Duration(seconds: 30));
      if (r.exitCode != 0) return null;
      final out = r.stdout.toString();
      return trim ? out.trim() : out;
    } catch (_) {
      return null;
    }
  }
}

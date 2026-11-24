import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../exceptions.dart';
import 'ref_source.dart';

/// A private copy of the project that one parallel build runs in.
class Workspace {
  Workspace(this.dir, this._lock);

  final Directory dir;
  final File _lock;

  String get path => dir.path;

  void release() {
    try {
      if (_lock.existsSync()) _lock.deleteSync();
    } catch (_) {}
  }
}

/// What a clean-up of workspaces deleted.
class WorkspaceRemoval {
  WorkspaceRemoval(this.removed, this.bytes, this.inUse);

  /// The folders deleted.
  final List<String> removed;

  /// The disk space they used, when it could be measured.
  final int? bytes;

  /// Workspaces kept because a running build holds them.
  final int inUse;

  bool get isEmpty => removed.isEmpty;

  /// "5.1 GB", or null when unknown.
  String? get size => bytes == null ? null : formatSize(bytes!);

  static String formatSize(int bytes) {
    const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    return unit == 0
        ? '$bytes bytes'
        : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
  }
}

/// Manages the per-project pool of build workspaces under
/// `~/.udara_cli/workspaces/`. They live outside the project so IDEs don't
/// index them, and they persist between runs so `build/`, Gradle and
/// CocoaPods caches stay warm. Each is synced from the project before use,
/// so uncommitted changes are built too.
///
/// Every --ref has workspaces of its own, so they add up: [prune] deletes
/// the ones not used for [maxIdle] and the refs beyond the [keepRefs] most
/// recently built.
class WorkspaceManager {
  /// [home] replaces the user's home folder (for tests).
  WorkspaceManager(this.projectDir, {String? home}) : _homeOverride = home;

  final String projectDir;
  final String? _homeOverride;

  /// How many refs keep their workspaces.
  static const keepRefs = 3;

  /// Workspaces not used for this long are deleted.
  static const maxIdle = Duration(days: 14);

  static const _lockName = '.udara_workspace.lock';

  /// Written each time a build uses a workspace or a ref's set of them.
  static const _usedName = '.udara_workspace_used';

  /// Never copied into a workspace, and never deleted from it: build
  /// outputs and caches that each workspace keeps for itself.
  static const _preserved = {
    '.git',
    'build',
    '.dart_tool',
    '.idea',
    '.vscode',
    '.udara',
    '.udara_build_history.json',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    'ios/Pods',
    'ios/.symlinks',
    'ios/Flutter/ephemeral',
    'macos/Pods',
    'macos/Flutter/ephemeral',
    'android/.gradle',
    'android/.kotlin',
    'android/app/.cxx',
    _lockName,
    _usedName,
  };

  static const _ignoredNames = {'.DS_Store'};

  String get _home =>
      _homeOverride ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;

  /// `~/.udara_cli/workspaces`: every project's workspaces.
  Directory get allRoots =>
      Directory(p.join(_home, '.udara_cli', 'workspaces'));

  /// `~/.udara_cli/workspaces/<project>-<hash of its path>`.
  Directory get root {
    final abs = p.canonicalize(projectDir);
    return Directory(
        p.join(allRoots.path, '${p.basename(abs)}-${_fnv1a(abs)}'));
  }

  /// Parallel builds can't run in a pub workspace member: the copy would lose
  /// the parent workspace. Returns the reason, or null when supported.
  String? unsupportedReason() {
    try {
      final yaml =
          loadYaml(File(p.join(projectDir, 'pubspec.yaml')).readAsStringSync());
      if (yaml is YamlMap && yaml['resolution'] == 'workspace') {
        return 'pubspec.yaml uses "resolution: workspace"';
      }
    } catch (_) {}
    return null;
  }

  /// Locks a free workspace for [platform] (creating one if needed) and
  /// syncs the project into it, or, with [source], that ref's files. Each
  /// ref has workspaces of its own, so switching between building it and
  /// the working copy doesn't throw away either's build caches.
  Future<Workspace> acquire(String platform, {RefSource? source}) async {
    final pool = source == null
        ? root
        : Directory(p.join(root.path, RefSource.poolName(source.ref)));
    pool.createSync(recursive: true);
    for (var n = 1;; n++) {
      final dir = Directory(p.join(pool.path, '$platform-$n'));
      dir.createSync(recursive: true);
      final lock = File(p.join(dir.path, _lockName));
      if (_tryLock(lock)) {
        final ws = Workspace(dir, lock);
        markUsed(dir);
        if (source != null) markUsed(pool);
        try {
          if (source == null) {
            await sync(Directory(projectDir), dir);
          } else {
            // Generated code stays, so build_runner only redoes what changed.
            await sync(source.tree, dir, keep: RefSource.isGenerated);
          }
          rewriteExternalPathDependencies(dir.path);
        } catch (e) {
          ws.release();
          throw BuildException(
              'Could not prepare a build workspace at ${dir.path}: $e',
              fix:
                  'Check free disk space, or run "udara_cli clean --workspaces" to reset them.');
        }
        return ws;
      }
    }
  }

  /// Deletes this project's workspaces, or with [allProjects] every
  /// project's, except those a running build holds.
  Future<WorkspaceRemoval> removeAll({bool allProjects = false}) async {
    final roots = allProjects ? _children(allRoots) : [root];
    final doomed = <Directory>[];
    var inUse = 0;
    for (final projectRoot in roots.where((d) => d.existsSync())) {
      var kept = false;
      for (final entry in _children(projectRoot)) {
        if (_isRefPool(entry)) {
          if (!_poolInUse(entry)) {
            doomed.add(entry);
            continue;
          }
          // A running build of this ref keeps its workspaces and the ref's
          // files, which its next jobs sync from.
          kept = true;
          for (final ws in _children(entry)) {
            if (p.basename(ws.path) == RefSource.sourceName) continue;
            if (_heldByRunningBuild(ws)) {
              inUse++;
            } else {
              doomed.add(ws);
            }
          }
        } else if (_heldByRunningBuild(entry)) {
          inUse++;
          kept = true;
        } else {
          doomed.add(entry);
        }
      }
      if (!kept) doomed.add(projectRoot);
    }
    return _delete(doomed, inUse: inUse);
  }

  /// Deletes workspaces of any project that no build has used for
  /// [maxIdle], and this project's refs beyond the [keepRefs] most recently
  /// built, except those a running build holds. Run after a build, so the
  /// workspaces it used count as the most recent.
  Future<WorkspaceRemoval> prune({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(maxIdle);
    bool idle(Directory dir) => lastUsed(dir).isBefore(cutoff);

    final doomed = <Directory>[];
    var inUse = 0;
    final ownRoot = p.canonicalize(root.path);

    for (final projectRoot in _children(allRoots)) {
      final entries = _children(projectRoot);
      final pools = entries.where(_isRefPool).toList()
        ..sort((a, b) => lastUsed(b).compareTo(lastUsed(a)));
      final surplus = p.canonicalize(projectRoot.path) == ownRoot
          ? pools.skip(keepRefs).toSet()
          : <Directory>{};

      var left = 0;
      for (final entry in entries) {
        if (_isRefPool(entry)) {
          if (surplus.contains(entry) || idle(entry)) {
            if (_poolInUse(entry)) {
              inUse++;
              left++;
            } else {
              doomed.add(entry);
            }
            continue;
          }
          // A recent ref: only its workspaces for a platform it hasn't
          // been built for lately.
          left++;
          for (final ws in _children(entry)) {
            if (p.basename(ws.path) == RefSource.sourceName) continue;
            if (!idle(ws)) continue;
            if (_heldByRunningBuild(ws)) {
              inUse++;
            } else {
              doomed.add(ws);
            }
          }
        } else if (idle(entry)) {
          if (_heldByRunningBuild(entry)) {
            inUse++;
            left++;
          } else {
            doomed.add(entry);
          }
        } else {
          left++;
        }
      }
      // Nothing of this project is left (it may no longer exist).
      if (left == 0) doomed.add(projectRoot);
    }
    return _delete(doomed, inUse: inUse);
  }

  /// Records that a build is using [dir] (a workspace, or a ref's set).
  static void markUsed(Directory dir) {
    try {
      File(p.join(dir.path, _usedName))
          .writeAsStringSync('${DateTime.now().toIso8601String()}\n');
    } catch (_) {}
  }

  /// When a build last used [dir]. Workspaces made before udara_cli 1.3.4
  /// have no record and go by the folder's modification time, which their
  /// lock file changed at every use.
  static DateTime lastUsed(Directory dir) {
    try {
      final stamp = File(p.join(dir.path, _usedName));
      if (stamp.existsSync()) return stamp.lastModifiedSync();
      return dir.statSync().modified;
    } catch (_) {
      return DateTime.now(); // When in doubt, keep it.
    }
  }

  static bool _isRefPool(Directory dir) =>
      p.basename(dir.path).startsWith('ref-');

  static List<Directory> _children(Directory dir) {
    try {
      return dir.listSync(followLinks: false).whereType<Directory>().toList();
    } catch (_) {
      return const [];
    }
  }

  static bool _poolInUse(Directory pool) =>
      _children(pool).any(_heldByRunningBuild);

  /// Whether a build that is still running has locked [workspace].
  static bool _heldByRunningBuild(Directory workspace) {
    final lock = File(p.join(workspace.path, _lockName));
    if (!lock.existsSync()) return false;
    final owner = int.tryParse(_readOrEmpty(lock).trim());
    // No owner yet: a build is taking it right now.
    return owner == null || _isAlive(owner);
  }

  /// Deletes [dirs] (outermost first), measuring the space they used.
  static Future<WorkspaceRemoval> _delete(List<Directory> dirs,
      {required int inUse}) async {
    // A folder inside another one on the list goes with it.
    final outer = dirs
        .where((d) => !dirs.any((o) => o != d && p.isWithin(o.path, d.path)))
        .toList();
    final bytes = await _diskUsage(outer);
    final removed = <String>[];
    for (final dir in outer) {
      try {
        await dir.delete(recursive: true);
        removed.add(dir.path);
      } catch (_) {}
    }
    final measured =
        removed.length == outer.length && removed.isNotEmpty ? bytes : null;
    return WorkspaceRemoval(removed, measured, inUse);
  }

  /// Disk space used by [dirs] (`du`), or null where there is no `du`.
  static Future<int?> _diskUsage(List<Directory> dirs) async {
    if (dirs.isEmpty || Platform.isWindows) return null;
    try {
      final r = await Process.run('du', ['-sk', ...dirs.map((d) => d.path)]);
      if (r.exitCode != 0) return null;
      var kb = 0;
      for (final line in r.stdout.toString().split('\n')) {
        kb += int.tryParse(line.split(RegExp(r'\s')).first) ?? 0;
      }
      return kb * 1024;
    } catch (_) {
      return null;
    }
  }

  bool _tryLock(File lock) {
    try {
      lock.createSync(exclusive: true);
      lock.writeAsStringSync('$pid');
      return true;
    } on FileSystemException {
      // Taken. Reclaim it if the process that holds it is gone.
      final owner = int.tryParse(_readOrEmpty(lock).trim());
      if (owner != null && !_isAlive(owner)) {
        lock.writeAsStringSync('$pid');
        return true;
      }
      return false;
    }
  }

  static String _readOrEmpty(File f) {
    try {
      return f.readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  static bool _isAlive(int processId) {
    try {
      if (Platform.isWindows) {
        final r =
            Process.runSync('tasklist', ['/FI', 'PID eq $processId', '/NH']);
        return r.stdout.toString().contains('$processId');
      }
      return Process.runSync('kill', ['-0', '$processId']).exitCode == 0;
    } catch (_) {
      return true; // When in doubt, don't steal the workspace.
    }
  }

  /// Makes [dest] match [source], copying only changed files (by size and
  /// modification time) and deleting files that no longer exist, except the
  /// preserved build caches and files [keep] accepts.
  static Future<void> sync(Directory source, Directory dest,
      {bool Function(String rel)? keep}) async {
    await _syncDir(source, dest, '', keep);
  }

  /// Build outputs and caches each workspace keeps for itself, by path
  /// relative to the project (`ios/Pods`).
  static bool isPreserved(String rel) =>
      _preserved.contains(rel) || _ignoredNames.contains(p.basename(rel));

  static Future<void> _syncDir(Directory source, Directory dest, String rel,
      bool Function(String rel)? keep) async {
    dest.createSync(recursive: true);
    final seen = <String>{};

    for (final entity in source.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (isPreserved(childRel)) continue;
      seen.add(name);
      final target = p.join(dest.path, name);

      if (entity is Link) {
        final linkTarget = entity.targetSync();
        final existing = Link(target);
        if (existing.existsSync() &&
            FileSystemEntity.isLinkSync(target) &&
            existing.targetSync() == linkTarget) {
          continue;
        }
        _deleteAny(target);
        Link(target).createSync(linkTarget);
      } else if (entity is Directory) {
        if (FileSystemEntity.typeSync(target, followLinks: false) ==
                FileSystemEntityType.file ||
            FileSystemEntity.isLinkSync(target)) {
          _deleteAny(target);
        }
        await _syncDir(entity, Directory(target), childRel, keep);
      } else if (entity is File) {
        final srcStat = entity.statSync();
        final dstType = FileSystemEntity.typeSync(target, followLinks: false);
        if (dstType == FileSystemEntityType.file) {
          final dstStat = File(target).statSync();
          if (dstStat.size == srcStat.size &&
              dstStat.modified == srcStat.modified) continue;
        } else if (dstType != FileSystemEntityType.notFound) {
          _deleteAny(target);
        }
        entity.copySync(target);
        File(target).setLastModifiedSync(srcStat.modified);
      }
    }

    for (final entity in dest.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (seen.contains(name) || isPreserved(childRel)) continue;
      if (keep != null && keep(childRel)) continue;
      if (keep != null && entity is Directory) {
        _prune(entity, childRel, keep); // part of it may be kept
        continue;
      }
      _deleteAny(entity.path);
    }
  }

  /// Deletes [dir]'s contents except what [keep] accepts, and [dir] itself
  /// if nothing is left.
  static void _prune(Directory dir, String rel, bool Function(String) keep) {
    for (final entity in dir.listSync(followLinks: false)) {
      final childRel = '$rel/${p.basename(entity.path)}';
      if (keep(childRel)) continue;
      if (entity is Directory) {
        _prune(entity, childRel, keep);
      } else {
        _deleteAny(entity.path);
      }
    }
    if (dir.listSync().isEmpty) dir.deleteSync();
  }

  static void _deleteAny(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      File(path).deleteSync();
    }
  }

  /// Relative `path:` dependencies that point outside the project (e.g. a
  /// shared package next to it) would break in the copy; make them absolute.
  void rewriteExternalPathDependencies(String workspaceDir) {
    final file = File(p.join(workspaceDir, 'pubspec.yaml'));
    if (!file.existsSync()) return;
    final content = file.readAsStringSync();
    final yaml = loadYaml(content);
    if (yaml is! YamlMap) return;

    final editor = YamlEditor(content);
    var changed = false;
    for (final section in [
      'dependencies',
      'dev_dependencies',
      'dependency_overrides'
    ]) {
      final deps = yaml[section];
      if (deps is! YamlMap) continue;
      for (final entry in deps.entries) {
        final spec = entry.value;
        if (spec is! YamlMap || spec['path'] is! String) continue;
        final path = spec['path'] as String;
        if (p.isAbsolute(path)) continue;
        final resolved = p.normalize(p.join(projectDir, path));
        if (p.isWithin(projectDir, resolved)) continue;
        editor.update([section, entry.key, 'path'], resolved);
        changed = true;
      }
    }
    if (changed) file.writeAsStringSync(editor.toString());
  }

  static String _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

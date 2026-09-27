import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../exceptions.dart';

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

/// Manages the per-project pool of build workspaces under
/// `~/.udara_cli/workspaces/`. They live outside the project so IDEs don't
/// index them, and they persist between runs so `build/`, Gradle and
/// CocoaPods caches stay warm. Each is synced from the project before use,
/// so uncommitted changes are built too.
class WorkspaceManager {
  WorkspaceManager(this.projectDir);

  final String projectDir;

  static const _lockName = '.udara_workspace.lock';

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
  };

  static const _ignoredNames = {'.DS_Store'};

  static String get _home =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;

  /// `~/.udara_cli/workspaces/<project>-<hash of its path>`.
  Directory get root {
    final abs = p.canonicalize(projectDir);
    return Directory(p.join(_home, '.udara_cli', 'workspaces',
        '${p.basename(abs)}-${_fnv1a(abs)}'));
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
  /// syncs the project into it.
  Future<Workspace> acquire(String platform) async {
    root.createSync(recursive: true);
    for (var n = 1;; n++) {
      final dir = Directory(p.join(root.path, '$platform-$n'));
      dir.createSync(recursive: true);
      final lock = File(p.join(dir.path, _lockName));
      if (_tryLock(lock)) {
        final ws = Workspace(dir, lock);
        try {
          await sync(Directory(projectDir), dir);
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

  /// Deletes every workspace for this project.
  Future<bool> removeAll() async {
    if (!root.existsSync()) return false;
    await root.delete(recursive: true);
    return true;
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
  /// preserved build caches.
  static Future<void> sync(Directory source, Directory dest) async {
    await _syncDir(source, dest, '');
  }

  static bool _isPreserved(String rel) =>
      _preserved.contains(rel) || _ignoredNames.contains(p.basename(rel));

  static Future<void> _syncDir(
      Directory source, Directory dest, String rel) async {
    dest.createSync(recursive: true);
    final seen = <String>{};

    for (final entity in source.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (_isPreserved(childRel)) continue;
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
        await _syncDir(entity, Directory(target), childRel);
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
      if (seen.contains(name) || _isPreserved(childRel)) continue;
      _deleteAny(entity.path);
    }
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

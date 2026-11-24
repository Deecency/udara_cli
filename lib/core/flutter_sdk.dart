import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The Flutter SDK that udara_cli runs `flutter` and `dart` from.
///
/// When the project pins a version with FVM (`.fvmrc`), that version is used
/// from FVM's cache, so builds get the same Flutter as the IDE and CI rather
/// than whichever one is first on the PATH. Without a pin, or when the
/// `flutter` on the PATH already is the pinned version, the PATH is used as is.
class FlutterSdk {
  FlutterSdk._({
    this.pinned,
    this.pinFile,
    this.root,
    this.pathVersion,
    this.pathChannel,
    Map<String, String> environment = const {},
  }) : _environment = environment;

  /// The version the project pins ("3.50.0", or a channel such as "stable"),
  /// or null when it pins none.
  final String? pinned;

  /// The file the pin is read from: `.fvmrc` or `.fvm/fvm_config.json`.
  final String? pinFile;

  /// The pinned SDK's folder in FVM's cache, when it is installed there.
  final String? root;

  /// The version of the `flutter` on the PATH, when it was looked up.
  final String? pathVersion;

  /// Its channel ("stable"), when known.
  final String? pathChannel;

  final Map<String, String> _environment;

  /// Variables for processes that run `flutter` or `dart`: [root]'s `bin`
  /// first on the PATH. Empty when the PATH is used as is.
  Map<String, String> get environment => _environment;

  /// The project pins a version that is neither in FVM's cache nor on the
  /// PATH, so the build runs another Flutter.
  bool get isMissing => pinned != null && root == null && !_pathMatches;

  bool get _pathMatches =>
      pinned != null &&
      pathVersion != null &&
      matches(pinned!, pathVersion!, channel: pathChannel);

  /// What to tell the user about the Flutter in use, or null when there is
  /// no pin.
  String? get description {
    if (pinned == null) return null;
    if (root != null) return 'Flutter $pinned ($pinFile) from $root';
    if (_pathMatches) return 'Flutter $pinned ($pinFile), the one on the PATH';
    final other = pathVersion == null
        ? 'the flutter on the PATH'
        : 'Flutter $pathVersion from the PATH';
    return 'This project pins Flutter $pinned in $pinFile, which FVM has not '
        'installed, so $other is used instead.';
  }

  /// The command that installs the pinned version.
  String get installCommand => 'fvm install $pinned';

  static const _channels = {'stable', 'beta', 'dev', 'main', 'master'};

  /// Whether a pin ("3.50.0", "3.50.0@beta", "stable") is satisfied by an
  /// SDK of [version] ("3.50.0") on [channel].
  static bool matches(String pin, String version, {String? channel}) {
    if (_channels.contains(pin)) return channel == null || channel == pin;
    return pin.split('@').first == version;
  }

  /// Finds the SDK for [projectDir]. [environment] and [home] replace the
  /// process's own (for tests).
  static FlutterSdk resolve(String projectDir,
      {Map<String, String>? environment, String? home}) {
    final env = environment ?? Platform.environment;
    final pin = readPin(projectDir);
    if (pin == null) return FlutterSdk._();
    final (version, file) = pin;

    final userHome = home ?? env['HOME'] ?? env['USERPROFILE'] ?? '';
    final fvmCache = env['FVM_CACHE_PATH'];
    final localAppData = env['LOCALAPPDATA'];
    final candidates = [
      // Linked by "fvm use", whatever FVM's cache path is.
      p.join(projectDir, '.fvm', 'versions', version),
      if (fvmCache != null && fvmCache.isNotEmpty) ...[
        p.join(fvmCache, 'versions', version),
        p.join(fvmCache, version),
      ],
      if (userHome.isNotEmpty) p.join(userHome, 'fvm', 'versions', version),
      if (Platform.isWindows && localAppData != null)
        p.join(localAppData, 'fvm', 'versions', version),
    ];
    for (final dir in candidates) {
      if (!File(p.join(dir, 'bin', _flutterExe)).existsSync()) continue;
      final root = _resolve(dir);
      final pathKey = env.keys
          .firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
      final path = env[pathKey];
      final bin = p.join(root, 'bin');
      return FlutterSdk._(
        pinned: version,
        pinFile: file,
        root: root,
        environment: {
          pathKey: path == null || path.isEmpty
              ? bin
              : '$bin${Platform.isWindows ? ';' : ':'}$path',
        },
      );
    }

    final onPath = _flutterOnPath(env);
    final (pathVersion, pathChannel) =
        onPath == null ? (null, null) : _versionOf(onPath);
    return FlutterSdk._(
      pinned: version,
      pinFile: file,
      pathVersion: pathVersion,
      pathChannel: pathChannel,
    );
  }

  /// The pinned version and the file it's in, or null.
  ///
  /// `.fvmrc` (FVM 3 and later) wins over `.fvm/fvm_config.json` (FVM 2),
  /// which newer FVMs also write but which isn't committed.
  static (String, String)? readPin(String projectDir) {
    for (final (rel, keys) in [
      ('.fvmrc', ['flutter', 'flutterSdkVersion']),
      (p.join('.fvm', 'fvm_config.json'), ['flutterSdkVersion', 'flutter']),
    ]) {
      final file = File(p.join(projectDir, rel));
      if (!file.existsSync()) continue;
      try {
        final json = jsonDecode(file.readAsStringSync());
        if (json is! Map) continue;
        for (final key in keys) {
          final value = json[key];
          if (value is String && value.trim().isNotEmpty) {
            return (value.trim(), p.posix.joinAll(p.split(rel)));
          }
        }
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  static String get _flutterExe =>
      Platform.isWindows ? 'flutter.bat' : 'flutter';

  static String _resolve(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return path;
    }
  }

  /// The root of the SDK whose `flutter` is first on the PATH.
  static String? _flutterOnPath(Map<String, String> env) {
    final path = env.entries
        .firstWhere((e) => e.key.toUpperCase() == 'PATH',
            orElse: () => const MapEntry('PATH', ''))
        .value;
    for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final exe = File(p.join(dir, _flutterExe));
      if (!exe.existsSync()) continue;
      try {
        return p.dirname(p.dirname(exe.resolveSymbolicLinksSync()));
      } catch (_) {
        return p.dirname(dir);
      }
    }
    return null;
  }

  /// The framework version ("3.44.8") and channel of the SDK at [root],
  /// as far as they are known.
  static (String?, String?) _versionOf(String root) {
    try {
      final file = File(p.join(root, 'bin', 'cache', 'flutter.version.json'));
      if (file.existsSync()) {
        final json = jsonDecode(file.readAsStringSync());
        if (json is Map && json['frameworkVersion'] is String) {
          final channel = json['channel'];
          return (
            json['frameworkVersion'] as String,
            channel is String ? channel : null
          );
        }
      }
      final legacy = File(p.join(root, 'version'));
      if (legacy.existsSync()) return (legacy.readAsStringSync().trim(), null);
    } catch (_) {}
    return (null, null);
  }
}

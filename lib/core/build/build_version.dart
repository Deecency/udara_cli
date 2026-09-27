import '../exceptions.dart';

/// A Flutter app version: build name plus optional build number (`1.4.0+12`).
class BuildVersion {
  const BuildVersion(this.name, this.number);

  /// Flutter's format; the same rule the IDE extensions validate against.
  static final pattern =
      RegExp(r'^\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?(?:\+\d+)?$');

  final String name;
  final String? number;

  static BuildVersion parse(String value) {
    final plus = value.indexOf('+');
    return plus < 0
        ? BuildVersion(value, null)
        : BuildVersion(value.substring(0, plus), value.substring(plus + 1));
  }

  /// Applies [requested] on top of the pubspec version. A requested version
  /// without a build number keeps the pubspec's, so `1.4.0` on `1.3.9+41`
  /// becomes `1.4.0+41`.
  static BuildVersion effective(String? requested, String pubspecVersion) {
    final base = parse(pubspecVersion);
    if (requested == null) return base;
    final wanted = parse(requested);
    return BuildVersion(wanted.name, wanted.number ?? base.number);
  }

  /// Arguments for `flutter build` that set this version without touching
  /// pubspec.yaml.
  List<String> get flutterArgs =>
      ['--build-name=$name', if (number != null) '--build-number=$number'];

  @override
  String toString() => number == null ? name : '$name+$number';

  @override
  bool operator ==(Object other) =>
      other is BuildVersion && other.name == name && other.number == number;

  @override
  int get hashCode => Object.hash(name, number);

  /// Resolves `--build-version` values into a version per client. A plain
  /// value (`1.4.0+12`) applies to every client without its own entry;
  /// `client=1.4.0+12` targets one client. Clients without either keep the
  /// pubspec version (absent from the map).
  static Map<String, String> resolvePerClient(
      List<String> specs, List<String> clients) {
    String? fallback;
    final perClient = <String, String>{};
    for (final raw in specs.map((s) => s.trim()).where((s) => s.isNotEmpty)) {
      final eq = raw.indexOf('=');
      final client = eq < 0 ? null : raw.substring(0, eq).trim();
      final version = (eq < 0 ? raw : raw.substring(eq + 1)).trim();

      if (!pattern.hasMatch(version)) {
        throw BuildException(
          'Invalid --build-version "$raw".',
          fix: 'Use 1.4.0, 1.4.0+12, or client=1.4.0+12.',
        );
      }
      if (client == null) {
        if (fallback != null) {
          throw BuildException(
            'More than one --build-version without a client name.',
            fix: 'Give one default version, and client=version for the others.',
          );
        }
        fallback = version;
      } else {
        if (!clients.contains(client)) {
          throw BuildException(
            '--build-version names "$client", which is not being built.',
            fix: 'Clients in this build: ${clients.join(', ')}.',
          );
        }
        if (perClient.containsKey(client)) {
          throw BuildException('--build-version given twice for "$client".');
        }
        perClient[client] = version;
      }
    }
    return {
      for (final client in clients)
        if ((perClient[client] ?? fallback) != null)
          client: (perClient[client] ?? fallback)!,
    };
  }
}

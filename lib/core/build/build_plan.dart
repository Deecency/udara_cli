import '../exceptions.dart';

/// One artifact to produce for a client: Android APK/AAB or an iOS IPA.
class BuildTarget {
  const BuildTarget(this.platform, this.type);

  /// `android` or `ios`.
  final String platform;

  /// `apk`, `aab` or `ipa`.
  final String type;

  String get label => '$platform/$type';

  String get flutterCommand => switch (type) {
        'apk' => 'flutter build apk --release',
        'aab' => 'flutter build appbundle --release',
        _ => 'flutter build ipa',
      };

  @override
  bool operator ==(Object other) =>
      other is BuildTarget && other.platform == platform && other.type == type;

  @override
  int get hashCode => Object.hash(platform, type);

  @override
  String toString() => label;
}

/// A unit of work that runs on its own: one client on one platform. Android
/// types (AAB, APK) share a job so they reuse the same Gradle outputs; iOS is
/// a separate job so it can run next to Android.
class BuildJob {
  const BuildJob(
      {required this.client, required this.platform, required this.targets});

  final String client;
  final String platform;
  final List<BuildTarget> targets;

  String get label => '$client · $platform';

  String get types => targets.map((t) => t.type).join(',');

  /// Stable id used for log file names.
  String get id => '$client-$platform';
}

/// Turns `build` arguments into the ordered list of clients and targets.
class BuildPlan {
  const BuildPlan({required this.clients, required this.targets});

  final List<String> clients;
  final List<BuildTarget> targets;

  int get size => clients.length * targets.length;

  /// Clients × platforms, keeping the requested order.
  List<BuildJob> get jobs => [
        for (final client in clients)
          for (final platform in targets.map((t) => t.platform).toSet())
            BuildJob(
              client: client,
              platform: platform,
              targets: targets.where((t) => t.platform == platform).toList(),
            ),
      ];

  bool get isBatch => size > 1;

  /// Resolves `--client` values (repeated or comma-separated) or
  /// `--all-clients` into a de-duplicated list, preserving order.
  static List<String> resolveClients(
    List<String> requested, {
    required bool allClients,
    required List<String> knownClients,
  }) {
    final names = _unique(requested);
    if (allClients && names.isNotEmpty) {
      throw BuildException(
        'Use either --client or --all-clients, not both.',
        fix: 'Drop --all-clients to build only the named clients.',
      );
    }
    if (allClients) {
      if (knownClients.isEmpty) {
        throw BuildException(
          'No clients found in the clients/ directory.',
          fix: 'Run "udara_cli setup --clients <name>" to create one.',
        );
      }
      return List.of(knownClients);
    }
    if (names.isEmpty) {
      throw BuildException(
        'No client given.',
        fix: 'Pass --client <name> (repeat it or comma-separate for several), '
            'or --all-clients.',
      );
    }
    return names;
  }

  /// Expands platforms and Android types into targets. Android gets one
  /// target per requested type; iOS always builds a single IPA, so `--type`
  /// does not apply to it.
  static List<BuildTarget> resolveTargets(
      List<String> platforms, List<String> androidTypes) {
    final targets = <BuildTarget>[];
    for (final platform in _unique(platforms)) {
      if (platform == 'ios') {
        targets.add(const BuildTarget('ios', 'ipa'));
      } else {
        final types = _unique(androidTypes);
        for (final type in types.isEmpty ? ['aab'] : types) {
          targets.add(BuildTarget('android', type));
        }
      }
    }
    return targets;
  }

  static List<String> _unique(List<String> values) {
    final seen = <String>{};
    return values
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty && seen.add(v))
        .toList();
  }
}

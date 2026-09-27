import 'dart:convert';
import 'dart:io';

import 'build_plan.dart';

/// Outcome of building one target. Serialised so a worker process can hand
/// its results to the parent of a parallel build.
class TargetResult {
  TargetResult({
    required this.client,
    required this.target,
    required this.success,
    this.skipped = false,
    this.version,
    this.duration = Duration.zero,
    this.artifact,
    this.error,
    this.cause,
    this.logPath,
  });

  factory TargetResult.skipped(String client, BuildTarget target,
          {String? reason}) =>
      TargetResult(
          client: client,
          target: target,
          success: false,
          skipped: true,
          error: reason);

  final String client;
  final BuildTarget target;
  final bool success;
  final bool skipped;
  final String? version;
  final Duration duration;
  final String? artifact;
  final String? error;

  /// The original exception, for single builds that rethrow it. Not serialised.
  final Object? cause;

  /// Worker log for parallel builds.
  final String? logPath;

  bool get failed => !success && !skipped;

  TargetResult copyWith({String? artifact, String? logPath}) => TargetResult(
        client: client,
        target: target,
        success: success,
        skipped: skipped,
        version: version,
        duration: duration,
        artifact: artifact ?? this.artifact,
        error: error,
        cause: cause,
        logPath: logPath ?? this.logPath,
      );

  Map<String, dynamic> toJson() => {
        'client': client,
        'platform': target.platform,
        'type': target.type,
        'success': success,
        'skipped': skipped,
        'version': version,
        'durationMs': duration.inMilliseconds,
        if (artifact != null) 'artifact': artifact,
        if (error != null) 'error': error,
      };

  factory TargetResult.fromJson(Map<String, dynamic> json) => TargetResult(
        client: json['client'] as String,
        target: BuildTarget(json['platform'] as String, json['type'] as String),
        success: json['success'] as bool,
        skipped: json['skipped'] as bool? ?? false,
        version: json['version'] as String?,
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
        artifact: json['artifact'] as String?,
        error: json['error'] as String?,
      );

  static void writeAll(File file, List<TargetResult> results) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(results.map((r) => r.toJson()).toList()));
  }

  static List<TargetResult> readAll(File file) =>
      (jsonDecode(file.readAsStringSync()) as List<dynamic>)
          .map((e) => TargetResult.fromJson(e as Map<String, dynamic>))
          .toList();
}

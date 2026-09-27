import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'build_plan.dart';

/// Estimates build durations from `.udara_build_history.json`, so progress
/// and ETA reflect how long this project's builds actually take.
class DurationEstimator {
  DurationEstimator(List<Map<String, dynamic>> history)
      : _history = history.where((e) => e['success'] == true).toList();

  final List<Map<String, dynamic>> _history;

  /// Used until the project has history for a build type.
  static const defaults = {
    'aab': Duration(minutes: 5),
    'apk': Duration(minutes: 5),
    'ipa': Duration(minutes: 10),
  };

  Duration target(String client, String type) {
    Duration? median(Iterable<Map<String, dynamic>> entries) {
      final seconds = entries
          .take(5)
          .map((e) => e['durationSeconds'])
          .whereType<int>()
          .where((s) => s > 0)
          .toList()
        ..sort();
      if (seconds.isEmpty) return null;
      return Duration(seconds: seconds[seconds.length ~/ 2]);
    }

    return median(_history
            .where((e) => e['client'] == client && e['type'] == type)) ??
        median(_history.where((e) => e['type'] == type)) ??
        defaults[type] ??
        const Duration(minutes: 5);
  }

  Duration job(BuildJob job) => job.targets
      .map((t) => target(job.client, t.type))
      .fold(Duration.zero, (a, b) => a + b);
}

enum JobState { queued, running, succeeded, failed, skipped }

/// Live state of one [BuildJob].
class JobProgress {
  JobProgress(this.job, this.estimate);

  final BuildJob job;
  final Duration estimate;

  JobState state = JobState.queued;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? step;
  int targetsDone = 0;
  String? logPath;
  String? detail;

  bool get isFinished =>
      state == JobState.succeeded ||
      state == JobState.failed ||
      state == JobState.skipped;

  Duration elapsed(DateTime now) => startedAt == null
      ? Duration.zero
      : (finishedAt ?? now).difference(startedAt!);

  /// 0..1. Time-based against the estimate while running (builds give no
  /// finer signal), never below the share of targets already built, and
  /// slowing down instead of hitting 100% when a build overruns.
  double fraction(DateTime now) {
    switch (state) {
      case JobState.queued:
        return 0;
      case JobState.succeeded:
      case JobState.failed:
      case JobState.skipped:
        return 1;
      case JobState.running:
        final est = math.max(estimate.inMilliseconds, 1);
        final ms = elapsed(now).inMilliseconds;
        final byTime = ms <= est ? 0.9 * ms / est : 0.9 + 0.09 * (1 - est / ms);
        final byTargets = 0.99 * targetsDone / job.targets.length;
        return math.min(math.max(byTime, byTargets), 0.99);
    }
  }

  /// Best guess at the time left for this job: the unfinished share of its
  /// estimate, so finishing a target (e.g. the AAB of AAB+APK) shortens it.
  Duration remaining(DateTime now) {
    if (isFinished) return Duration.zero;
    if (state == JobState.queued) return estimate;
    final left = Duration(
        milliseconds: (estimate.inMilliseconds * (1 - fraction(now))).round());
    const floor = Duration(seconds: 5);
    return left > floor ? left : floor;
  }
}

/// Aggregates job progress into an overall percentage and ETA, renders it,
/// and mirrors it to a JSON file that the IDE extensions poll.
class ProgressTracker {
  ProgressTracker({
    required List<JobProgress> jobs,
    required this.parallel,
    DateTime Function()? clock,
  })  : jobs = List.unmodifiable(jobs),
        _clock = clock ?? DateTime.now {
    startedAt = _clock();
  }

  final List<JobProgress> jobs;
  final int parallel;
  final DateTime Function() _clock;
  late final DateTime startedAt;

  DateTime get now => _clock();

  int get totalTargets => jobs.fold(0, (n, j) => n + j.job.targets.length);

  int count(JobState state) => jobs.where((j) => j.state == state).length;

  /// Weighted by each job's estimate, so a 10 minute iOS build counts for
  /// more than a 5 minute APK.
  double percent([DateTime? at]) {
    final t = at ?? now;
    final total =
        jobs.fold<int>(0, (n, j) => n + math.max(j.estimate.inSeconds, 1));
    final done = jobs.fold<double>(
        0, (n, j) => n + math.max(j.estimate.inSeconds, 1) * j.fraction(t));
    return total == 0 ? 100 : 100 * done / total;
  }

  /// Simulates the remaining work on [parallel] slots: running jobs keep
  /// their slot, queued jobs start on whichever slot frees up first.
  Duration eta([DateTime? at]) {
    final t = at ?? now;
    final slots = List<Duration>.filled(math.max(parallel, 1), Duration.zero);
    var i = 0;
    for (final j in jobs.where((j) => j.state == JobState.running)) {
      if (i < slots.length) slots[i++] = j.remaining(t);
    }
    for (final j in jobs.where((j) => j.state == JobState.queued)) {
      var best = 0;
      for (var s = 1; s < slots.length; s++) {
        if (slots[s] < slots[best]) best = s;
      }
      slots[best] += j.estimate;
    }
    return slots.reduce((a, b) => a > b ? a : b);
  }

  /// Whole-number percentage for display; only reads 100 when every job
  /// has actually finished.
  String percentLabel([DateTime? at]) {
    if (jobs.every((j) => j.isFinished)) return '100';
    return math.min(99, percent(at).floor()).toString();
  }

  Map<String, dynamic> toJson() {
    final t = now;
    return {
      'version': 1,
      'startedAt': startedAt.toIso8601String(),
      'updatedAt': t.toIso8601String(),
      'elapsedSeconds': t.difference(startedAt).inSeconds,
      'percent': double.parse(percent(t).toStringAsFixed(1)),
      'etaSeconds': eta(t).inSeconds,
      'parallel': parallel,
      'jobsTotal': jobs.length,
      'jobsDone': jobs.where((j) => j.isFinished).length,
      'jobsFailed': count(JobState.failed),
      'jobsRunning': count(JobState.running),
      'finished': jobs.every((j) => j.isFinished),
      'jobs': [
        for (final j in jobs)
          {
            'client': j.job.client,
            'platform': j.job.platform,
            'types': j.job.types,
            'state': j.state.name,
            'step': j.step,
            'targetsDone': j.targetsDone,
            'targetsTotal': j.job.targets.length,
            'percent': double.parse((100 * j.fraction(t)).toStringAsFixed(1)),
            'remainingSeconds': j.remaining(t).inSeconds,
            'elapsedSeconds': j.elapsed(t).inSeconds,
            if (j.logPath != null) 'log': j.logPath,
            if (j.detail != null) 'detail': j.detail,
          },
      ],
    };
  }

  /// Writes atomically so readers never see a half-written file.
  void writeFile(String path) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(jsonEncode(toJson()));
      tmp.renameSync(path);
    } catch (_) {
      // Progress reporting must never break a build.
    }
  }

  /// Reads the step and completed targets a worker process reported.
  static ({String? step, int targetsDone})? readWorkerState(String path) {
    try {
      final json =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final job = (json['jobs'] as List).first as Map<String, dynamic>;
      return (
        step: job['step'] as String?,
        targetsDone: job['targetsDone'] as int? ?? 0
      );
    } catch (_) {
      return null;
    }
  }
}

String formatDuration(Duration d) {
  if (d.inHours > 0)
    return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  if (d.inMinutes > 0)
    return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
  return '${d.inSeconds}s';
}

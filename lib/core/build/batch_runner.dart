import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../exceptions.dart';
import 'build_plan.dart';
import 'progress.dart';
import 'progress_view.dart';
import 'target_result.dart';
import 'workspaces.dart';

/// Builds the worker command line for one job, given the files the worker
/// reports its results and progress to.
typedef WorkerArgs = List<String> Function(
    BuildJob job, String resultFile, String progressFile);

/// Runs [BuildJob]s as separate `udara_cli build` worker processes, up to
/// `parallel` at a time. With workspaces each job runs in its own synced copy
/// of the project, so jobs can't overwrite each other's files; without them
/// (parallel = 1) jobs run one after another in the project itself.
class BatchRunner {
  BatchRunner({
    required this.projectDir,
    required this.tracker,
    required this.view,
    required this.workerArgs,
    required this.useWorkspaces,
    this.failFast = false,
    this.progressFile,
  }) : workspaces = WorkspaceManager(projectDir);

  final String projectDir;
  final ProgressTracker tracker;
  final ProgressView view;
  final WorkerArgs workerArgs;
  final bool useWorkspaces;
  final bool failFast;
  final String? progressFile;
  final WorkspaceManager workspaces;

  final _processes = <Process>{};
  Timer? _forceQuit;

  /// True when the run was stopped by Ctrl+C or a termination signal.
  bool get cancelled => _stopReason == 'cancelled';
  final _workerProgress = <JobProgress, String>{};
  String? _stopReason;

  String get logsDir => p.join(projectDir, 'build', 'udara', 'logs');

  Future<List<TargetResult>> run() async {
    Directory(logsDir).createSync(recursive: true);
    final queue = Queue<JobProgress>.of(tracker.jobs);
    final results = <TargetResult>[];

    void tick() {
      _pollWorkers();
      view.update(tracker);
      if (progressFile != null) tracker.writeFile(progressFile!);
    }

    final ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    final signals = <StreamSubscription<ProcessSignal>>[
      ProcessSignal.sigint.watch().listen((_) => _onSignal()),
      if (!Platform.isWindows) ...[
        ProcessSignal.sigterm.watch().listen((_) => _onSignal()),
        // IDE stop buttons and closed terminals send SIGHUP.
        ProcessSignal.sighup.watch().listen((_) => _onSignal()),
      ],
    ];
    tick();

    try {
      await Future.wait([
        for (var i = 0;
            i < math.min(tracker.parallel, tracker.jobs.length);
            i++)
          _worker(queue, results, tick),
      ]);
    } finally {
      ticker.cancel();
      _forceQuit?.cancel();
      for (final s in signals) {
        await s.cancel();
      }
      view.finish(tracker);
      if (progressFile != null) tracker.writeFile(progressFile!);
    }

    // Keep the requested order in the summary.
    final order = [
      for (final j in tracker.jobs)
        for (final t in j.job.targets) '${j.job.client}/${t.label}'
    ];
    results.sort((a, b) => order
        .indexOf('${a.client}/${a.target.label}')
        .compareTo(order.indexOf('${b.client}/${b.target.label}')));
    return results;
  }

  bool get stopped => _stopReason != null;

  var _signalCount = 0;
  void _onSignal() {
    _signalCount++;
    if (_signalCount > 1) {
      stdout.write('\x1B[?25h');
      exit(130);
    }
    _stop('cancelled');
    view.log(
        '  Cancelling: stopping running builds (press Ctrl+C again to force quit)…',
        tracker);
    // Never hang on cancel: force quit if workers don't wind down in time.
    _forceQuit = Timer(const Duration(seconds: 15), () {
      if (stdout.hasTerminal) stdout.write('\x1B[?25h');
      exit(130);
    });
  }

  void _stop(String reason) {
    _stopReason ??= reason;
    for (final process in _processes) {
      killTree(process.pid);
    }
  }

  Future<void> _worker(Queue<JobProgress> queue, List<TargetResult> results,
      void Function() tick) async {
    while (queue.isNotEmpty) {
      final jp = queue.removeFirst();
      if (stopped) {
        jp
          ..state = JobState.skipped
          ..detail = _stopReason;
        results.addAll(jp.job.targets.map((t) =>
            TargetResult.skipped(jp.job.client, t, reason: _stopReason)));
        continue;
      }
      final jobResults = await _runJob(jp, tick);
      results.addAll(jobResults);
      if (failFast && jobResults.any((r) => r.failed))
        _stop('stopped by --fail-fast');
    }
  }

  Future<List<TargetResult>> _runJob(
      JobProgress jp, void Function() tick) async {
    final job = jp.job;
    jp
      ..state = JobState.running
      ..startedAt = tracker.now
      ..step = useWorkspaces ? 'Syncing workspace' : 'Starting'
      ..logPath =
          p.relative(p.join(logsDir, '${job.id}.log'), from: projectDir);
    tick();

    final logFile = File(p.join(logsDir, '${job.id}.log'));
    final temp = Directory.systemTemp.createTempSync('udara_job_');
    final resultFile = p.join(temp.path, 'result.json');
    final progressPath = p.join(temp.path, 'progress.json');
    Workspace? workspace;
    var results = <TargetResult>[];

    try {
      if (useWorkspaces) workspace = await workspaces.acquire(job.platform);
      final dir = workspace?.path ?? projectDir;

      final command = [
        ...selfCommand(),
        ...workerArgs(job, resultFile, progressPath)
      ];
      final sink = logFile.openWrite();
      sink.writeln('# ${job.label} (${job.types})');
      sink.writeln('# directory: $dir');
      sink.writeln('# command: ${command.join(' ')}');
      sink.writeln();

      _workerProgress[jp] = progressPath;
      final process = await Process.start(
          command.first, command.skip(1).toList(),
          workingDirectory: dir);
      _processes.add(process);
      if (stopped) killTree(process.pid);

      // Attach the completion futures before waiting for the exit code: a
      // stream that finishes first would never complete a later asFuture().
      final outDone = process.stdout.listen(sink.add).asFuture<void>();
      final errDone = process.stderr.listen(sink.add).asFuture<void>();
      final exitCode = await process.exitCode;
      // A background process (e.g. a Gradle daemon) may inherit the pipes and
      // keep them open; don't wait on it forever.
      await Future.wait([outDone, errDone])
          .timeout(const Duration(seconds: 10), onTimeout: () => <void>[])
          .catchError((_) => <void>[]);
      _processes.remove(process);
      sink.writeln('\n# exit code: $exitCode');
      await sink.close();

      if (File(resultFile).existsSync()) {
        results = TargetResult.readAll(File(resultFile));
      } else {
        final reason = stopped
            ? _stopReason!
            : 'Worker exited with code $exitCode before reporting results';
        results = [
          for (final t in job.targets)
            stopped
                ? TargetResult.skipped(job.client, t, reason: reason)
                : TargetResult(
                    client: job.client,
                    target: t,
                    success: false,
                    error: reason),
        ];
      }
      if (workspace != null)
        results = [for (final r in results) _collectArtifact(r)];
    } catch (e) {
      final message = e is BuildException ? e.message : e.toString();
      results = [
        for (final t in job.targets)
          TargetResult(
              client: job.client, target: t, success: false, error: message)
      ];
      try {
        logFile.writeAsStringSync('\n# $message\n', mode: FileMode.append);
      } catch (_) {}
    } finally {
      workspace?.release();
      _workerProgress.remove(jp);
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    }

    results = [for (final r in results) r.copyWith(logPath: jp.logPath)];
    final failed = results.where((r) => r.failed).toList();
    jp
      ..finishedAt = tracker.now
      ..targetsDone = results.where((r) => r.success).length
      ..state = results.every((r) => r.skipped)
          ? JobState.skipped
          : failed.isEmpty
              ? JobState.succeeded
              : JobState.failed
      ..detail = failed.isEmpty
          ? (results.every((r) => r.skipped) ? _stopReason : null)
          : '${failed.map((r) => r.target.type).join(',')}: ${_short(failed.first.error)} · log: ${jp.logPath}';
    tick();
    return results;
  }

  /// Moves an artifact out of the workspace into the project's build/udara/.
  TargetResult _collectArtifact(TargetResult r) {
    final source = r.artifact;
    if (source == null || !File(source).existsSync()) return r;
    final dest = File(
        p.join(projectDir, 'build', 'udara', r.client, p.basename(source)));
    dest.parent.createSync(recursive: true);
    if (dest.existsSync()) dest.deleteSync();
    try {
      File(source).renameSync(dest.path);
    } on FileSystemException {
      File(source).copySync(dest.path); // different volume
      File(source).deleteSync();
    }
    return r.copyWith(artifact: dest.path);
  }

  void _pollWorkers() {
    for (final entry in _workerProgress.entries) {
      final state = ProgressTracker.readWorkerState(entry.value);
      if (state == null) continue;
      entry.key
        ..step = state.step ?? entry.key.step
        ..targetsDone = state.targetsDone;
    }
  }

  static String _short(String? error) {
    final text = (error ?? 'failed').split('\n').first;
    return text.length > 80 ? '${text.substring(0, 79)}…' : text;
  }

  /// The command that re-runs this CLI: the compiled executable itself, or
  /// the Dart VM with this script/snapshot (pub global activate, dart run).
  static List<String> selfCommand() {
    final exe = Platform.resolvedExecutable;
    final script = Platform.script.toFilePath();
    const scriptExtensions = ['.dart', '.snapshot', '.dill', '.jit'];
    if (scriptExtensions.any(script.endsWith)) {
      return [exe, ...Platform.executableArguments, script];
    }
    return [exe];
  }

  /// A conservative default: one build per ~8 GB of RAM and per 4 CPU cores,
  /// between 1 and 4.
  static int autoParallel() {
    final cores = Platform.numberOfProcessors;
    final ramGb = _totalRamGb() ?? 16;
    return math.max(1, math.min(4, math.min(ramGb ~/ 8, cores ~/ 4)));
  }

  static int? _totalRamGb() {
    try {
      if (Platform.isMacOS) {
        final r = Process.runSync('sysctl', ['-n', 'hw.memsize']);
        return int.parse(r.stdout.toString().trim()) ~/ (1024 * 1024 * 1024);
      }
      if (Platform.isLinux) {
        final line = File('/proc/meminfo')
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith('MemTotal:'));
        return int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!) ~/
            (1024 * 1024);
      }
    } catch (_) {}
    return null;
  }

  /// The part of a worker log that explains a failure: the lines leading up
  /// to the first error, or to the cleanup that follows it.
  static List<String> tail(String path, {int lines = 15}) {
    try {
      final all = const LineSplitter()
          .convert(File(path).readAsStringSync())
          .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
          .toList();
      var end = all.indexWhere((l) => l.contains('ERROR '));
      if (end >= 0) {
        // Include the error and its FIX line.
        end = (end + 3).clamp(0, all.length);
      } else {
        end = all.indexWhere((l) => l.contains('Starting project cleanup'));
        if (end < 0) end = all.length;
      }
      final start = (end - lines).clamp(0, end);
      return all.sublist(start, end);
    } catch (_) {
      return const [];
    }
  }

  /// Stops a worker and everything it started (flutter, Gradle, xcodebuild),
  /// children first so none are orphaned.
  static void killTree(int rootPid, {bool includeRoot = true}) {
    try {
      if (Platform.isWindows) {
        Process.runSync('taskkill', ['/PID', '$rootPid', '/T', '/F']);
        return;
      }
      final ps = Process.runSync('ps', ['-A', '-o', 'pid=,ppid=']);
      final children = <int, List<int>>{};
      for (final line in ps.stdout.toString().split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length != 2) continue;
        final pid = int.tryParse(parts[0]);
        final ppid = int.tryParse(parts[1]);
        if (pid == null || ppid == null) continue;
        children.putIfAbsent(ppid, () => []).add(pid);
      }
      final order = <int>[];
      void visit(int pid) {
        for (final child in children[pid] ?? const <int>[]) {
          visit(child);
        }
        order.add(pid);
      }

      visit(rootPid);
      if (!includeRoot) order.remove(rootPid);
      for (final pid in order) {
        Process.killPid(pid, ProcessSignal.sigterm);
      }
    } catch (_) {
      Process.killPid(rootPid);
    }
  }
}

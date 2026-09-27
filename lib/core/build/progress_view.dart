import 'dart:io';
import 'dart:math' as math;

import 'progress.dart';

/// Shows a [ProgressTracker] to the user.
abstract class ProgressView {
  /// A live redrawing dashboard on an interactive terminal, plain lines
  /// otherwise (IDE consoles, CI logs, pipes).
  factory ProgressView.forStdout() =>
      stdout.hasTerminal && stdout.supportsAnsiEscapes
          ? TerminalProgressView()
          : LineProgressView();

  /// Called about once a second and after every state change.
  void update(ProgressTracker tracker);

  /// Prints a message that stays in the scrollback (e.g. a job finished).
  void log(String message, ProgressTracker tracker);

  /// Leaves the final state on screen.
  void finish(ProgressTracker tracker);
}

class _Style {
  _Style(this.enabled);
  final bool enabled;
  String _w(String s, String code) => enabled ? '\x1B[${code}m$s\x1B[0m' : s;
  String green(String s) => _w(s, '32');
  String red(String s) => _w(s, '31');
  String cyan(String s) => _w(s, '36');
  String dim(String s) => _w(s, '2');
  String bold(String s) => _w(s, '1');
}

String _headline(ProgressTracker t) {
  final clients = t.jobs.map((j) => j.job.client).toSet().length;
  return 'Building ${t.totalTargets} build${t.totalTargets == 1 ? '' : 's'} for '
      '$clients client${clients == 1 ? '' : 's'} · '
      '${t.parallel == 1 ? 'one at a time' : '${t.parallel} in parallel'}';
}

String _etaText(ProgressTracker t) {
  final done = t.jobs.every((j) => j.isFinished);
  final elapsed = formatDuration(t.now.difference(t.startedAt));
  return done
      ? 'took $elapsed'
      : 'elapsed $elapsed · ETA ~${formatDuration(t.eta())}';
}

class TerminalProgressView implements ProgressView {
  final _style = _Style(true);
  int _drawnLines = 0;
  int _frame = 0;
  static const _spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  int get _width => stdout.hasTerminal ? stdout.terminalColumns : 100;

  @override
  void update(ProgressTracker tracker) {
    _frame++;
    _clear();
    final lines = _render(tracker);
    stdout.write('\x1B[?25l'); // hide cursor while redrawing
    for (final line in lines) {
      stdout.writeln(line);
    }
    _drawnLines = lines.length;
  }

  @override
  void log(String message, ProgressTracker tracker) {
    _clear();
    stdout.writeln(message);
    _drawnLines = 0;
    update(tracker);
  }

  @override
  void finish(ProgressTracker tracker) {
    update(tracker);
    stdout.write('\x1B[?25h');
    _drawnLines = 0;
  }

  void _clear() {
    for (var i = 0; i < _drawnLines; i++) {
      stdout.write('\x1B[1A\x1B[2K');
    }
  }

  /// Truncates plain text to the terminal width before colouring it.
  String _fit(String plain) {
    final max = math.max(_width - 1, 20);
    return plain.length <= max ? plain : '${plain.substring(0, max - 1)}…';
  }

  List<String> _render(ProgressTracker t) {
    final now = t.now;
    final pct = t.percent(now);
    final barWidth = math.min(40, math.max(10, _width - 40));
    final filled = (barWidth * pct / 100).round().clamp(0, barWidth);
    final bar = '${'█' * filled}${'░' * (barWidth - filled)}';

    final clientWidth =
        t.jobs.map((j) => j.job.client.length).fold(0, math.max);
    final lines = <String>[
      '',
      _style.bold(_fit('  ${_headline(t)}')),
      '  ${_style.cyan(bar)} ${t.percentLabel(now).padLeft(3)}%   ${_etaText(t)}',
    ];

    for (final j in t.jobs) {
      final name =
          '${j.job.client.padRight(clientWidth)}  ${j.job.platform.padRight(7)} ${j.job.types.padRight(8)}';
      switch (j.state) {
        case JobState.queued:
          lines.add(_style
              .dim(_fit('  ·  $name queued   ~${formatDuration(j.estimate)}')));
        case JobState.running:
          final spin = _spinner[_frame % _spinner.length];
          final p = math
              .min(99, (100 * j.fraction(now)).floor())
              .toString()
              .padLeft(3);
          final text = _fit(
              '  $spin  $name $p%  ${j.step ?? 'starting…'} · ~${formatDuration(j.remaining(now))} left');
          lines.add(_style.cyan(text.substring(0, 5)) + text.substring(5));
        case JobState.succeeded:
          lines.add(_style.green('  ✓  ') +
              _fit('$name done in ${formatDuration(j.elapsed(now))}'));
        case JobState.failed:
          lines.add(_style.red('  ✗  ') +
              _fit(
                  '$name failed after ${formatDuration(j.elapsed(now))}${j.detail != null ? ' · ${j.detail}' : ''}'));
        case JobState.skipped:
          lines.add(_style.dim(_fit(
              '  –  $name skipped${j.detail != null ? ' · ${j.detail}' : ''}')));
      }
    }
    return lines;
  }
}

/// For consoles that can't redraw: prints state changes as they happen and
/// a status line every [interval].
class LineProgressView implements ProgressView {
  LineProgressView({this.interval = const Duration(seconds: 30)});

  final Duration interval;
  final _style = _Style(stdout.supportsAnsiEscapes);
  final _lastState = <int, JobState>{};
  DateTime? _lastStatus;
  bool _announced = false;

  @override
  void update(ProgressTracker t) {
    if (!_announced) {
      _announced = true;
      stdout.writeln(_style.bold('  ${_headline(t)}'));
    }
    final now = t.now;
    for (var i = 0; i < t.jobs.length; i++) {
      final j = t.jobs[i];
      if (_lastState[i] == j.state) continue;
      _lastState[i] = j.state;
      final name = '${j.job.label} (${j.job.types})';
      final pct = '${t.percentLabel(now)}%';
      switch (j.state) {
        case JobState.queued:
          break;
        case JobState.running:
          stdout.writeln(
              '  ▶ started $name · ~${formatDuration(j.estimate)} expected');
        case JobState.succeeded:
          stdout.writeln(_style.green('  ✓ ') +
              '$name done in ${formatDuration(j.elapsed(now))} · $pct · ${_etaText(t)}');
        case JobState.failed:
          stdout.writeln(_style.red('  ✗ ') +
              '$name failed${j.detail != null ? ': ${j.detail}' : ''} · $pct · ${_etaText(t)}');
        case JobState.skipped:
          stdout.writeln(
              '  – skipped $name${j.detail != null ? ': ${j.detail}' : ''}');
      }
    }
    if (_lastStatus == null || now.difference(_lastStatus!) >= interval) {
      _lastStatus = now;
      final running = t.jobs.where((j) => j.state == JobState.running).map((j) =>
          '${j.job.label} ${math.min(99, (100 * j.fraction(now)).floor())}%${j.step != null ? ' (${j.step})' : ''}');
      if (running.isNotEmpty) {
        stdout.writeln(_style.dim(
            '  … ${t.percentLabel(now)}% · ${_etaText(t)} · ${running.join(' · ')}'));
      }
    }
  }

  @override
  void log(String message, ProgressTracker tracker) => stdout.writeln(message);

  @override
  void finish(ProgressTracker tracker) => update(tracker);
}

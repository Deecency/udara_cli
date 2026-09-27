import 'package:test/test.dart';
import 'package:udara_cli/core/core.dart';

void main() {
  const android = BuildJob(
      client: 'acme',
      platform: 'android',
      targets: [BuildTarget('android', 'aab')]);
  const ios = BuildJob(
      client: 'acme', platform: 'ios', targets: [BuildTarget('ios', 'ipa')]);
  const beta = BuildJob(
      client: 'beta',
      platform: 'android',
      targets: [BuildTarget('android', 'aab')]);

  group('DurationEstimator', () {
    test('falls back to defaults without history', () {
      final e = DurationEstimator(const []);
      expect(e.target('acme', 'aab'), DurationEstimator.defaults['aab']);
      expect(e.target('acme', 'ipa'), DurationEstimator.defaults['ipa']);
    });

    test('prefers the same client, then the same type, ignoring failures', () {
      final e = DurationEstimator([
        {
          'client': 'acme',
          'type': 'aab',
          'success': true,
          'durationSeconds': 100
        },
        {
          'client': 'acme',
          'type': 'aab',
          'success': true,
          'durationSeconds': 300
        },
        {
          'client': 'acme',
          'type': 'aab',
          'success': true,
          'durationSeconds': 200
        },
        {
          'client': 'beta',
          'type': 'aab',
          'success': true,
          'durationSeconds': 900
        },
        {
          'client': 'beta',
          'type': 'apk',
          'success': false,
          'durationSeconds': 5
        },
      ]);
      expect(e.target('acme', 'aab'), const Duration(seconds: 200)); // median
      expect(e.target('gamma', 'aab').inSeconds, greaterThan(0));
      expect(e.target('beta', 'apk'), DurationEstimator.defaults['apk']);
    });
  });

  group('ProgressTracker', () {
    late DateTime now;
    ProgressTracker tracker(List<JobProgress> jobs, int parallel) =>
        ProgressTracker(jobs: jobs, parallel: parallel, clock: () => now);

    setUp(() => now = DateTime(2026, 1, 1, 12));

    test('starts at 0% and ETA equals the longest slot', () {
      final a = JobProgress(android, const Duration(minutes: 4));
      final b = JobProgress(ios, const Duration(minutes: 10));
      final c = JobProgress(beta, const Duration(minutes: 4));
      final t = tracker([a, b, c], 2);
      expect(t.percent(), 0);
      // Slots: [4, 10] then c joins the 4-minute slot -> 8; longest is 10.
      expect(t.eta(), const Duration(minutes: 10));
      expect(tracker([a, b, c], 1).eta(), const Duration(minutes: 18));
    });

    test('progress is weighted by estimates and time', () {
      final a = JobProgress(android, const Duration(minutes: 4));
      final b = JobProgress(ios, const Duration(minutes: 12));
      final t = tracker([a, b], 2);
      a
        ..state = JobState.succeeded
        ..startedAt = now
        ..finishedAt = now;
      b
        ..state = JobState.running
        ..startedAt = now;
      now = now.add(const Duration(minutes: 6)); // halfway through b
      // a = 4/16 done, b = 12/16 * 0.9 * 0.5
      expect(t.percent(), closeTo(100 * (4 + 12 * 0.45) / 16, 0.01));
      // Unfinished share of b's estimate: 12 min * (1 - 0.45).
      expect(t.eta().inSeconds, closeTo(12 * 60 * 0.55, 1));
    });

    test('an overrunning job slows down instead of reaching 100%', () {
      final a = JobProgress(android, const Duration(minutes: 4))
        ..state = JobState.running
        ..startedAt = now;
      final t = tracker([a], 1);
      now = now.add(const Duration(minutes: 40));
      expect(a.fraction(now), lessThan(0.99));
      expect(a.fraction(now), greaterThan(0.9));
      expect(t.eta(), greaterThan(Duration.zero));
    });

    test('percent label never reads 100 before everything finished', () {
      final a = JobProgress(android, const Duration(minutes: 4))
        ..state = JobState.running
        ..startedAt = now
        ..targetsDone = 1;
      final t = tracker([a], 1);
      expect(t.percentLabel(), '99');
      a.state = JobState.succeeded;
      expect(t.percentLabel(), '100');
    });

    test('finishing a target shortens the time left', () {
      final a = JobProgress(android, const Duration(minutes: 10))
        ..state = JobState.running
        ..startedAt = now;
      final t = tracker([a], 1);
      now = now.add(const Duration(seconds: 5));
      final before = t.eta();
      a.targetsDone = 1;
      expect(t.eta(), lessThan(before));
      expect(t.eta(), lessThan(const Duration(minutes: 1)));
    });

    test('completed targets set a floor on job progress', () {
      final job = JobProgress(
          const BuildJob(client: 'acme', platform: 'android', targets: [
            BuildTarget('android', 'aab'),
            BuildTarget('android', 'apk'),
          ]),
          const Duration(hours: 1))
        ..state = JobState.running
        ..startedAt = now
        ..targetsDone = 1;
      expect(job.fraction(now.add(const Duration(seconds: 5))),
          closeTo(0.495, 0.001));
    });

    test('json snapshot round-trips the worker state', () {
      final a = JobProgress(android, const Duration(minutes: 4))
        ..state = JobState.running
        ..startedAt = now
        ..step = 'Building android/aab'
        ..targetsDone = 0;
      final t = tracker([a], 1);
      final json = t.toJson();
      expect(json['jobsTotal'], 1);
      expect((json['jobs'] as List).single['step'], 'Building android/aab');
      expect(json['finished'], isFalse);
    });
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 42)), '42s');
    expect(formatDuration(const Duration(minutes: 3, seconds: 5)), '3m 05s');
    expect(formatDuration(const Duration(hours: 1, minutes: 2)), '1h 02m');
  });
}

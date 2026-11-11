import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/stores.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/services/tracking/tracking_entry_cache.dart';
import 'package:kazumi/services/tracking/tracking_sync.dart';
import 'package:logger/logger.dart';

class MemoryBindings implements BindingStore {
  final Map<String, TrackingBinding> rows = {};
  @override
  Future<List<TrackingBinding>> all() async => rows.values.toList();
  @override
  Future<void> delete(String key) async {
    rows.remove(key);
  }

  @override
  Future<TrackingBinding?> get(String key) async => rows[key];
  @override
  Future<void> put(TrackingBinding binding) async {
    rows[binding.key] = binding;
  }
}

class MemoryOutbox implements OutboxStore {
  final Map<String, OutboxEntry> rows = {};
  @override
  Future<List<OutboxEntry>> all() async => rows.values.toList();
  @override
  Future<void> delete(String key) async {
    rows.remove(key);
  }

  @override
  Future<OutboxEntry?> get(String key) async => rows[key];
  @override
  Future<void> put(OutboxEntry entry) async {
    rows[entry.key] = entry;
  }
}

class FakeTracker implements Tracker {
  FakeTracker(this.id);
  @override
  final TrackerId id;
  RemoteEntry? remote;
  TrackerException? failure;
  Object? Function(String)? readFailure;
  final calls = <(int?, TrackStatus?, int?)>[];
  int reads = 0;
  Completer<void>? blockedRead;
  @override
  Future<RemoteEntry?> readEntry(String token, String remoteId) async {
    reads++;
    if (blockedRead != null) await blockedRead!.future;
    final unexpected = readFailure?.call(remoteId);
    if (unexpected != null) throw unexpected;
    if (failure != null) throw failure!;
    return remote;
  }

  @override
  Future<int> save(
    String token,
    String remoteId, {
    int? progress,
    TrackStatus? status,
    int? score,
  }) async {
    if (failure != null) throw failure!;
    calls.add((progress, status, score));
    return progress ?? remote?.progress ?? 0;
  }

  @override
  Future<List<TrackerSearchResult>> search(
    String query, {
    String? token,
  }) async => [];
  @override
  Future<TrackerUser> viewer(String token) async =>
      const TrackerUser(id: '1', name: 'test');
}

class Harness {
  Harness({this.cache});
  final TrackingEntryCache? cache;
  final bindings = MemoryBindings();
  final outbox = MemoryOutbox();
  final a = FakeTracker(TrackerId.bangumi);
  final b = FakeTracker(TrackerId.anilist);
  DateTime now = DateTime.utc(2026);
  late final TrackingSync sync = TrackingSync(
    bindings: bindings,
    outbox: outbox,
    trackers: [a, b],
    tokenProvider: (_) async => 'secret',
    clock: () => now,
    delay: (d) async {
      now = now.add(d);
    },
    schedule: (_, _) => () {},
    cache: cache,
  );
  Future<void> bind({
    TrackerId id = TrackerId.bangumi,
    int subject = 1,
    String remote = 'r',
    bool locked = false,
    int? total,
    int offset = 0,
  }) => bindings.put(
    TrackingBinding(
      subjectId: subject,
      trackerId: id,
      remoteId: remote,
      statusLocked: locked,
      total: total,
      episodeOffset: offset,
    ),
  );
  Future<void> enqueue({
    int subject = 1,
    int? progress,
    TrackStatus? status,
    int? score,
  }) async {
    await sync.enqueue(
      subject,
      progress: progress,
      status: status,
      score: score,
    );
    await sync.drain();
  }
}

void main() {
  late Harness h;
  setUp(() {
    h = Harness();
  });
  tearDown(() {
    h.sync.dispose();
  });

  test('new entry uses current and offset, then never lowers remote', () async {
    await h.bind(offset: 2);
    await h.enqueue(progress: 3);
    expect(h.a.calls.single, (5, TrackStatus.current, null));
    h.a.remote = const RemoteEntry(progress: 9, status: TrackStatus.current);
    await h.enqueue(progress: 2);
    expect(h.a.calls.length, 1);
  });
  test('completion, rewatch, and locked status rules', () async {
    await h.bind(total: 12);
    h.a.remote = const RemoteEntry(progress: 10, status: TrackStatus.current);
    await h.enqueue(progress: 12);
    expect(h.a.calls.last, (12, TrackStatus.completed, null));
    h.a.remote = const RemoteEntry(progress: 12, status: TrackStatus.completed);
    await h.enqueue(progress: 3);
    expect(h.a.calls.length, 1);
    await h.bind(total: 12, locked: true);
    await h.enqueue(status: TrackStatus.paused);
    expect(h.a.calls.last, (null, TrackStatus.paused, null));
  });
  test('locked status suppresses derived completion and current', () async {
    await h.bind(total: 12, locked: true);
    h.a.remote = const RemoteEntry(progress: 11, status: TrackStatus.current);
    await h.enqueue(progress: 12);
    expect(h.a.calls.single, (12, null, null));
    h.a.remote = null;
    await h.enqueue(progress: 1);
    expect(h.a.calls.last, (1, null, null));
  });
  test('explicit status overrides remote completed', () async {
    await h.bind(total: 12);
    h.a.remote = const RemoteEntry(progress: 12, status: TrackStatus.completed);
    await h.enqueue(status: TrackStatus.dropped);
    expect(h.a.calls.single, (null, TrackStatus.dropped, null));
  });
  test('watching a completed entry sends no status', () async {
    await h.bind(total: 12);
    h.a.remote = const RemoteEntry(progress: 12, status: TrackStatus.completed);
    await h.enqueue(progress: 13);
    expect(h.a.calls.single, (13, null, null));
  });
  test('re-enqueue keeps the high-water mark during a call', () async {
    await h.bind();
    h.a.blockedRead = Completer<void>();
    await h.sync.enqueue(1, progress: 8);
    while (h.a.reads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await h.sync.enqueue(1, progress: 3);
    expect(h.outbox.rows.values.single.progress, 8);
    h.a.blockedRead!.complete();
    await h.sync.drain();
    expect(h.a.calls.every((call) => call.$1 == 8), isTrue);
    expect(h.outbox.rows, isEmpty);
  });
  test('new entry accepts chosen status', () async {
    await h.bind();
    await h.enqueue(status: TrackStatus.planning);
    expect(h.a.calls.single, (null, TrackStatus.planning, null));
  });

  test('score is only sent when changed', () async {
    await h.bind();
    h.a.remote = const RemoteEntry(
      progress: 4,
      status: TrackStatus.current,
      score: 70,
    );
    await h.enqueue(score: 70);
    expect(h.a.calls, isEmpty);
    await h.enqueue(score: 80);
    expect(h.a.calls.single, (null, null, 80));
  });
  for (final failure in [
    const TrackerNetworkException(),
    const TrackerServerException(),
  ]) {
    test('$failure follows all backoffs then fails', () async {
      await h.bind();
      h.a.failure = failure;
      await h.enqueue(progress: 1);
      for (final wait in [
        const Duration(seconds: 30),
        const Duration(minutes: 2),
        const Duration(minutes: 10),
        const Duration(hours: 1),
      ]) {
        final row = h.outbox.rows.values.single;
        expect(row.retryAt!.difference(h.now), wait);
        h.now = row.retryAt!;
        await h.sync.drain();
      }
      expect(h.outbox.rows.values.single.error, 'Sync failed after retries');
    });
  }
  test(
    'unexpected tracker error backs off and other rows still drain',
    () async {
      final previousLevel = Logger.level;
      Logger.level = Level.off;
      addTearDown(() => Logger.level = previousLevel);
      await h.bind(remote: 'bad');
      await h.bind(subject: 2, remote: 'good');
      for (final binding in await h.bindings.all()) {
        await h.outbox.put(
          OutboxEntry(
            subjectId: binding.subjectId,
            trackerId: binding.trackerId,
            remoteId: binding.remoteId,
            bindingGeneration: binding.generation,
            progress: 1,
          ),
        );
      }
      h.a.readFailure = (remote) =>
          remote == 'bad' ? StateError('secret') : null;
      final started = h.now;
      await h.sync.drain();
      expect(h.a.calls, [(1, TrackStatus.current, null)]);
      final row = h.outbox.rows.values.single;
      expect(row.subjectId, 1);
      expect(row.attempts, 1);
      expect(row.retryAt, started.add(const Duration(seconds: 30)));
      for (var i = 0; i < 4; i++) {
        h.now = h.outbox.rows.values.single.retryAt!;
        await h.sync.drain();
      }
      expect(h.outbox.rows.values.single.error, 'Sync failed after retries');
    },
  );
  test('auth fails tracker rows while other tracker drains', () async {
    await h.bind();
    await h.bind(id: TrackerId.anilist);
    h.a.failure = const TrackerAuthException();
    await h.enqueue(progress: 1);
    expect(h.outbox.rows.values.single.error, 'sign-in expired');
    expect(h.b.calls.single.$1, 1);
  });
  test('retryFailed recovers an auth-failed tracker after sign-in', () async {
    await h.bind();
    await h.bind(id: TrackerId.anilist);
    h.a.failure = const TrackerAuthException();
    h.b.failure = const TrackerAuthException();
    await h.enqueue(progress: 5, status: TrackStatus.paused, score: 70);
    expect(h.outbox.rows, hasLength(2));
    h.a.failure = null;
    await h.sync.retryFailed(TrackerId.bangumi);
    expect(h.a.calls.single, (5, TrackStatus.paused, 70));
    expect(h.outbox.rows.values.single.trackerId, TrackerId.anilist);
    expect(h.outbox.rows.values.single.error, 'sign-in expired');
  });
  test(
    'a new enqueue retries an exhausted row and preserves pending intent',
    () async {
      await h.bind();
      h.a.failure = const TrackerServerException();
      await h.enqueue(progress: 8, status: TrackStatus.paused, score: 70);
      for (var i = 0; i < 4; i++) {
        h.now = h.outbox.rows.values.single.retryAt!;
        await h.sync.drain();
      }
      expect(h.outbox.rows.values.single.error, isNotNull);
      h.a.failure = null;
      await h.enqueue(progress: 3);
      expect(h.a.calls.single, (8, TrackStatus.paused, 70));
      expect(h.outbox.rows, isEmpty);
    },
  );
  test('request rejection fails permanently', () async {
    await h.bind();
    h.a.failure = const TrackerRequestException('rejected');
    await h.enqueue(progress: 1);
    expect(h.outbox.rows.values.single.error, 'rejected');
    await h.sync.drain();
    expect(h.a.reads, 1);
  });
  test('rate limit pauses tracker for retry-after', () async {
    await h.bind();
    h.a.failure = const TrackerRateLimitedException(Duration(minutes: 3));
    await h.enqueue(progress: 1);
    expect(
      h.outbox.rows.values.single.retryAt!.difference(h.now),
      const Duration(minutes: 3),
    );
    await h.sync.drain();
    expect(h.a.reads, 1);
    h.now = h.now.add(const Duration(minutes: 3));
    h.a.failure = null;
    await h.sync.drain();
    expect(h.a.calls, hasLength(1));
  });
  test('rate limit waits at least one minute', () async {
    await h.bind();
    h.a.failure = const TrackerRateLimitedException(Duration(seconds: 1));
    await h.enqueue(progress: 1);
    expect(
      h.outbox.rows.values.single.retryAt!.difference(h.now),
      const Duration(minutes: 1),
    );
  });
  test('recreating the same remote binding drops the old row', () async {
    await h.bind();
    final old = (await h.bindings.get('1:bangumi'))!;
    await h.outbox.put(
      OutboxEntry(
        subjectId: 1,
        trackerId: TrackerId.bangumi,
        remoteId: old.remoteId,
        bindingGeneration: old.generation,
        progress: 4,
      ),
    );
    await h.bindings.delete(old.key);
    await h.bind();
    expect((await h.bindings.get(old.key))!.generation, isNot(old.generation));
    await h.sync.drain();
    expect(h.outbox.rows, isEmpty);
    expect(h.a.reads, 0);
  });
  test('rebind between remote read and write drops the old row', () async {
    await h.bind();
    h.a.blockedRead = Completer<void>();
    await h.sync.enqueue(1, progress: 4);
    while (h.a.reads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await h.bind();
    h.a.blockedRead!.complete();
    await h.sync.drain();
    expect(h.a.calls, isEmpty);
    expect(h.outbox.rows, isEmpty);
  });
  test('removed or rebound entries are dropped', () async {
    await h.bind();
    await h.outbox.put(
      const OutboxEntry(
        subjectId: 1,
        trackerId: TrackerId.bangumi,
        remoteId: 'old',
        bindingGeneration: 'old',
        progress: 4,
      ),
    );
    await h.sync.drain();
    expect(h.outbox.rows, isEmpty);
    expect(h.a.reads, 0);
    await h.bindings.delete('1:bangumi');
    await h.outbox.put(
      const OutboxEntry(
        subjectId: 1,
        trackerId: TrackerId.bangumi,
        remoteId: 'r',
        bindingGeneration: 'old',
        progress: 4,
      ),
    );
    await h.sync.drain();
    expect(h.outbox.rows, isEmpty);
  });

  test('a successful drain refreshes the entry cache before clearing the row', () async {
    final cache = TrackingEntryCache();
    final syncing = Harness(cache: cache);
    addTearDown(syncing.sync.dispose);
    await syncing.bind(total: 12);
    syncing.a.remote = const RemoteEntry(
      progress: 1,
      status: TrackStatus.planning,
      total: 12,
    );
    await syncing.enqueue(status: TrackStatus.current);
    expect(syncing.outbox.rows, isEmpty);
    final binding = syncing.bindings.rows.values.single;
    final snapshot = cache.get(binding);
    expect(snapshot?.entry?.status, TrackStatus.current);
    expect(snapshot?.entry?.progress, 1);
    expect(snapshot?.entry?.total, 12);
    expect(snapshot?.isFresh(syncing.now), isTrue);
  });
}
